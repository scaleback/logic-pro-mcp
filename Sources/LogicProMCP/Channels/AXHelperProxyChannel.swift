import Foundation

/// Batuta (Fase 3): stands in for `AccessibilityChannel` in the SANDBOXED
/// main process. Forwards every `execute()` call to a separate, unsandboxed
/// helper process (`LogicProMCPAXHelper`) over a JSON-Lines pipe, and
/// decodes its answer back into a `ChannelResult` — from the router's (and
/// every dispatcher's) point of view this is indistinguishable from calling
/// `AccessibilityChannel` directly. See LogicProMCPAXHelper/main.swift for
/// why this split exists and AXHelperProtocol.swift for the wire format.
actor AXHelperProxyChannel: AccessibilityChannelProtocol {
    let id: ChannelID = .accessibility

    private let helperPath: String
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?

    /// Line-framing buffer for whatever partial/complete lines have arrived
    /// on the helper's stdout so far but haven't been claimed by a waiting
    /// `execute()` call yet.
    private var lineBuffer = Data()
    private var bufferedLines: [String] = []
    /// Continuations for `execute()` calls that are already waiting on the
    /// NEXT line to arrive, in the order they started waiting. Reentrancy
    /// note: an `actor` allows a second `execute()` call to start while a
    /// first one is suspended awaiting its response — but each call writes
    /// its request line and THEN awaits, and that write always finishes
    /// (synchronously, no intervening suspension point) before any other
    /// call on this actor can run. So requests are written to the helper in
    /// the same order calls arrived, the helper (a single, non-concurrent
    /// stdin-read loop) answers in that same order, and resolving
    /// continuations FIFO here reunites each answer with the right caller —
    /// this is why a plain array-as-queue is correct here, not a scheduling
    /// bug waiting to happen.
    private var pendingWaiters: [CheckedContinuation<String?, Never>] = []
    private var eof = false

    init(helperPath: String = AXHelperProxyChannel.defaultHelperPath()) {
        self.helperPath = helperPath
    }

    /// Ships alongside the main binary at the same install location.
    /// Overridable (see `init`) for tests and for a future proper installer
    /// that may place it somewhere more principled (e.g. next to
    /// `CommandLine.arguments[0]`) — hardcoded for now, matching how the
    /// rest of Fase 3 has shipped: get it correct and live-verified first,
    /// generalize the install story later.
    static func defaultHelperPath() -> String {
        "/usr/local/bin/LogicProMCPAXHelper"
    }

    func start() async throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw AXHelperProxyChannelError.helperNotFound(helperPath)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperPath)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        try proc.run()

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        eof = false

        let outHandle = stdoutPipe.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.handleIncoming(data) }
        }
    }

    func stop() async {
        stdoutHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        lineBuffer = Data()
        bufferedLines = []
        eof = true
        for waiter in pendingWaiters {
            waiter.resume(returning: nil)
        }
        pendingWaiters = []
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        if process == nil || process?.isRunning != true {
            do {
                try await start()
            } catch {
                return .error("AXHelperProxyChannel: could not start helper (\(error))")
            }
        }
        guard let stdinHandle, process?.isRunning == true else {
            return .error("AXHelperProxyChannel: helper process unavailable")
        }

        let request = AXHelperProtocol.Request(operation: operation, params: params)
        guard let requestData = try? JSONEncoder().encode(request) else {
            return .error("AXHelperProxyChannel: failed to encode request for \(operation)")
        }
        var line = requestData
        line.append(0x0A)

        do {
            try stdinHandle.write(contentsOf: line)
        } catch {
            return .error("AXHelperProxyChannel: failed to write to helper stdin: \(error)")
        }

        guard let responseLine = await nextLine() else {
            return .error("AXHelperProxyChannel: helper closed the connection (EOF) answering \(operation)")
        }
        guard let responseData = responseLine.data(using: .utf8),
              let response = try? JSONDecoder().decode(AXHelperProtocol.Response.self, from: responseData) else {
            return .error("AXHelperProxyChannel: malformed helper response for \(operation): \(responseLine)")
        }
        switch response.kind {
        case .success: return .success(response.message)
        case .error: return .error(response.message)
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard let process, process.isRunning else {
            return .unavailable("AX helper process is not running", verificationStatus: .unavailable)
        }
        return .healthy(detail: "AX helper connected (pid \(process.processIdentifier))")
    }

    /// No local AX runtime to read — the real one lives in the helper
    /// process, across the pipe. Returning `nil` correctly triggers
    /// `StatePoller.pollOnce()`'s existing fallback to
    /// `poll(operation: "track.get_tracks", ...)`, which only needs
    /// `Channel.execute()` and works identically through this proxy.
    func readTrackStates() async -> [TrackState]? {
        nil
    }

    // MARK: - Line framing

    private func handleIncoming(_ data: Data) {
        guard !data.isEmpty else {
            eof = true
            resolveOneWaiter(with: nil)
            return
        }
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            let line = String(data: lineData, encoding: .utf8) ?? ""
            if pendingWaiters.isEmpty {
                bufferedLines.append(line)
            } else {
                pendingWaiters.removeFirst().resume(returning: line)
            }
        }
    }

    private func resolveOneWaiter(with line: String?) {
        guard !pendingWaiters.isEmpty else { return }
        pendingWaiters.removeFirst().resume(returning: line)
    }

    private func nextLine() async -> String? {
        if !bufferedLines.isEmpty {
            return bufferedLines.removeFirst()
        }
        if eof { return nil }
        return await withCheckedContinuation { continuation in
            pendingWaiters.append(continuation)
        }
    }
}

enum AXHelperProxyChannelError: Error, CustomStringConvertible {
    case helperNotFound(String)

    var description: String {
        switch self {
        case .helperNotFound(let path):
            return "AX helper executable not found or not executable at \(path)"
        }
    }
}
