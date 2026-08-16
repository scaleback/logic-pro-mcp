import Darwin
import Foundation

/// Batuta (Fase 3): stands in for `AccessibilityChannel` in the SANDBOXED
/// main process. Forwards every `execute()` call to a separate, unsandboxed
/// helper process (`LogicProMCPAXHelper`) over named pipes (FIFOs), and
/// decodes its answer back into a `ChannelResult` — from the router's (and
/// every dispatcher's) point of view this is indistinguishable from calling
/// `AccessibilityChannel` directly. See LogicProMCPAXHelper/main.swift for
/// what the helper does and AXFifoTransport.swift for the low-level
/// mechanics and the FULL history of why this took three different
/// transports to land (Process()+Pipe() → Unix socket → FIFOs).
///
/// Short version: `Process()`-spawning the helper made it a child of this
/// sandboxed process, and `kAXWindowsAttribute` failed for EVERY target app
/// tried from that position — live-tested and confirmed to be about
/// ancestry, not entitlements (the same helper, launched via `launchctl
/// submit` instead, worked immediately, no code changes). So the helper now
/// runs as its own launchd-managed LaunchAgent; this actor never spawns it
/// directly, only asks launchd to (via `launchctl kickstart`), which keeps
/// launchd as its true parent. A Unix domain socket was the first IPC
/// replacement and worked architecturally, but the sandbox profile
/// classifies `connect()` on ANY socket — including a purely local
/// `AF_UNIX` one — as `network-outbound`, requiring
/// `com.apple.security.network.client`. Edgar chose not to add that
/// entitlement (Fase 1's "no network" guarantee is meant to be
/// kernel-enforced, not code-review-enforced) and asked for named pipes
/// instead — confirmed live that `mkfifo`/`open`/`read`/`write` are plain
/// file operations to the sandbox, already covered by the file entitlement
/// this process already has.
actor AXHelperProxyChannel: AccessibilityChannelProtocol {
    let id: ChannelID = .accessibility

    /// launchd label for the helper's LaunchAgent — shared by the plist
    /// this writes/bootstraps and the `launchctl kickstart` target.
    static let launchdLabel = "com.scaleback.batuta.logicpromcp.axhelper"

    private let helperBinaryPath: String
    /// Set once `ensureLaunchAgentRegistered()` has run successfully, so
    /// `execute()` doesn't rewrite the (idempotent, but not free) plist and
    /// re-bootstrap on every single call — only the first, and again after
    /// a call that couldn't reach the control FIFO at all.
    private var launchAgentEnsured = false

    init(helperBinaryPath: String = AXHelperProxyChannel.defaultHelperBinaryPath()) {
        self.helperBinaryPath = helperBinaryPath
    }

    /// Ships alongside the main binary at the same install location.
    static func defaultHelperBinaryPath() -> String {
        "/usr/local/bin/LogicProMCPAXHelper"
    }

    func start() async throws {
        try ensureLaunchAgentRegistered()
        try? await launchctl(["kickstart", "gui/\(getuid())/\(Self.launchdLabel)"])
    }

    /// Nothing persistent to tear down — every call is a fully self-contained
    /// round trip over its own pair of FIFOs (see AXFifoTransport.swift's
    /// doc comment for why per-call, not per-connection).
    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        let request = AXHelperProtocol.Request(operation: operation, params: params)
        guard let requestData = try? JSONEncoder().encode(request) else {
            return .error("AXHelperProxyChannel: failed to encode request for \(operation)")
        }

        if !launchAgentEnsured {
            do {
                try await start()
                launchAgentEnsured = true
            } catch {
                return .error("AXHelperProxyChannel: could not register helper LaunchAgent (\(error))")
            }
        }

        // The actual FIFO dance is a sequence of blocking POSIX calls
        // (mkfifo/open/write/read) — running it inline here would block
        // this actor's serial executor for the whole round trip, starving
        // every OTHER call to this same actor for that entire time (an
        // `await` is what lets an actor's queue move on; a thread-blocking
        // syscall with no suspension point in between is not the same
        // thing). `Task.detached` moves it to Concurrency's own pool, off
        // this actor entirely — `await`ing its result is a real suspension
        // point.
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.performRoundTrip(requestData: requestData, operation: operation)
        }.value

        switch outcome {
        case .success(let responseLine):
            guard let responseData = responseLine.data(using: .utf8),
                  let response = try? JSONDecoder().decode(AXHelperProtocol.Response.self, from: responseData) else {
                return .error("AXHelperProxyChannel: malformed helper response for \(operation): \(responseLine)")
            }
            switch response.kind {
            case .success: return .success(response.message)
            case .error: return .error(response.message)
            }
        case .helperUnreachable:
            // The control FIFO write failed even after a kickstart retry —
            // the LaunchAgent registration itself may be stale (e.g. the
            // helper binary was reinstalled and needs a fresh bootstrap).
            // Clear the flag so the NEXT call re-registers instead of
            // trusting a possibly-stale "already ensured" state forever.
            launchAgentEnsured = false
            return .error("AXHelperProxyChannel: could not reach helper control FIFO for \(operation)")
        case .transportError(let message):
            return .error("AXHelperProxyChannel: \(message)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        if !launchAgentEnsured {
            do {
                try await start()
                launchAgentEnsured = true
            } catch {
                return .unavailable("AX helper LaunchAgent not registered: \(error)", verificationStatus: .unavailable)
            }
        }
        return .healthy(detail: "AX helper LaunchAgent registered (FIFO transport)")
    }

    /// No local AX runtime to read — the real one lives in the helper
    /// process, across the FIFOs. Returning `nil` correctly triggers
    /// `StatePoller.pollOnce()`'s existing fallback to
    /// `poll(operation: "track.get_tracks", ...)`, which only needs
    /// `Channel.execute()` and works identically through this proxy.
    func readTrackStates() async -> [TrackState]? {
        nil
    }

    // MARK: - Round trip (runs off-actor, inside Task.detached)

    private enum RoundTripOutcome: Sendable {
        case success(String)
        case helperUnreachable
        case transportError(String)
    }

    private static func performRoundTrip(requestData: Data, operation: String) -> RoundTripOutcome {
        let requestId = UUID().uuidString
        let reqPath = AXFifoTransport.requestFifoPath(id: requestId)
        let respPath = AXFifoTransport.responseFifoPath(id: requestId)
        defer {
            unlink(reqPath)
            unlink(respPath)
        }

        guard let respFD = AXFifoTransport.createAndOpenForReading(path: respPath) else {
            return .transportError("could not create response FIFO for \(operation)")
        }
        defer { close(respFD) }

        // The request FIFO is opened for WRITING by this side but must be
        // CREATED here too — the server only ever opens an existing path
        // for reading, it never creates one. Missing this the first time
        // around meant `openForWriting` had no special file to find.
        guard AXFifoTransport.createFifo(path: reqPath) else {
            return .transportError("could not create request FIFO for \(operation)")
        }

        let hello = "{\"req_path\":\"\(reqPath)\",\"resp_path\":\"\(respPath)\"}"
        guard let helloData = hello.data(using: .utf8) else {
            return .transportError("could not encode hello for \(operation)")
        }
        guard let controlFD = AXFifoTransport.openForWriting(path: AXFifoTransport.controlFifoPath()) else {
            return .helperUnreachable
        }
        let helloSent = AXFifoTransport.writeLine(helloData, to: controlFD)
        close(controlFD)
        guard helloSent else {
            return .helperUnreachable
        }

        guard let reqFD = AXFifoTransport.openForWriting(path: reqPath) else {
            return .transportError("could not open request FIFO for \(operation)")
        }
        let requestSent = AXFifoTransport.writeLine(requestData, to: reqFD)
        close(reqFD)
        guard requestSent else {
            return .transportError("failed to write request for \(operation)")
        }

        guard let responseLine = AXFifoTransport.readLine(fd: respFD) else {
            return .transportError("no response from helper for \(operation) (EOF or read error)")
        }
        return .success(responseLine)
    }

    // MARK: - LaunchAgent lifecycle

    /// Writes the LaunchAgent plist (idempotent — same content every time,
    /// harmless to overwrite) and bootstraps it into launchd if it isn't
    /// already loaded. `bootstrap` on an already-loaded label fails
    /// harmlessly (steady-state outcome, not treated as an error here —
    /// every OTHER failure to write the plist itself is, and propagates).
    private func ensureLaunchAgentRegistered() throws {
        let plistPath = Self.launchAgentPlistPath()
        let plistContents = Self.launchAgentPlistContents(helperBinaryPath: helperBinaryPath)
        let directory = (plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try plistContents.write(toFile: plistPath, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootstrap", "gui/\(getuid())", plistPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    private func launchctl(_ arguments: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
    }

    static func launchAgentPlistPath() -> String {
        AXFifoTransport.realHomeDirectory() + "/Library/LaunchAgents/\(launchdLabel).plist"
    }

    static func launchAgentPlistContents(helperBinaryPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchdLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helperBinaryPath)</string>
            </array>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardErrorPath</key>
            <string>\(AXFifoTransport.realHomeDirectory())/Library/Logs/LogicProMCP/axhelper.err.log</string>
        </dict>
        </plist>
        """
    }
}
