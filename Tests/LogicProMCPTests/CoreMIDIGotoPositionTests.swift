import Foundation
import Testing

@testable import LogicProMCP

/// `transport.goto_position` over MMC LOCATE — the focus-free playhead move.
///
/// The property under test throughout is that this path never converts "I sent
/// bytes" into "it worked". MMC has no readback of its own; the verification
/// comes from an Accessibility read of Logic's bar slider, and anything short
/// of a confirmed landing must return a non-terminal error so `ChannelRouter`
/// falls through to the Accessibility path.
@Suite("CoreMIDI goto_position via MMC LOCATE")
struct CoreMIDIGotoPositionTests {

    /// A scripted sequence of transport readings, so a test can say "the
    /// playhead read bar 3 before the LOCATE and bar 12 after it".
    private final class BarReadings: @unchecked Sendable {
        private let lock = NSLock()
        private let values: [Int?]
        private let tempo: Double
        private var calls = 0

        init(_ values: [Int?], tempo: Double = 128) {
            self.values = values
            self.tempo = tempo
        }

        func next() -> TransportObserver.Reading? {
            lock.lock()
            defer { lock.unlock() }
            let value = values[min(calls, values.count - 1)]
            calls += 1
            guard let value else { return nil }
            return TransportObserver.Reading(bar: value, tempo: tempo)
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    /// Edgar's project, as measured live on 2026-09-05.
    private static let liveProject = ProjectSyncSettings(
        frameRate: .fps25, beatsPerBar: 4, smpteStartSeconds: 3600
    )

    private static func makeChannel(
        engine: MockCoreMIDIEngine,
        sync: ProjectSyncSettings? = liveProject,
        bars: BarReadings
    ) -> CoreMIDIChannel {
        CoreMIDIChannel(
            engine: engine,
            projectSync: sync,
            observeTransport: { bars.next() },
            sleepNanos: { _ in }   // no real waiting in tests
        )
    }

    private static func goto(_ channel: CoreMIDIChannel, bar: String) async -> ChannelResult {
        await channel.execute(operation: "transport.goto_position", params: ["bar": bar])
    }

    // MARK: - The safety property that gates the whole feature

    /// An unconfigured frame rate must put NOTHING on the wire.
    ///
    /// This is not a nicety. Logic compares the frame rate encoded in an
    /// incoming LOCATE against the project's own and, on a mismatch, raises a
    /// modal that blocks every later operation until a human clears it. A
    /// guessed rate therefore wedges the session rather than merely missing the
    /// bar — so "no configuration" has to mean "do not send", not "send 30 fps
    /// and hope".
    @Test("unconfigured frame rate sends no SysEx at all")
    func unconfiguredSendsNothing() async {
        let engine = MockCoreMIDIEngine(active: true)
        let bars = BarReadings([3])
        let channel = Self.makeChannel(engine: engine, sync: nil, bars: bars)

        let result = await Self.goto(channel, bar: "12")

        #expect(!result.isSuccess)
        #expect(await engine.sysexMessages.isEmpty, "a guessed frame rate can wedge the session")
        #expect(result.message.contains(ProjectSyncSettings.frameRateKey))
        // Must remain fallback-eligible, or the operation is simply dead.
        #expect(!HonestContract.isTerminalStateC(result.message))
    }

    // MARK: - Verified success

    @Test("a confirmed landing is State A and reports that focus was not taken")
    func confirmedLandingIsStateA() async throws {
        let engine = MockCoreMIDIEngine(active: true)
        // Read 3 before the LOCATE, 12 after it.
        let bars = BarReadings([3, 12])
        let channel = Self.makeChannel(engine: engine, bars: bars)

        let result = await Self.goto(channel, bar: "12")

        #expect(result.isSuccess)
        let obj = try #require(
            try JSONSerialization.jsonObject(
                with: Data(result.message.utf8)
            ) as? [String: Any]
        )
        #expect(obj["state"] as? String == "A")
        #expect(obj["method"] as? String == "mmc_locate")
        #expect(obj["observed"] as? String == "12.1.1.1")
        #expect(obj["stole_focus"] as? Bool == false)
        // The playhead genuinely moved, so the receipt must not claim otherwise.
        #expect(obj["already_at_target"] as? Bool == false)
    }

