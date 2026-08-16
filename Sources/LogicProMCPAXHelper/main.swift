import Darwin
import Foundation
import LogicProMCP

// Batuta (Fase 3): the Accessibility channel, running WITHOUT App Sandbox,
// as its own independent launchd LaunchAgent.
//
// Why a LaunchAgent, not a plain child process: confirmed live (2026-08-16,
// see HANDOFF.md) that kAXWindowsAttribute fails with -25204 reading ANY
// target app's window list (Logic Pro, Finder, even Claude itself) from a
// process descended from the sandboxed main LogicProMCP process — even
// with this process carrying no sandbox entitlement of its own and being
// genuinely Accessibility-trusted. The SAME binary launched via `launchctl
// submit` (parented by launchd, no sandboxed ancestor in its process tree)
// read real window lists from all three targets with zero code changes.
// The restriction tracks ancestry, not this process's own configuration.
//
// Why named pipes (FIFOs), not a Unix domain socket: sockets worked
// architecturally (same ancestry fix), but the sandbox profile classifies
// `connect()` on ANY socket — including a purely local `AF_UNIX` one — as
// `network-outbound`, which the sandboxed main process would need
// `com.apple.security.network.client` to do. Edgar chose not to add that
// entitlement (Fase 1's "no network" guarantee is meant to be
// kernel-enforced, not code-review-enforced) and asked for FIFOs instead —
// confirmed live that `mkfifo`/`open`/`read`/`write` are plain file
// operations to the sandbox, already covered by the file entitlement the
// main process already has. See AXFifoTransport.swift for the full
// protocol design and AXHelperProxyChannel.swift (the sandboxed side of
// this) for the client's half of the story.
//
// Protocol: one long-lived "control" FIFO at a fixed path, held open for
// this process's entire life. Each client call arrives as a one-line
// "hello" naming a fresh, uniquely-named request/response FIFO pair;
// serving it is a self-contained task (open request FIFO, read one JSON
// line, `channel.execute()`, open response FIFO, write one JSON line,
// close both). Multiple concurrent client calls are handled concurrently —
// each on its own FIFO pair — with the actual AX operations serialized by
// the AccessibilityChannel actor itself, same as always. This process holds
// NO privilege beyond com.apple.security.automation.apple-events (needed
// by AccessibilityChannel's AppleScript-backed helpers for a few
// operations) — no sandbox, no other entitlements. It runs for as long as
// launchd keeps it alive (`KeepAlive.SuccessfulExit: false` in the plist
// AXHelperProxyChannel writes).

@main
struct LogicProMCPAXHelperMain {
    // Found live 2026-08-15 (Batuta tarea #26, before either IPC pivot): a
    // bare blocking `readLine()` loop never let the main thread's run loop
    // spin, and ProcessUtils.swift's own `logicOwnsTheKeyboard()` doc
    // comment already names exactly this failure mode for NSWorkspace-backed
    // lookups ("served from a cache that a process only refreshes while it
    // runs a run loop"). Still true here: `main()` stays synchronous so it's
    // guaranteed to run start-to-finish on the real thread 0 (an async
    // `main()` may resume post-`await` on a different Concurrency worker
    // thread), all actual async/blocking work runs inside `Task`s on
    // Concurrency's own thread pool, and thread 0 is left free to block in
    // `RunLoop.main.run()` for the process's entire lifetime.
    static func main() {
        let channel = AccessibilityChannel()
        let controlPath = AXFifoTransport.controlFifoPath()

        guard let controlFD = AXFifoTransport.createAndOpenForReading(path: controlPath) else {
            FileHandle.standardError.write("AXHelper: could not create/open control FIFO at \(controlPath)\n".data(using: .utf8)!)
            exit(1)
        }

        Task {
            do {
                try await channel.start()
            } catch {
                FileHandle.standardError.write("AXHelper: channel.start() failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }

        let controlHandle = FileHandle(fileDescriptor: controlFD, closeOnDealloc: true)
        // Mutated only from this readabilityHandler callback, which
        // Foundation invokes serially (never concurrently with itself) on
        // its own dispatch queue — never touched from anywhere else, so
        // this is safe despite not being actor-isolated. Same escape hatch
        // used throughout this rewrite's history for identical reasons.
        nonisolated(unsafe) var buffer = Data()
        controlHandle.readabilityHandler = { handle in
            let data = handle.availableData
            // The control FIFO is opened O_RDWR by us specifically so this
            // never actually happens (see AXFifoTransport's doc comment) —
            // an empty read here would normally mean EOF, but this fd
            // counts as its own permanent writer.
            guard !data.isEmpty else { return }
            buffer.append(data)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                handleHello(line: line, channel: channel)
            }
        }

        RunLoop.main.run()
    }

    private struct Hello: Codable, Sendable {
        let reqPath: String
        let respPath: String

        enum CodingKeys: String, CodingKey {
            case reqPath = "req_path"
            case respPath = "resp_path"
        }
    }

    /// One hello → one self-contained task serving that specific
    /// request/response FIFO pair. `Task.detached` (not a plain `Task {}`)
    /// because the actual work is a sequence of blocking POSIX calls
    /// (open/read/write on the FIFOs) interleaved with the `await
    /// channel.execute(...)` call — detached keeps it off any
    /// actor's/thread 0's own execution context.
    private static func handleHello(line: String, channel: AccessibilityChannel) {
        guard let data = line.data(using: .utf8),
              let hello = try? JSONDecoder().decode(Hello.self, from: data) else {
            return
        }
        Task.detached(priority: .userInitiated) {
            await serveOneRequest(hello: hello, channel: channel)
        }
    }

    private static func serveOneRequest(hello: Hello, channel: AccessibilityChannel) async {
        let response: AXHelperProtocol.Response
        if let reqFD = AXFifoTransport.openForReading(path: hello.reqPath) {
            let requestLine = AXFifoTransport.readLine(fd: reqFD)
            close(reqFD)
            if let requestLine,
               let data = requestLine.data(using: .utf8),
               let request = try? JSONDecoder().decode(AXHelperProtocol.Request.self, from: data) {
                let result = await channel.execute(operation: request.operation, params: request.params)
                switch result {
                case .success(let message):
                    response = AXHelperProtocol.Response(kind: .success, message: message)
                case .error(let message):
                    response = AXHelperProtocol.Response(kind: .error, message: message)
                }
            } else {
                response = AXHelperProtocol.Response(kind: .error, message: "AXHelper: malformed or missing request line")
            }
        } else {
            response = AXHelperProtocol.Response(kind: .error, message: "AXHelper: could not open request FIFO")
        }

        guard let responseData = try? JSONEncoder().encode(response) else { return }
        guard let respFD = AXFifoTransport.openForWriting(path: hello.respPath) else { return }
        AXFifoTransport.writeLine(responseData, to: respFD)
        close(respFD)
    }
}
