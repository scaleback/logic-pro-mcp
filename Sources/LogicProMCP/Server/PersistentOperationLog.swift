import Darwin
import Foundation

/// Batuta (Fase 1): "Bitácora de auditoría: toda operación queda registrada
/// localmente con qué canal usó. Es lo que permite responder '¿qué hizo
/// esto?' sin adivinar." (PLAN.md).
///
/// `OperationTraceStore` already tracks this per-operation, in detail — but
/// only in memory, cleared on every process restart (documented in
/// `logic_system.help`). That answers "what is this doing right now", not
/// "what did this do last week". This adds the durable half: one compact
/// JSON line per completed operation, appended to disk.
///
/// Hooked from `DispatcherSupport.finalizeTrace`, the single choke point
/// every dispatcher already funnels through — so this covers every tool
/// call without touching each of the ~10 dispatchers individually. Mirrors
/// the append-only, fd-relative, no-follow write pattern
/// `SystemDispatcher.appendTraceClearAuditLine` already uses for
/// `trace-clear.log`: same directory root, same `SecureFD` primitives, same
/// durability shape — a different file because the two logs answer
/// different questions and neither should get harder to read by sharing a
/// stream with the other.
enum PersistentOperationLog {
    enum LogError: Error {
        case encodingFailed
        case writeFailed
    }

    /// Same root as the trace-clear receipt log: one audit directory for
    /// everything this server durably records about its own operations.
    static var logURL: URL {
        SystemDispatcher.auditLogRoot.appendingPathComponent("operations.log", isDirectory: false)
    }

    /// Best-effort by design: a failure to append this line must never fail
    /// the operation it is recording, and must never be surfaced to the MCP
    /// caller as part of that operation's result. This is the opposite
    /// tradeoff from the trace-clear receipt, which fails closed on purpose
    /// — losing the record of evidence destruction is the failure that must
    /// never silently pass. Losing one routine operations-log line to a
    /// rare disk I/O error is not in the same class; log a warning and move on.
    static func record(_ trace: OperationTrace, isError: Bool) async {
        do {
            try appendLine(fields(for: trace, isError: isError))
        } catch {
            Log.warn("Failed to append persistent operation log line: \(error)", subsystem: .server)
        }
    }

    private static func fields(for trace: OperationTrace, isError: Bool) -> [String: Any] {
        var channelsAttempted: [String] = []
        var channelUsed: String?
        var readbackState: String?
        var errorCode: String?

        for event in trace.events {
            switch event.phase {
            case .channelStarted:
                if let channel = event.attributes["channel"] {
                    channelsAttempted.append(channel)
                }
            case .channelCompleted:
                // The chain can retry through several channels after an
                // early failure (§ChannelRouter.route); the one whose
                // "outcome" is "success" is the one that actually handled
                // the operation. A chain that never succeeds leaves this nil
                // — honest, not a guess at which failed attempt to blame.
                if event.attributes["outcome"] == "success", let channel = event.attributes["channel"] {
                    channelUsed = channel
                }
            case .verificationCompleted:
                readbackState = event.attributes["readback_state"] ?? readbackState
                errorCode = event.attributes["error_code"] ?? errorCode
            default:
                break
            }
        }

        var result: [String: Any] = [
            "ts": ISO8601DateFormatter.cacheFormatter.string(from: Date()),
            "trace_id": trace.traceID.rawValue,
            "operation": trace.operationID,
            "channels_attempted": channelsAttempted,
            "success": !isError,
        ]
        if let channelUsed { result["channel_used"] = channelUsed }
        if let readbackState { result["state"] = readbackState }
        if let errorCode { result["error_code"] = errorCode }
        return result
    }

    /// Append-only, fd-relative, no-follow write — identical safety
    /// properties to `SystemDispatcher.appendTraceClearAuditLine`, minus the
    /// fsync/dir-fsync durability step (see the doc comment above on why
    /// this log tolerates best-effort instead of fail-closed).
    private static func appendLine(_ fields: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else {
            throw LogError.encodingFailed
        }
        let bytes = Array((line + "\n").utf8)

        let (baseFD, relative) = try SecureFD.openTrustedBase(for: logURL)
        defer { close(baseFD) }
        guard let logName = relative.last else { throw LogError.encodingFailed }
        let dirFD = try SecureFD.ensureDirectory(
            baseFD: baseFD, components: Array(relative.dropLast()), mode: 0o700
        )
        defer { close(dirFD) }

        let fileFD: Int32
        do {
            let fd = try SecureFD.createFile(parentFD: dirFD, name: logName, mode: 0o600)
            let flags = fcntl(fd, F_GETFL)
            guard flags != -1, fcntl(fd, F_SETFL, flags | O_APPEND) != -1 else {
                close(fd)
                throw LogError.writeFailed
            }
            fileFD = fd
        } catch SecureFD.FDError.componentOpenFailed(_, let e) where e == EEXIST {
            fileFD = try SecureFD.openAppend(parentFD: dirFD, name: logName)
        }
        defer { close(fileFD) }

        let written = bytes.withUnsafeBytes { Darwin.write(fileFD, $0.baseAddress, $0.count) }
        guard written == bytes.count else { throw LogError.writeFailed }
    }
}