    /// Bar 12 at 128 BPM in 4/4 is 20.625 s after bar 1; with the project's
    /// 01:00:00:00 start that is 01:00:20:16 at 25 fps. The hours byte carries
    /// the frame rate in bits 5-6, so 25 fps makes it 0x01 | 0x20 = 0x21.
    @Test("the LOCATE on the wire carries the measured timecode and frame rate")
    func wireBytesMatchTheMeasuredLocate() async throws {
        let engine = MockCoreMIDIEngine(active: true)
        let bars = BarReadings([3, 12])
        let channel = Self.makeChannel(engine: engine, bars: bars)

        _ = await Self.goto(channel, bar: "12")

        let sent = await engine.sysexMessages
        #expect(sent.count == 1)
        let bytes = try #require(sent.first)
        #expect(bytes == [0xF0, 0x7F, 0x7F, 0x06, 0x44, 0x06, 0x01,
                          0x21, 0x00, 0x14, 0x10, 0x00, 0xF7])
    }

    /// Landing on a bar the playhead already occupied proves the position but
    /// not that the LOCATE caused it — a MIDI cable that goes nowhere reads
    /// identically. The receipt has to distinguish the two.
    @Test("already-at-target is State A but flagged, not silently claimed as a move")
    func alreadyAtTargetIsFlagged() async throws {
        let engine = MockCoreMIDIEngine(active: true)
        let bars = BarReadings([12, 12])
        let channel = Self.makeChannel(engine: engine, bars: bars)

        let result = await Self.goto(channel, bar: "12")

        #expect(result.isSuccess)
        let obj = try #require(
            try JSONSerialization.jsonObject(
                with: Data(result.message.utf8)
            ) as? [String: Any]
        )
        #expect(obj["state"] as? String == "A")
        #expect(obj["already_at_target"] as? Bool == true)
    }

    // MARK: - Everything unverified falls back rather than succeeding

    @Test("a landing on the wrong bar is an error, never a State B success")
    func wrongLandingFallsBack() async {
        let engine = MockCoreMIDIEngine(active: true)
        let bars = BarReadings([3, 11])   // the subframe-truncation failure
        let channel = Self.makeChannel(engine: engine, bars: bars)

        let result = await Self.goto(channel, bar: "12")

        #expect(!result.isSuccess)
        #expect(result.message.contains("bar 11"))
        #expect(!HonestContract.isTerminalStateC(result.message))
    }

    /// The anti-#440 property: a read that succeeds before the LOCATE but fails
    /// after it means UNVERIFIED, and an unverified send must not be dressed up
    /// as a State B success — State B would end the routing chain and leave the
    /// playhead wherever it actually is, which for a subsequent trim means
    /// cutting in the wrong place.
    @Test("losing the transport read after the send falls back, never reports success")
    func unreadableAfterSendFallsBack() async {
        let engine = MockCoreMIDIEngine(active: true)
        let bars = BarReadings([3, nil])   // readable before, gone after
        let channel = Self.makeChannel(engine: engine, bars: bars)

        let result = await Self.goto(channel, bar: "12")

        #expect(!result.isSuccess)
        #expect(result.message.contains("unverified"))
        #expect(!HonestContract.isTerminalStateC(result.message))
        // The LOCATE did go out — this is the "sent but unproven" case.
        #expect(await engine.sysexMessages.count == 1)
    }

    /// The helper is a separate process that can be down, unauthorised for
    /// Accessibility, or mid-restart. When it cannot answer, the tempo is
    /// unknown and the landing could not be verified anyway — so nothing is
    /// sent at all, rather than a LOCATE computed from a guessed tempo.
    @Test("an unreachable AX helper refuses before sending anything")
    func unreadableTransportSendsNothing() async {
        let engine = MockCoreMIDIEngine(active: true)
        let bars = BarReadings([nil])
        let channel = Self.makeChannel(engine: engine, bars: bars)

        let result = await Self.goto(channel, bar: "12")

        #expect(!result.isSuccess)
        #expect(await engine.sysexMessages.isEmpty)
        #expect(!HonestContract.isTerminalStateC(result.message))
    }

    @Test("a failed send is reported as a failure, not a success")
    func failedSendIsAFailure() async {
        let engine = MockCoreMIDIEngine(
            active: true,
            sendFailure: MockCoreMIDIHarnessError.sendFailed,
            sendFailureMode: .sysex
        )
        let bars = BarReadings([3, 12])   // slider would "confirm" — must not save it
        let channel = Self.makeChannel(engine: engine, bars: bars)

        let result = await Self.goto(channel, bar: "12")

        #expect(!result.isSuccess)
    }

    // MARK: - Accepted position spellings

    @Test("accepts the same bar spellings as the Accessibility path")
    func parsesPositionSpellings() {
        #expect(CoreMIDIChannel.parseTargetBar(["bar": "12"]) == 12)
        #expect(CoreMIDIChannel.parseTargetBar(["position": "12.1.1.1"]) == 12)
        #expect(CoreMIDIChannel.parseTargetBar(["position": "12"]) == 12)
        // Timecode belongs to `mmc.locate`, not here.
        #expect(CoreMIDIChannel.parseTargetBar(["position": "01:00:20:16"]) == nil)
        #expect(CoreMIDIChannel.parseTargetBar(["bar": "0"]) == nil)
        #expect(CoreMIDIChannel.parseTargetBar(["bar": "10000"]) == nil)
        #expect(CoreMIDIChannel.parseTargetBar([:]) == nil)
    }
}

@Suite("ProjectSyncSettings")
struct ProjectSyncSettingsTests {

