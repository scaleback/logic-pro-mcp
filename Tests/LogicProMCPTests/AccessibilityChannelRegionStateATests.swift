@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// v3.1.3 backlog #3 — `region.move_to_playhead` and `region.select_last`
// State A coverage. Both ops were State B (`readback_unavailable`) in v3.1.0
// because the AppleScript-driven menu/click path didn't have a way to verify
// the resulting region position. v3.1.3 adds a pre/post AX snapshot via
// `selectedRegionInfo` + `currentPlayheadBar` (move) and
// `selectedRegionInfo` + `lastRegionInfo` (select_last) so the same
// operations can return State A `verified:true` when read-back matches.

// MARK: - Helpers

private func decodeJSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}

/// Build a Logic-shaped AX tree with:
///   window
///   ├── headerRail (트랙 헤더) → trackHeaders
///   ├── transport (Transport group) → position static text
///   └── contentGroup (트랙 콘텐츠) → regions (AXLayoutItem)
///
/// `regions` is `(name, help, position, size, selected)`. `headers` is
/// `(position, size)`. `playheadPosition` is the "Bar.Beat.Division.Tick"
/// value extracted from the transport bar.
private struct RegionFakeFixture {
    let builder: FakeAXRuntimeBuilder
    let runtime: AXLogicProElements.Runtime
}

