import Foundation

/// Reads Logic's playhead bar and tempo for MMC LOCATE verification.
///
/// **Process boundary — the whole reason this type exists.** The MCP server
/// runs SANDBOXED and is not Accessibility-trusted; only the unsandboxed
/// `LogicProMCPAXHelper` LaunchAgent may touch `AXUIElement` at all. So a read
/// from server code has to travel through `AXHelperProxyChannel` over FIFOs.
///
/// Calling the AX APIs directly from the server instead does not crash and
/// does not log — it just returns nothing, forever. That failure mode is
/// especially treacherous here: this observer feeds the *verification* half of
/// `transport.goto_position`, so a direct-AX version degrades silently into
/// "never verified → always fall back", leaving the focus-free path dead while
/// every test that injects a fake observer stays green. It was written that way
/// once (2026-09-05) and caught only when the helper failed to start for an
/// unrelated reason. Route every read through the helper.
///
/// One round trip returns both values, which is why this is a single call
/// rather than separate bar and tempo reads: each FIFO round trip costs real
/// time, and the pre-LOCATE read needs both anyway.
enum TransportObserver {

    struct Reading: Sendable, Equatable {
        /// 1-indexed bar the playhead currently sits on.
        let bar: Int
        /// Project tempo in BPM. Read rather than configured because, unlike
        /// the SMPTE frame rate, it is both readable and routinely changed.
        let tempo: Double
    }

    /// Ask the helper for the transport state and decode it.
    /// Returns `nil` on any failure — callers must treat that as "unverified",
    /// never as "unchanged".
    static func read(via channel: any Channel) async -> Reading? {
        let result = await channel.execute(operation: "transport.get_state", params: [:])
        guard case let .success(payload) = result else { return nil }
        return parse(payload)
    }

    /// Decode a `TransportState` envelope. Split out from `read` so the
    /// parsing is testable without a helper process.
    static func parse(_ payload: String) -> Reading? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // `position` is Logic's "Bar.Beat.Division.Tick"; only the bar matters
        // for a bar-granular locate.
        guard let position = object["position"] as? String,
              let barField = position.split(separator: ".").first,
              let bar = Int(barField), bar >= 1
        else { return nil }

        guard let tempo = numeric(object["tempo"]), tempo > 0 else { return nil }
        return Reading(bar: bar, tempo: tempo)
    }

    /// JSONSerialization hands back `NSNumber` for both integral and
    /// fractional tempi, so an `as? Double` alone drops whole-number BPM.
    private static func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
