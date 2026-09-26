import Foundation

/// What the server's synchronous guards need to know about Logic's UI, read by
/// the HELPER and published here.
///
/// The server runs under the App Sandbox, where its own Accessibility calls come
/// back nil — that is the whole reason the unsandboxed helper exists. Two server
/// guards were still reading AX directly and so failed closed while sandboxed:
/// the `expected_name` corroboration (`index_binding`, which blocked
/// load_preset with `header_unreadable`) and the blocking-dialog preflight.
/// Both are synchronous by construction, so they cannot await the helper at the
/// moment they run; instead the on-demand refresh that already precedes every
/// tool call and resource read (`ServerConfig.StatePollMode.onDemand`) fills
/// this box, and the guards read it.
///
/// Freshness is therefore "as of the refresh that preceded this call" — tens of
/// milliseconds, not live. That is enough for what these guards do: they are a
/// pre-write sanity check on the caller's assumptions. The write-time identity
/// checks that must be live stay live, inside the helper (load_preset's own
/// track-name guard, its plugin-name check and the readback).
///
/// `nil` names mean "not read", never "no tracks": an unread surface must keep
/// failing closed, exactly as an unreadable one did.
final class AXFacts: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var trackNames: [Int: String]?
        var blockingDialog: AXLogicProElements.BlockingDialogInfo?
        var updatedAt: Date?
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()

    init() {}

    var current: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Publish what one refresh cycle observed. A `nil` field is recorded as
    /// unread rather than dropped, so a failed read never leaves a stale value
    /// standing in for a live one.
    func update(trackNames: [Int: String]?, blockingDialog: AXLogicProElements.BlockingDialogInfo?) {
        lock.lock(); defer { lock.unlock() }
        snapshot = Snapshot(trackNames: trackNames, blockingDialog: blockingDialog, updatedAt: Date())
    }

    /// Forget everything: used when the surface goes away (no Logic window), so
    /// a guard never corroborates against names read before it vanished.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        snapshot = Snapshot()
    }

    var trackNames: [Int: String]? { current.trackNames }

    func trackName(at index: Int) -> String? { current.trackNames?[index] }

    var blockingDialog: AXLogicProElements.BlockingDialogInfo? { current.blockingDialog }

    var dialogPresent: Bool { current.blockingDialog != nil }
}