private func makeRegionFixture(
    builder externalBuilder: FakeAXRuntimeBuilder? = nil,
    headers: [(pos: AXValue, size: AXValue)],
    regions: [(name: String, help: String, pos: AXValue, size: AXValue, selected: Bool)],
    playheadPosition: String,
    performActionHandler: (@Sendable (AXUIElement, String) -> Bool)? = nil
) -> RegionFakeFixture {
    let builder = externalBuilder ?? FakeAXRuntimeBuilder()
    let app = builder.element(1_000)
    let window = builder.element(1_001)
    let headerRail = builder.element(1_002)
    let contentGroup = builder.element(1_003)
    let transport = builder.element(1_004)
    let positionText = builder.element(1_005)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)

    builder.setAttribute(headerRail, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(headerRail, kAXDescriptionAttribute as String, "트랙 헤더")
    let headerEls: [AXUIElement] = headers.enumerated().map { idx, h in
        let el = builder.element(2_000 + idx)
        builder.setAttribute(el, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(el, kAXPositionAttribute as String, h.pos)
        builder.setAttribute(el, kAXSizeAttribute as String, h.size)
        return el
    }
    builder.setChildren(headerRail, headerEls)

    builder.setAttribute(contentGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(contentGroup, kAXDescriptionAttribute as String, "트랙 콘텐츠")
    let regionEls: [AXUIElement] = regions.enumerated().map { idx, r in
        let el = builder.element(3_000 + idx)
        builder.setAttribute(el, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        builder.setAttribute(el, kAXDescriptionAttribute as String, r.name)
        builder.setAttribute(el, kAXHelpAttribute as String, r.help)
        builder.setAttribute(el, kAXPositionAttribute as String, r.pos)
        builder.setAttribute(el, kAXSizeAttribute as String, r.size)
        builder.setAttribute(el, kAXSelectedAttribute as String, r.selected)
        return el
    }
    builder.setChildren(contentGroup, regionEls)

    // Transport: matches looksLikeTransportContainer via "Transport" identifier.
    builder.setAttribute(transport, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(transport, kAXIdentifierAttribute as String, "Transport")
    builder.setAttribute(positionText, kAXRoleAttribute as String, kAXStaticTextRole as String)
    builder.setAttribute(positionText, kAXDescriptionAttribute as String, "Position")
    builder.setAttribute(positionText, kAXValueAttribute as String, playheadPosition)
    builder.setChildren(transport, [positionText])

    builder.setChildren(window, [headerRail, transport, contentGroup])

    return RegionFakeFixture(
        builder: builder,
        runtime: builder.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: nil,
            performActionHandler: performActionHandler
        )
    )
}

/// Adds a fake Edit > Bounce or Join > Bounce Regions in Place… menu tree to
/// `app`, matching what `defaultBounceRegionInPlace` resolves via
/// `AXLocalePolicy.bounceRegionsInPlaceMenuPath`. Element IDs are in the
/// 4_000s range to stay clear of the header (2_000s) and region (3_000s)
/// ranges `makeRegionFixture` already uses.
@discardableResult
private func addBounceMenu(
    to builder: FakeAXRuntimeBuilder,
    app: AXUIElement,
    enabled: Bool = true
) -> AXUIElement {
    let menuBar = builder.element(4_000)
    let editBarItem = builder.element(4_001)
    let editMenu = builder.element(4_002)
    let bounceOrJoinItem = builder.element(4_003)
    let bounceOrJoinSubmenu = builder.element(4_004)
    let bounceMenuItem = builder.element(4_005)

    builder.setAttribute(editBarItem, kAXTitleAttribute as String, "Edit")
    builder.setChildren(editBarItem, [editMenu])

    builder.setAttribute(bounceOrJoinItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
    builder.setAttribute(bounceOrJoinItem, kAXTitleAttribute as String, "Bounce or Join")
    builder.setChildren(bounceOrJoinItem, [bounceOrJoinSubmenu])
    builder.setChildren(editMenu, [bounceOrJoinItem])

    builder.setAttribute(bounceMenuItem, kAXRoleAttribute as String, kAXMenuItemRole as String)
    builder.setAttribute(bounceMenuItem, kAXTitleAttribute as String, "Bounce Regions in Place…")
    builder.setAttribute(bounceMenuItem, kAXEnabledAttribute as String, enabled)
    builder.setChildren(bounceOrJoinSubmenu, [bounceMenuItem])

    builder.setChildren(menuBar, [editBarItem])
    builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)

    return bounceMenuItem
}

// MARK: - region.move_to_playhead — State A path

@Test func testMoveToPlayheadReturnsStateAOnMatch() async {
    // Pre: selected region at bar 1. Action moves it to bar 9 (matching
    // playhead). Post-read should expose post.startBar=9 and playhead=9 →
    // State A verified:true.
    let preHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let postHelp = "리전은 9 마디 에서 시작하여 11 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA",
            help: preHelp,
            pos: axPoint(240, 108),
            size: axSize(320, 24),
            selected: true
        )],
        playheadPosition: "9.1.1.1"
    )

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in
            // Simulate Logic moving the region to bar 9 by rewriting the
            // AXHelp text the parser reads.
            fixture.builder.setAttribute(
                fixture.builder.element(3_000),
                kAXHelpAttribute as String,
                postHelp
            )
            return .success("OK")
        },
        settle: { /* skip in tests */ }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["pre_start_bar"] as? Int == 1)
    #expect(obj["post_start_bar"] as? Int == 9)
    #expect(obj["playhead_bar"] as? Int == 9)
    #expect(obj["requested"] as? Int == 9)
    #expect(obj["observed"] as? Int == 9)
}

@Test func testMoveToPlayheadReturnsStateBOnMismatch() async {
    // Pre: bar 1. Action moves region to bar 5 but playhead is at bar 9 →
    // post.startBar(5) ≠ playhead(9) → State B readback_mismatch.
    let preHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let postHelp = "리전은 5 마디 에서 시작하여 7 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA",
            help: preHelp,
            pos: axPoint(240, 108),
            size: axSize(320, 24),
            selected: true
        )],
        playheadPosition: "9.1.1.1"
    )

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in
            fixture.builder.setAttribute(
                fixture.builder.element(3_000),
                kAXHelpAttribute as String,
                postHelp
            )
            return .success("OK")
        },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["pre_start_bar"] as? Int == 1)
    #expect(obj["post_start_bar"] as? Int == 5)
    #expect(obj["playhead_bar"] as? Int == 9)
}