    @Test("absent or unrecognised frame rate disables MMC positioning entirely")
    func absentFrameRateYieldsNil() {
        #expect(ProjectSyncSettings.fromEnvironment([:]) == nil)
        #expect(ProjectSyncSettings.fromEnvironment(
            [ProjectSyncSettings.frameRateKey: "48"]
        ) == nil)
    }

    @Test("reads the rate the way it is spelled in Logic's own pane")
    func parsesHumanSpellings() {
        #expect(ProjectSyncSettings.parseFrameRate("25") == .fps25)
        #expect(ProjectSyncSettings.parseFrameRate(" 24 ") == .fps24)
        #expect(ProjectSyncSettings.parseFrameRate("29.97 drop") == .fps29_97df)
        #expect(ProjectSyncSettings.parseFrameRate("30.0") == .fps30)
    }

    /// The other two default to Logic's own factory values — 4/4, bar 1 at
    /// 01:00:00:00 — because a wrong value there is self-correcting: the
    /// landing bar is verified, and a mismatch falls back.
    @Test("defaults match Logic's factory settings, not zero")
    func defaultsMatchLogic() throws {
        let settings = try #require(ProjectSyncSettings.fromEnvironment(
            [ProjectSyncSettings.frameRateKey: "25"]
        ))
        #expect(settings.beatsPerBar == 4)
        #expect(settings.smpteStartSeconds == 3600)
    }

    @Test("out-of-range overrides are ignored rather than honoured")
    func rejectsBadOverrides() throws {
        let settings = try #require(ProjectSyncSettings.fromEnvironment([
            ProjectSyncSettings.frameRateKey: "25",
            ProjectSyncSettings.beatsPerBarKey: "0",
            ProjectSyncSettings.smpteStartKey: "-5",
        ]))
        #expect(settings.beatsPerBar == 4)
        #expect(settings.smpteStartSeconds == 3600)
    }
}


/// The contract between what the AX helper returns and what we decode.
///
/// This suite exists because the original implementation read AX **directly
/// from the sandboxed server process**, where it silently returns nothing
/// forever. Every behavioural test still passed, because they inject a fake
/// observer. Only a test that pins the real envelope shape catches that class
/// of mistake — so this one encodes an actual `TransportState` exactly the way
/// `AccessibilityChannel.encodeResult` does, and decodes it back.
@Suite("TransportObserver decoding")
struct TransportObserverTests {

    private static func encodedTransportState(
        position: String, tempo: Double
    ) throws -> String {
        var state = TransportState()
        state.position = position
        state.tempo = tempo
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(state), as: UTF8.self)
    }

    @Test("decodes a real TransportState envelope end to end")
    func decodesRealEnvelope() throws {
        let payload = try Self.encodedTransportState(position: "12.1.1.1", tempo: 128)
        let reading = try #require(TransportObserver.parse(payload))
        #expect(reading.bar == 12)
        #expect(reading.tempo == 128)
    }

    /// JSONSerialization hands back NSNumber for whole-number tempi; an
    /// `as? Double` alone would drop 120 BPM and keep 128.5.
    @Test("a whole-number tempo survives decoding")
    func wholeNumberTempoSurvives() throws {
        let payload = try Self.encodedTransportState(position: "1.1.1.1", tempo: 120)
        let reading = try #require(TransportObserver.parse(payload))
        #expect(reading.tempo == 120)
    }

    @Test("refuses malformed, empty or nonsensical payloads instead of guessing")
    func refusesGarbage() {
        #expect(TransportObserver.parse("") == nil)
        #expect(TransportObserver.parse("not json") == nil)
        #expect(TransportObserver.parse("{}") == nil)
        #expect(TransportObserver.parse(#"{"position":"12.1.1.1"}"#) == nil)      // sin tempo
        #expect(TransportObserver.parse(#"{"tempo":128}"#) == nil)                // sin position
        #expect(TransportObserver.parse(#"{"position":"x.1.1.1","tempo":128}"#) == nil)
        #expect(TransportObserver.parse(#"{"position":"0.1.1.1","tempo":128}"#) == nil)
        #expect(TransportObserver.parse(#"{"position":"12.1.1.1","tempo":0}"#) == nil)
    }

    /// Stands in for the AX helper proxy, so the read path can be exercised
    /// without a helper process.
    private actor StubChannel: Channel {
        nonisolated let id: ChannelID = .accessibility
        private let result: ChannelResult
        init(_ result: ChannelResult) { self.result = result }
        func start() async throws {}
        func stop() async {}
        func execute(operation: String, params: [String: String]) async -> ChannelResult {
            result
        }
        func healthCheck() async -> ChannelHealth { .healthy(detail: "stub") }
    }

    /// A failed channel call is "unverified", never a default reading. This is
    /// the live case when the helper is down or has lost its Accessibility
    /// grant — which happens on every deploy, since TCC keys a Team-ID-less
    /// signature to the binary hash.
    @Test("an erroring channel yields nil, not a fabricated position")
    func erroringChannelYieldsNil() async {
        let channel = StubChannel(.error("helper unreachable"))
        #expect(await TransportObserver.read(via: channel) == nil)
    }

    @Test("a successful channel call decodes through to a reading")
    func successfulChannelDecodes() async throws {
        let payload = try Self.encodedTransportState(position: "17.1.1.1", tempo: 96)
        let channel = StubChannel(.success(payload))
        let reading = try #require(await TransportObserver.read(via: channel))
        #expect(reading.bar == 17)
        #expect(reading.tempo == 96)
    }
}
