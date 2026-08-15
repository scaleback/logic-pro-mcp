import Foundation
import LogicProMCP

// Batuta (Fase 3): the Accessibility channel, running WITHOUT App Sandbox.
//
// Why this exists: confirmed live (2026-08-15, see HANDOFF.md) that App
// Sandbox blocks kAXWindowsAttribute — reading another process's window
// list — even with Accessibility genuinely trusted. mainWindow() (and
// everything built on it: track selection, region enumeration, ...) fails
// closed under sandbox, and works when unsandboxed. Rather than dropping
// the sandbox on the whole server (losing the real, load-bearing "no
// network, kernel-enforced" guarantee for everything else — file I/O, MIDI,
// project parsing), only the Accessibility channel itself moves to this
// separate, minimal, unsandboxed helper process. Everything else — the
// server, the router, every other channel — stays exactly as sandboxed as
// before. See AXHelperProxyChannel.swift for the sandboxed side of this.
//
// Protocol: JSON Lines over stdin/stdout (AXHelperProtocol.swift, shared
// with the proxy channel so the two sides can't drift). One request in, one
// response out, per line, in order — no concurrent requests (matches how
// this process reads one stdin line at a time). EOF on stdin ends the
// process cleanly. This process holds NO privilege beyond
// com.apple.security.automation.apple-events (needed by AccessibilityChannel's
// AppleScript-backed helpers for a few operations) — no file entitlements,
// no network entitlements, nothing sandbox-scoped at all since it isn't
// sandboxed to begin with. It is exactly as auditable and single-purpose as
// the Channel protocol it implements.

@main
struct LogicProMCPAXHelperMain {
    static func main() async {
        let channel = AccessibilityChannel()
        do {
            try await channel.start()
        } catch {
            FileHandle.standardError.write("AXHelper: channel.start() failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let request = try? decoder.decode(AXHelperProtocol.Request.self, from: data) else {
                emit(AXHelperProtocol.Response(kind: .error, message: "AXHelper: malformed request line"), encoder: encoder)
                continue
            }

            let result = await channel.execute(operation: request.operation, params: request.params)
            let response: AXHelperProtocol.Response
            switch result {
            case .success(let message):
                response = AXHelperProtocol.Response(kind: .success, message: message)
            case .error(let message):
                response = AXHelperProtocol.Response(kind: .error, message: message)
            }
            emit(response, encoder: encoder)
        }

        await channel.stop()
    }

    private static func emit(_ response: AXHelperProtocol.Response, encoder: JSONEncoder) {
        guard let data = try? encoder.encode(response),
              var line = String(data: data, encoding: .utf8) else {
            print("{\"kind\":\"error\",\"message\":\"AXHelper: failed to encode response\"}")
            fflush(stdout)
            return
        }
        // A JSON-encoded string can never legally contain a raw, unescaped
        // newline byte (Foundation's JSONEncoder always escapes \n inside
        // string values as \\n) — this replace is a pure defense-in-depth
        // belt-and-suspenders, not a real code path, since a raw newline
        // here would mean the line-oriented framing is already broken.
        line = line.replacingOccurrences(of: "\n", with: " ")
        print(line)
        fflush(stdout)
    }
}