@Test func testMoveToPlayheadReturnsStateBOnNoChange() async {
    // Pre==Post → menu was a no-op. State B readback_mismatch with note.
    let staticHelp = "리전은 4 마디 에서 시작하여 6 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA",
            help: staticHelp,
            pos: axPoint(240, 108),
            size: axSize(320, 24),
            selected: true
        )],
        playheadPosition: "9.1.1.1"
    )

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in .success("OK") },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["pre_start_bar"] as? Int == 4)
    #expect(obj["post_start_bar"] as? Int == 4)
    #expect(((obj["note"] as? String)?.contains("no position change"))!)
}

@Test func testMoveToPlayheadReturnsStateBWhenNoSelectedRegion() async {
    // No region has AXSelected=true → cannot snapshot pre-state →
    // State B readback_unavailable.
    let help = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA",
            help: help,
            pos: axPoint(240, 108),
            size: axSize(320, 24),
            selected: false
        )],
        playheadPosition: "9.1.1.1"
    )

    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in .success("OK") },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_unavailable")
}

@Test func testMoveToPlayheadReturnsStateCOnMenuError() async {
    let fixture = makeRegionFixture(
        headers: [],
        regions: [],
        playheadPosition: "1.1.1.1"
    )
    let result = await AccessibilityChannel.defaultMoveSelectedRegionToPlayhead(
        runtime: fixture.runtime,
        executeScript: { _ in .success("MENU_ERROR: not found") },
        settle: { }
    )
    #expect(!result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "ax_write_failed")
}

// MARK: - region.select_last — State A path

@Test func testSelectLastReturnsStateAOnMatch() async {
    // Two regions; the second (bar 5) is the last. AppleScript executor
    // simulates Logic selecting it. Post-read finds AXSelected on the
    // last region → State A.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 5 마디 에서 시작하여 7 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: false),
            (name: "RegionB", help: regionBHelp,
             pos: axPoint(400, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        executeScript: { _ in
            // Logic flipped AXSelected=true on RegionB.
            fixture.builder.setAttribute(
                fixture.builder.element(3_001),
                kAXSelectedAttribute as String,
                true
            )
            return .success("SELECTED")
        },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["expected_name"] as? String == "RegionB")
    #expect(obj["selected_name"] as? String == "RegionB")
    #expect(obj["expected_start_bar"] as? Int == 5)
    #expect(obj["selected_start_bar"] as? Int == 5)
}

@Test func testSelectLastFailsClosedWhenAXSelectedWriteFails() async {
    // Order-7 coordinate-free campaign: the former `click at {center}` fallback
    // after a failed AXSelected write was REMOVED. A SELECT_FAILED marker from
    // the script must fail closed (State C ax_write_failed) with no fallback —
    // never a fabricated success.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        executeScript: { _ in .success("SELECT_FAILED") },
        settle: { }
    )

    #expect(!result.isSuccess)
    let obj = decodeJSON(result.message)
    let success = (obj["success"] as? Bool)!
    #expect(!success)
    #expect(obj["error"] as? String == "ax_write_failed")
    let hint = obj["hint"] as? String ?? ""
    #expect(hint.contains("no fallback"))
}

