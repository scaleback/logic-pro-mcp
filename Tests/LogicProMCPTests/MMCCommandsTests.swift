import Foundation
import Testing
@testable import LogicProMCP

@Suite("MMCCommands")
struct MMCCommandsTests {

    // MARK: - New no-arg commands

    @Test("deferredPlay emits SysEx with command byte 0x03")
    func deferredPlayBytes() {
        #expect(MMCCommands.deferredPlay() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x03, 0xF7])
    }

    @Test("reset emits SysEx with command byte 0x0D")
    func resetBytes() {
        #expect(MMCCommands.reset() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x0D, 0xF7])
    }

    @Test("write emits SysEx with command byte 0x40")
    func writeBytes() {
        #expect(MMCCommands.write() == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x40, 0xF7])
    }

    // MARK: - goto (memory locate)

    @Test("goto emits 0x44 0x01 + target byte")
    func gotoTargetBytes() throws {
        let bytes = try MMCCommands.goto(target: 0x05)
        #expect(bytes == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x44, 0x01, 0x05, 0xF7])
    }

    @Test("goto rejects target > 0x7F")
    func gotoRejectsHighTarget() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.goto(target: 0x80)
        }
    }

    @Test("goto accepts deviceID 0x7F (broadcast)")
    func gotoAcceptsBroadcast() throws {
        let bytes = try MMCCommands.goto(target: 0x01, deviceID: 0x7F)
        #expect(bytes[2] == 0x7F)
    }

    // MARK: - locateStrict input validation

    @Test("locateStrict rejects hours > 23")
    func locateRejectsHours24() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 24, minutes: 0, seconds: 0, frames: 0)
        }
    }

    @Test("locateStrict rejects minutes > 59")
    func locateRejectsMinutes60() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 0, minutes: 60, seconds: 0, frames: 0)
        }
    }

    @Test("locateStrict rejects seconds > 59")
    func locateRejectsSeconds60() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 0, minutes: 0, seconds: 60, frames: 0)
        }
    }

    @Test("locateStrict rejects frames = 30 at 30fps (max frame index is 29)")
    func locateRejectsFrames30At30fps() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 0, minutes: 0, seconds: 0, frames: 30, frameRate: .fps30)
        }
    }

    @Test("locateStrict rejects subframes > 99")
    func locateRejectsSubframes100() {
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 0, minutes: 0, seconds: 0, frames: 0, subframes: 100)
        }
    }

    @Test("locateStrict at 24fps boundary: frames=23 OK, frames=24 rejected")
    func locate24fpsBoundary() throws {
        _ = try MMCCommands.locateStrict(hours: 0, minutes: 0, seconds: 0, frames: 23, frameRate: .fps24)
        #expect(throws: MMCCommands.MMCError.self) {
            _ = try MMCCommands.locateStrict(hours: 0, minutes: 0, seconds: 0, frames: 24, frameRate: .fps24)
        }
    }

    // MARK: - Frame rate encoding in hours byte

    @Test("locateStrict encodes 24fps in hours bits 5-6 as 00")
    func frameRate24Encoding() throws {
        let bytes = try MMCCommands.locateStrict(hours: 1, minutes: 2, seconds: 3, frames: 4, frameRate: .fps24)
        // hours byte is at index 7. 0b00_xxxxx for 24fps
        #expect(bytes[7] & 0b0110_0000 == 0)
        #expect(bytes[7] & 0b0001_1111 == 1)
    }

    @Test("locateStrict encodes 25fps in hours bits 5-6 as 01")
    func frameRate25Encoding() throws {
        let bytes = try MMCCommands.locateStrict(hours: 2, minutes: 0, seconds: 0, frames: 0, frameRate: .fps25)
        #expect(bytes[7] & 0b0110_0000 == 0b0010_0000)
        #expect(bytes[7] & 0b0001_1111 == 2)
    }

    @Test("locateStrict encodes 29.97df in hours bits 5-6 as 10")
    func frameRate2997dfEncoding() throws {
        let bytes = try MMCCommands.locateStrict(hours: 3, minutes: 0, seconds: 0, frames: 0, frameRate: .fps29_97df)
        #expect(bytes[7] & 0b0110_0000 == 0b0100_0000)
    }

    @Test("locateStrict encodes 30fps in hours bits 5-6 as 11")
    func frameRate30Encoding() throws {
        let bytes = try MMCCommands.locateStrict(hours: 4, minutes: 0, seconds: 0, frames: 0, frameRate: .fps30)
        #expect(bytes[7] & 0b0110_0000 == 0b0110_0000)
    }

    // MARK: - bar/beat → SMPTE

    @Test("barBeatToSMPTE: bar 1 beat 1 is zero position")
    func barBeatZero() throws {
        let smpte = try #require(MMCCommands.barBeatToSMPTE(
            bar: 1, beat: 1.0, tempo: 120, beatsPerBar: 4
        ))
        #expect(smpte.hours == 0)
        #expect(smpte.minutes == 0)
        #expect(smpte.seconds == 0)
        #expect(smpte.frames == 0)
    }

    @Test("barBeatToSMPTE: bar 2 beat 1 at 120bpm 4/4 = 2 seconds")
    func barBeatTwoBarsAt120() throws {
        let smpte = try #require(MMCCommands.barBeatToSMPTE(
            bar: 2, beat: 1.0, tempo: 120, beatsPerBar: 4
        ))
        #expect(smpte.hours == 0)
        #expect(smpte.minutes == 0)
        #expect(smpte.seconds == 2)
    }

    @Test("barBeatToSMPTE: bar 61 at 120bpm 4/4 = 2 minutes")
    func barBeatTwoMinutes() throws {
        let smpte = try #require(MMCCommands.barBeatToSMPTE(
            bar: 61, beat: 1.0, tempo: 120, beatsPerBar: 4
        ))
        #expect(smpte.minutes == 2)
        #expect(smpte.seconds == 0)
    }

    @Test("barBeatToSMPTE rejects invalid inputs")
    func barBeatInvalidInputs() {
        #expect(MMCCommands.barBeatToSMPTE(bar: 0, beat: 1.0, tempo: 120, beatsPerBar: 4) == nil)
        #expect(MMCCommands.barBeatToSMPTE(bar: 1, beat: 0.5, tempo: 120, beatsPerBar: 4) == nil)
        #expect(MMCCommands.barBeatToSMPTE(bar: 1, beat: 1.0, tempo: 0, beatsPerBar: 4) == nil)
        #expect(MMCCommands.barBeatToSMPTE(bar: 1, beat: 1.0, tempo: 120, beatsPerBar: 0) == nil)
    }

    @Test("barBeatToSMPTE caps at 24h SMPTE limit")
    func barBeatExceeds24h() {
        // At 1 bpm 1/1, bar 86401 = 86400 beats = 86400 sec = exactly 24h
        let result = MMCCommands.barBeatToSMPTE(bar: 86_402, beat: 1.0, tempo: 1, beatsPerBar: 1)
        #expect(result == nil)
    }

    // MARK: - Back-compat: existing byte layout unchanged

    @Test("existing locate output is unchanged (byte equality)")
    func existingLocateUnchanged() {
        let bytes = MMCCommands.locate(hours: 1, minutes: 2, seconds: 3, frames: 4, subframes: 5)
        #expect(bytes == [0xF0, 0x7F, ServerConfig.mmcDeviceID, 0x06, 0x44, 0x06, 0x01, 1, 2, 3, 4, 5, 0xF7])
    }
}

