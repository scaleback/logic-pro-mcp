import Foundation

/// The three project constants a bar → SMPTE conversion needs and that
/// Accessibility cannot read back from Logic.
///
/// These are *configured*, never guessed. Two of the three are merely wrong
/// when guessed, but the frame rate is actively dangerous: Logic compares the
/// rate encoded in an incoming LOCATE against the project's own and, on a
/// mismatch, raises a modal asking which to keep (measured live 2026-09-05 —
/// we sent 30 fps to a 25 fps project). That modal blocks every subsequent
/// operation until a human clears it, so a guessed rate does not merely
/// mis-position the playhead: it wedges the session.
///
/// Hence `fromEnvironment` returns `nil` when the frame rate is unset. A
/// caller holding `nil` must not send a LOCATE at all — which makes an
/// unconfigured install behave exactly as it did before MMC positioning
/// existed, rather than behaving worse.
struct ProjectSyncSettings: Sendable, Equatable {
    /// Must match the project's own SMPTE frame rate. See the type doc.
    let frameRate: MMCCommands.FrameRate
    /// Numerator of the project's time signature.
    let beatsPerBar: Int
    /// SMPTE time, in seconds, that the project maps to bar 1. Logic's factory
    /// default is 01:00:00:00 — i.e. 3600, not zero.
    let smpteStartSeconds: Double

    static let frameRateKey = "LOGIC_MCP_PROJECT_FPS"
    static let beatsPerBarKey = "LOGIC_MCP_PROJECT_BEATS_PER_BAR"
    static let smpteStartKey = "LOGIC_MCP_PROJECT_SMPTE_START"

    init(frameRate: MMCCommands.FrameRate, beatsPerBar: Int = 4, smpteStartSeconds: Double = 3600) {
        self.frameRate = frameRate
        self.beatsPerBar = beatsPerBar
        self.smpteStartSeconds = smpteStartSeconds
    }

    /// Parse the settings, or return `nil` if the frame rate is absent or
    /// unrecognised. The other two fall back to Logic's defaults (4/4, bar 1 at
    /// 01:00:00:00) because a wrong value there is self-correcting: the caller
    /// verifies the landing bar and falls back to a different channel.
    static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProjectSyncSettings? {
        guard let raw = env[frameRateKey], let rate = parseFrameRate(raw) else { return nil }

        var beatsPerBar = 4
        if let s = env[beatsPerBarKey], let n = Int(s), (1...32).contains(n) {
            beatsPerBar = n
        }

        var smpteStart = 3600.0
        if let s = env[smpteStartKey], let v = Double(s), v.isFinite, v >= 0, v < 86_400 {
            smpteStart = v
        }

        return ProjectSyncSettings(
            frameRate: rate, beatsPerBar: beatsPerBar, smpteStartSeconds: smpteStart
        )
    }

    /// Accepts the way a human reads the rate off Logic's own Synchronization
    /// pane ("25", "29.97 drop"), not an internal token.
    static func parseFrameRate(_ raw: String) -> MMCCommands.FrameRate? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "24", "24.0", "fps24": return .fps24
        case "25", "25.0", "fps25": return .fps25
        case "29.97", "29.97df", "29.97 drop", "fps29.97", "fps29_97df": return .fps29_97df
        case "30", "30.0", "fps30": return .fps30
        default: return nil
        }
    }
}