@Test func testSelectLastReturnsStateBOnMismatch() async {
    // AppleScript flips selection on the WRONG region (RegionA / bar 1)
    // even though "last" is RegionB / bar 5 → State B readback_mismatch.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 5 마디 에서 시작하여 7 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: false),
            (name: "RegionB", help: regionBHelp,
             pos: axPoint(400, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        executeScript: { _ in
            fixture.builder.setAttribute(
                fixture.builder.element(3_000),  // RegionA — the wrong one
                kAXSelectedAttribute as String,
                true
            )
            return .success("SELECTED")
        },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["expected_name"] as? String == "RegionB")
    #expect(obj["selected_name"] as? String == "RegionA")
}

@Test func testSelectLastReturnsStateBWhenNoSelectionPostAction() async {
    // Script returns SELECTED but never flipped AXSelected (read-back fails)
    // → State B readback_unavailable.
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "RegionA", help: regionAHelp,
             pos: axPoint(100, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        executeScript: { _ in .success("SELECTED") },
        settle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect(!((obj["verified"] as? Bool)!))
    #expect(obj["reason"] as? String == "readback_unavailable")
    #expect(obj["expected_name"] as? String == "RegionA")
}

@Test func testSelectLastReturnsStateCWhenNoRegions() async {
    let fixture = makeRegionFixture(
        headers: [],
        regions: [],
        playheadPosition: "1.1.1.1"
    )

    let result = await AccessibilityChannel.defaultSelectLastRegion(
        runtime: fixture.runtime,
        executeScript: { _ in .success("NO_REGION") },
        settle: { }
    )

    #expect(!result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect(!((obj["success"] as? Bool)!))
    #expect(obj["error"] as? String == "element_not_found")
}

// MARK: - Helpers

@Test func testCurrentPlayheadBarParsesPositionString() {
    let fixture = makeRegionFixture(
        headers: [],
        regions: [],
        playheadPosition: "12.3.4.5"
    )
    #expect(AccessibilityChannel.currentPlayheadBar(runtime: fixture.runtime) == 12)
}

@Test func testLastRegionInfoReturnsLargestStartBar() {
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 7 마디 에서 시작하여 9 마디 에서 끝납니다., MIDI 리전."
    let regionCHelp = "리전은 4 마디 에서 시작하여 6 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "A", help: regionAHelp, pos: axPoint(100, 108), size: axSize(160, 24), selected: false),
            (name: "B", help: regionBHelp, pos: axPoint(400, 108), size: axSize(160, 24), selected: false),
            (name: "C", help: regionCHelp, pos: axPoint(250, 108), size: axSize(160, 24), selected: false)
        ],
        playheadPosition: "1.1.1.1"
    )
    let last = AccessibilityChannel.lastRegionInfo(runtime: fixture.runtime)
    #expect(last?.name == "B")
    #expect(last?.startBar == 7)
}

@Test func testSelectedRegionInfoReturnsRegionWithAXSelectedTrue() {
    let regionAHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let regionBHelp = "리전은 7 마디 에서 시작하여 9 마디 에서 끝납니다., MIDI 리전."

    let fixture = makeRegionFixture(
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [
            (name: "A", help: regionAHelp, pos: axPoint(100, 108), size: axSize(160, 24), selected: false),
            (name: "B", help: regionBHelp, pos: axPoint(400, 108), size: axSize(160, 24), selected: true)
        ],
        playheadPosition: "1.1.1.1"
    )
    let sel = AccessibilityChannel.selectedRegionInfo(runtime: fixture.runtime)
    #expect(sel?.name == "B")
    #expect(sel?.startBar == 7)
}

// MARK: - region.bounce — State A/B/C paths

@Test func testBounceRegionReturnsStateAOnAudioMatch() async {
    // Pre: selected MIDI region at bar 1-3. Bounce rewrites it to "audio" at
    // the same bar range (in-place, same position) → State A verified:true.
    let preHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let postHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., 오디오 리전."

    let builder = FakeAXRuntimeBuilder()
    let fixture = makeRegionFixture(
        builder: builder,
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA",
            help: preHelp,
            pos: axPoint(240, 108),
            size: axSize(320, 24),
            selected: true
        )],
        playheadPosition: "1.1.1.1",
        performActionHandler: { _, _ in
            builder.setAttribute(builder.element(3_000), kAXHelpAttribute as String, postHelp)
            return true
        }
    )
    addBounceMenu(to: builder, app: builder.element(1_000))

    let result = await AccessibilityChannel.defaultBounceRegionInPlace(
        runtime: fixture.runtime,
        settle: { /* skip in tests */ },
        menuOpenSettle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool)!)
    #expect((obj["verified"] as? Bool)!)
    #expect(obj["pre_kind"] as? String == "midi")
    #expect(obj["post_kind"] as? String == "audio")
    #expect(obj["pre_start_bar"] as? Int == 1)
    #expect(obj["post_start_bar"] as? Int == 1)
}