// MARK: - Live-measured corrections (2026-09-05, Edgar's project)
//
// Both cases below are transcriptions of a real failed locate, not invented
// arithmetic. The project: 128 bpm, 4/4, 25 fps, bar 1 mapped to SMPTE
// 01:00:00:00 (Logic's factory default, visible in Project Settings →
// Synchronization → General as "Bar Position 1 1 1 1 plays at SMPTE
// 01:00:00:00").

/// Bar 1 is not necessarily SMPTE zero. Assuming it was put the playhead a
/// negative bar away — roughly an hour before the project start — which is
/// what a locate computed without the offset actually did.
@Test("barBeatToSMPTE: honours the project's SMPTE start offset")
func barBeatToSMPTEHonoursStartOffset() throws {
    let withOffset = try #require(MMCCommands.barBeatToSMPTE(
        bar: 12, beat: 1.0, tempo: 128, beatsPerBar: 4,
        frameRate: .fps25, smpteStartSeconds: 3600
    ))
    #expect(withOffset.hours == 1)
    #expect(withOffset.minutes == 0)
    #expect(withOffset.seconds == 20)

    // Same musical position, no offset: one hour earlier on the wire.
    let withoutOffset = try #require(MMCCommands.barBeatToSMPTE(
        bar: 12, beat: 1.0, tempo: 128, beatsPerBar: 4, frameRate: .fps25
    ))
    #expect(withoutOffset.hours == 0)
    #expect(withoutOffset.seconds == 20)
}

/// The 25 ms that landed a trim in the wrong bar.
///
/// Bar 12 at 128 bpm is 20.625 s = 515.625 frames at 25 fps. Flooring gives
/// frame 15 and pushes .625 into the subframe byte — which Logic discards, so
/// the playhead landed at 20.600 s: bar 11 beat 4, one beat short of the
/// target, and a trim there cuts in the wrong place. Rounding to the nearest
/// frame (16) lands inside bar 12.
@Test("barBeatToSMPTE: rounds to the nearest frame instead of truncating")
func barBeatToSMPTERoundsToNearestFrame() throws {
    let smpte = try #require(MMCCommands.barBeatToSMPTE(
        bar: 12, beat: 1.0, tempo: 128, beatsPerBar: 4, frameRate: .fps25
    ))
    #expect(smpte.seconds == 20)
    #expect(smpte.frames == 16, "15 + discarded subframes lands in the previous bar")
    // Subframes are reported as zero: the rounding already carries that
    // precision, and a receiver that ignores them (Logic) must still land right.
    #expect(smpte.subframes == 0)
}

/// Rounding must carry into the next second rather than emitting an
/// out-of-range frame number.
@Test("barBeatToSMPTE: frame rounding carries into seconds")
func barBeatToSMPTERoundingCarries() throws {
    // 0.999 s at 25 fps = 24.975 frames → rounds to 25, which is not a legal
    // frame number; it must become the next whole second, frame 0.
    let tempo = 60.0 * 4.0 / 0.999   // one bar of 4/4 == 0.999 s
    let smpte = try #require(MMCCommands.barBeatToSMPTE(
        bar: 2, beat: 1.0, tempo: tempo, beatsPerBar: 4, frameRate: .fps25
    ))
    #expect(smpte.seconds == 1)
    #expect(smpte.frames == 0)
}

@Test("barBeatToSMPTE: rejects a negative or non-finite start offset")
func barBeatToSMPTERejectsBadOffset() {
    #expect(MMCCommands.barBeatToSMPTE(
        bar: 1, beat: 1.0, tempo: 120, beatsPerBar: 4, smpteStartSeconds: -1
    ) == nil)
    #expect(MMCCommands.barBeatToSMPTE(
        bar: 1, beat: 1.0, tempo: 120, beatsPerBar: 4, smpteStartSeconds: .infinity
    ) == nil)
}
