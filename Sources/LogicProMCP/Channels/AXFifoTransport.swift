import Darwin
import Foundation

/// Batuta (Fase 3, 2026-08-16): shared low-level named-pipe (FIFO) helpers
/// for `AXHelperProxyChannel` (client, inside the sandboxed main process)
/// and `LogicProMCPAXHelper/main.swift` (server, launched independently by
/// launchd — never as a child of the sandboxed process).
///
/// Second transport for this same handoff, in one session — the full story
/// belongs in HANDOFF.md, but in short: `Process()` + `Pipe()` made the
/// helper a child of the sandboxed process, which broke `kAXWindowsAttribute`
/// for an ancestry reason unrelated to entitlements (see
/// AXHelperProxyChannel.swift's older doc comment). Moving to a Unix domain
/// socket fixed that, but the sandbox profile classifies `connect()` on
/// ANY socket — including a purely local `AF_UNIX` one — as
/// `network-outbound`, which requires `com.apple.security.network.client`.
/// Edgar deliberately chose NOT to add that entitlement (Fase 1's whole
/// point was a KERNEL-enforced "no network", not a code-review-enforced
/// one) and asked for FIFOs instead: `mkfifo`/`open`/`read`/`write` on a
/// named pipe are plain filesystem operations to the sandbox, governed by
/// the file entitlements this process already has
/// (`temporary-exception.files.home-relative-path.read-write: /`), not by
/// networking ones — confirmed live with a minimal sandboxed test binary
/// before committing to this rewrite.
///
/// Design: one long-lived "control" FIFO at a fixed path, always held open
/// by the helper (see `createAndOpenForReading` — the `O_RDWR` trick makes
/// the opener its own permanent writer, so `read()` never sees a spurious
/// EOF just because no OTHER writer happens to be connected at a given
/// moment). A client wanting to make one call: creates a fresh, uniquely
/// named request/response FIFO pair, opens its response FIFO the same
/// self-holding way, writes a one-line "here's where to find me" hello to
/// the control FIFO, then opens+writes the actual request to its request
/// FIFO. The helper's control-FIFO read loop spawns one task per hello to
/// serve that specific pair. Each call gets its own pair — simpler
/// lifecycle than a persistent per-client connection (no "is this client
/// still alive" bookkeeping), at the cost of a few extra syscalls per call,
/// which is a fine trade for how infrequently these operations actually
/// happen.
package enum AXFifoTransport {
    /// The real, non-sandbox-redirected home directory — `getpwuid`, not
    /// `NSHomeDirectory()`. Found live (during the earlier socket attempt):
    /// `NSHomeDirectory()` resolves to the sandbox CONTAINER path
    /// (`~/Library/Containers/<id>/Data`) for the sandboxed main process,
    /// so a path built from it would silently disagree with the
    /// launchd-parented (real-home) helper. `getpwuid` reads the passwd
    /// database directly, bypassing Foundation's sandbox-aware path
    /// virtualization entirely, so both sides agree on the same real path.
    package static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// Fixed, well-known path both sides agree on without any handshake.
    package static func controlFifoPath() -> String {
        realHomeDirectory() + "/.batuta-axhelper-control.fifo"
    }

    package static func requestFifoPath(id: String) -> String {
        realHomeDirectory() + "/.batuta-axhelper-req-\(id).fifo"
    }

    package static func responseFifoPath(id: String) -> String {
        realHomeDirectory() + "/.batuta-axhelper-resp-\(id).fifo"
    }

    /// Creates a fresh FIFO at `path` (removing any stale file left behind
    /// by a previous crashed run first — `mkfifo` fails on an existing
    /// path) and opens it `O_RDWR`. That open mode is the deliberate part:
    /// a FIFO opened `O_RDONLY` blocks until SOME writer connects, and once
    /// the writer COUNT drops back to zero, `read()` on that fd starts
    /// returning EOF permanently — even after a new writer later opens the
    /// same path — because the fd's EOF state doesn't reset. Opening
    /// `O_RDWR` makes this call's own fd count as a permanent writer to
    /// itself, so the writer count never drops to zero and reads never see
    /// a spurious EOF, for as long as this fd stays open.
    ///
    /// `O_NONBLOCK` is passed to `open()` only, to keep the OPEN CALL
    /// itself from blocking on a FIFO with no other end connected yet —
    /// then immediately cleared via `fcntl` before returning. Found live
    /// 2026-08-16: `O_NONBLOCK` is a file-status flag, not an open-time-only
    /// one — it silently applies to every SUBSEQUENT `read()` on this fd
    /// too, so a caller's later blocking-style `read()` would instead
    /// return `EAGAIN` immediately whenever no data happened to be ready
    /// yet, indistinguishable (to this code) from a real error, and gave up
    /// waiting for a response that was still legitimately on its way.
    package static func createAndOpenForReading(path: String) -> Int32? {
        unlink(path)
        guard mkfifo(path, 0o600) == 0 else { return nil }
        let fd = open(path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return fd
    }

    /// Creates a FIFO special file at `path` without opening it — for the
    /// request FIFO, which the CLIENT creates but the SERVER opens first
    /// (for reading); the client only opens it afterward, for writing.
    @discardableResult
    package static func createFifo(path: String) -> Bool {
        unlink(path)
        return mkfifo(path, 0o600) == 0
    }

    /// Opens an EXISTING fifo for writing. Blocks until a reader is present
    /// — fine for the control FIFO (the helper holds a reader open for its
    /// entire lifetime) and for a per-request FIFO once its creator has
    /// already opened the matching read end.
    package static func openForWriting(path: String) -> Int32? {
        let fd = open(path, O_WRONLY)
        return fd >= 0 ? fd : nil
    }

    /// Opens an EXISTING fifo for reading. Blocks until a writer is
    /// present.
    package static func openForReading(path: String) -> Int32? {
        let fd = open(path, O_RDONLY)
        return fd >= 0 ? fd : nil
    }

    /// Writes `data` followed by a newline to `fd`. Small, one-shot JSON
    /// lines — comfortably under `PIPE_BUF`, so this is never expected to
    /// need more than one `write()` call, but loops just in case.
    @discardableResult
    package static func writeLine(_ data: Data, to fd: Int32) -> Bool {
        var line = data
        line.append(0x0A)
        var offset = 0
        return line.withUnsafeBytes { rawPtr -> Bool in
            let base = rawPtr.baseAddress!
            while offset < rawPtr.count {
                let written = write(fd, base + offset, rawPtr.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Blocking read of raw bytes currently available on `fd` (a single
    /// `read()` call — the caller is expected to already be off the
    /// actor's/main thread's own execution context, since this can block).
    /// Returns `nil` on EOF or error.
    package static func readAvailable(fd: Int32, maxLength: Int = 65536) -> Data? {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
            read(fd, ptr.baseAddress, maxLength)
        }
        guard bytesRead > 0 else { return nil }
        return Data(buffer[0..<bytesRead])
    }

    /// Blocking read of one complete newline-terminated line from `fd`,
    /// looping `readAvailable` as needed — a single `read()` isn't
    /// guaranteed to return a whole line in one call (e.g. `region
    /// .get_regions` with many regions can exceed one read's worth of
    /// bytes). Returns `nil` on EOF/error before a newline was ever seen.
    package static func readLine(fd: Int32) -> String? {
        var buffer = Data()
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return String(data: buffer[..<newlineIndex], encoding: .utf8)
            }
            guard let chunk = readAvailable(fd: fd) else { return nil }
            buffer.append(chunk)
        }
    }
}