@Test func testBounceRegionFailsClosedWhenNothingSelected() async {
    let help = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let builder = FakeAXRuntimeBuilder()
    let fixture = makeRegionFixture(
        builder: builder,
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA", help: help, pos: axPoint(240, 108), size: axSize(320, 24), selected: false
        )],
        playheadPosition: "1.1.1.1",
        performActionHandler: { _, _ in
            Issue.record("bounce menu item should never be pressed when nothing is selected")
            return true
        }
    )
    addBounceMenu(to: builder, app: builder.element(1_000))

    let result = await AccessibilityChannel.defaultBounceRegionInPlace(
        runtime: fixture.runtime,
        settle: { },
        menuOpenSettle: { }
    )

    // State C surfaces as .error at the ChannelResult level, per HonestContract.
    guard case .error(let message) = result else {
        Issue.record("expected .error, got \(result)")
        return
    }
    #expect(message.contains("element_not_found"))
    #expect(message.contains("no region is currently selected"))
}

@Test func testBounceRegionFailsClosedWhenAlreadyAudio() async {
    let help = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., 오디오 리전."
    let builder = FakeAXRuntimeBuilder()
    let fixture = makeRegionFixture(
        builder: builder,
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA", help: help, pos: axPoint(240, 108), size: axSize(320, 24), selected: true
        )],
        playheadPosition: "1.1.1.1",
        performActionHandler: { _, _ in
            Issue.record("bounce menu item should never be pressed for an already-audio region")
            return true
        }
    )
    addBounceMenu(to: builder, app: builder.element(1_000))

    let result = await AccessibilityChannel.defaultBounceRegionInPlace(
        runtime: fixture.runtime,
        settle: { },
        menuOpenSettle: { }
    )

    guard case .error(let message) = result else {
        Issue.record("expected .error, got \(result)")
        return
    }
    #expect(message.contains("invalid_params"))
    #expect(message.contains("already audio"))
}

@Test func testBounceRegionReturnsStateBWhenSelectionLostAfterBounce() async {
    let preHelp = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let builder = FakeAXRuntimeBuilder()
    let fixture = makeRegionFixture(
        builder: builder,
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA", help: preHelp, pos: axPoint(240, 108), size: axSize(320, 24), selected: true
        )],
        playheadPosition: "1.1.1.1",
        performActionHandler: { _, _ in
            // Simulate selection being lost post-bounce (AXSelected never
            // comes back true on anything).
            builder.setAttribute(builder.element(3_000), kAXSelectedAttribute as String, false)
            return true
        }
    )
    addBounceMenu(to: builder, app: builder.element(1_000))

    let result = await AccessibilityChannel.defaultBounceRegionInPlace(
        runtime: fixture.runtime,
        settle: { },
        menuOpenSettle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool) == false)
    #expect(obj["reason"] as? String == "readback_unavailable")
}

@Test func testBounceRegionReturnsStateBWhenStillMidiAfterBounce() async {
    // Bounce "succeeded" (AXPress returned true) but the region is still
    // MIDI post-settle — Logic didn't actually convert it. State B
    // readback_mismatch, never silently reported as success.
    let help = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let builder = FakeAXRuntimeBuilder()
    let fixture = makeRegionFixture(
        builder: builder,
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA", help: help, pos: axPoint(240, 108), size: axSize(320, 24), selected: true
        )],
        playheadPosition: "1.1.1.1",
        performActionHandler: { _, _ in true }
    )
    addBounceMenu(to: builder, app: builder.element(1_000))

    let result = await AccessibilityChannel.defaultBounceRegionInPlace(
        runtime: fixture.runtime,
        settle: { },
        menuOpenSettle: { }
    )

    #expect(result.isSuccess)
    let obj = decodeJSON(result.message)
    #expect((obj["success"] as? Bool) == false)
    #expect(obj["reason"] as? String == "readback_mismatch")
    #expect(obj["post_kind"] as? String == "midi")
}

@Test func testBounceRegionReturnsStateCWhenMenuItemNotFound() async {
    // Edit > Bounce or Join > Bounce Regions in Place… simply isn't in the
    // AX tree (e.g. Logic version/locale drift) — fails closed before any
    // press is attempted, distinct from the AXPress-fails case below.
    let help = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let builder = FakeAXRuntimeBuilder()
    let fixture = makeRegionFixture(
        builder: builder,
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA", help: help, pos: axPoint(240, 108), size: axSize(320, 24), selected: true
        )],
        playheadPosition: "1.1.1.1"
        // No addBounceMenu call — the menu bar attribute is simply absent.
    )

    let result = await AccessibilityChannel.defaultBounceRegionInPlace(
        runtime: fixture.runtime,
        settle: { },
        menuOpenSettle: { }
    )

    guard case .error(let message) = result else {
        Issue.record("expected .error, got \(result)")
        return
    }
    #expect(message.contains("element_not_found"))
    #expect(message.contains("was not found"))
}

@Test func testBounceRegionReturnsStateCWhenDisabled() async {
    // Menu item resolves but AXEnabled is false — Logic itself is refusing
    // the action for the current selection (e.g. unsupported region type).
    // Resolution presses the Edit and Bounce-or-Join parents on the way
    // down (to force their AX children to populate) — only a press on the
    // disabled LEAF item itself is the violation this test guards.
    let help = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let builder = FakeAXRuntimeBuilder()
    let bounceMenuItem = addBounceMenu(to: builder, app: builder.element(1_000), enabled: false)
    let bounceMenuItemID = builder.elementID(bounceMenuItem)
    let fixture = makeRegionFixture(
        builder: builder,
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA", help: help, pos: axPoint(240, 108), size: axSize(320, 24), selected: true
        )],
        playheadPosition: "1.1.1.1",
        performActionHandler: { element, _ in
            if builder.elementID(element) == bounceMenuItemID {
                Issue.record("a disabled menu item should never be pressed")
            }
            return true
        }
    )

    let result = await AccessibilityChannel.defaultBounceRegionInPlace(
        runtime: fixture.runtime,
        settle: { },
        menuOpenSettle: { }
    )

    guard case .error(let message) = result else {
        Issue.record("expected .error, got \(result)")
        return
    }
    #expect(message.contains("invalid_params"))
    #expect(message.contains("disabled"))
}

@Test func testBounceRegionReturnsStateCWhenAXPressFails() async {
    let help = "리전은 1 마디 에서 시작하여 3 마디 에서 끝납니다., MIDI 리전."
    let builder = FakeAXRuntimeBuilder()
    let fixture = makeRegionFixture(
        builder: builder,
        headers: [(axPoint(0, 100), axSize(200, 40))],
        regions: [(
            name: "RegionA", help: help, pos: axPoint(240, 108), size: axSize(320, 24), selected: true
        )],
        playheadPosition: "1.1.1.1",
        performActionHandler: { _, _ in false }
    )
    addBounceMenu(to: builder, app: builder.element(1_000))

    let result = await AccessibilityChannel.defaultBounceRegionInPlace(
        runtime: fixture.runtime,
        settle: { },
        menuOpenSettle: { }
    )

    guard case .error(let message) = result else {
        Issue.record("expected .error, got \(result)")
        return
    }
    #expect(message.contains("ax_write_failed"))
    #expect(message.contains("AXPress failed"))
}
