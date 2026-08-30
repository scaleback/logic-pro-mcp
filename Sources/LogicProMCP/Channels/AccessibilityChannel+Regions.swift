import ApplicationServices
import AppKit
import Foundation

/// Region surface: enumerate arrange regions, move-to-playhead, and select-last.
extension AccessibilityChannel {
    // MARK: - Regions

    /// Read the arrange regions (MIDI/audio clips) Logic's AX tree exposes.
    ///
    /// Uses AX traversal: locate the "트랙 콘텐츠"/"Track Content" AXGroup, collect
    /// AXLayoutItem children whose AXHelp matches Logic's region-description pattern,
    /// and parse bar positions from the localized help string.
    ///
    /// Regions scrolled outside the visible window are INCLUDED. A frame-
    /// intersection filter used to drop them, which cost real data: with the
    /// arrange view scrolled away, this returned zero regions while Logic's
    /// AX tree still carried all of them, help text and all (measured live
    /// 2026-08-17). Track attribution is what needed guarding instead — see
    /// `trackIndexForRegion`, which reports -1 rather than snapping a region
    /// to a far-away lane.
    ///
    /// `complete: false` / `scope` / `reason` below remain hardcoded: they
    /// disclaim what Logic's AX tree itself materializes, which is not
    /// something this traversal can widen, and callers must never read the
    /// result as a project-wide inventory.
    static func defaultGetRegions(runtime: AXLogicProElements.Runtime = .production) -> ChannelResult {
        switch enumerateRegionItems(runtime: runtime) {
        case .failure(let err):
            return .error(err.message)
        case .success(let result):
            let regions = result.regions.map { $0.info }
            return encodeResult(RegionInventoryPayload(
                regions: regions,
                complete: false,
                scope: "ax_exposed_regions",
                reason: "logic_ax_exposure_only",
                returnedCount: regions.count,
                debug: RegionInventoryPayload.Debug(
                    layoutItems: result.layoutItemCount,
                    nonRegion: result.nonRegionCount
                )
            ))
        }
    }

    /// Result of region traversal. `regions` contains both the AX element
    /// (for read-back like AXSelected) and the parsed RegionInfo.
    struct RegionEnumerationResult {
        let regions: [(item: AXUIElement, info: RegionInfo)]
        let layoutItemCount: Int
        let nonRegionCount: Int
    }

    /// Lightweight error wrapper so `enumerateRegionItems` can carry the
    /// existing diagnostic strings through `Result` without forcing every
    /// caller to define a typed enum. `String` itself does not conform to
    /// `Error`, so this minimal wrapper is the smallest viable adapter.
    struct RegionEnumerationError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func normalizeRegionGroupDescription(_ description: String) -> String {
        description
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split { $0.isWhitespace }
            .joined(separator: " ")
    }

    private static func isExplicitTrackContentDescription(_ description: String) -> Bool {
        let normalized = normalizeRegionGroupDescription(description)
        return AXLocalePolicy.trackContentExplicit.labels.contains(normalized)
    }

    private static func isGenericContentDescription(_ description: String) -> Bool {
        let normalized = normalizeRegionGroupDescription(description)
        return AXLocalePolicy.trackContentGeneric.labels.contains(normalized)
    }

    /// Classify a region as drummer / midi / audio / unknown.
    ///
    /// The AXHelp string is Logic's own description and names the type
    /// outright ("…, Audio region. An editable object representing recorded
    /// or imported audio.") — it is authoritative. The AXDescription (name)
    /// is whatever the region happens to be CALLED, which is user- and
    /// Logic-controlled text that frequently contradicts the real type.
    ///
    /// Both used to be concatenated into one haystack, which let a name
    /// decide the kind whenever it happened to contain a type word first.
    /// Live evidence (2026-08-17, Edgar's project): bouncing a MIDI region
    /// yields a real AUDIO region that Logic names after the original —
    /// "MIDI Region_bip". Its help says "Audio region", but the old
    /// name+help haystack matched "midi" (from the name) before ever
    /// reaching the audio check, so every bounced region read back as
    /// `kind: "midi"`. That is exactly what kept `region.bounce` from ever
    /// reaching State A: its verification requires `kind == "audio"`, so a
    /// bounce that provably worked (audio region on a new track, waveform
    /// visible on screen) was still reported as State B.
    ///
    /// So: classify from the help text alone. Only when help yields nothing
    /// usable does the name join the haystack, preserving the previous
    /// behavior for elements whose AXHelp is missing rather than trading
    /// one blind spot for another.
    private static func classifyRegionKind(name: String, help: String) -> String {
        let fromHelp = classifyRegionKind(in: help.lowercased())
        if fromHelp != "unknown" {
            return fromHelp
        }
        return classifyRegionKind(in: "\(name) \(help)".lowercased())
    }

    private static func classifyRegionKind(in searchable: String) -> String {
        if AXLocalePolicy.regionKindDrummer.containsAny(in: searchable) {
            return "drummer"
        }
        if AXLocalePolicy.regionKindMidi.containsAny(in: searchable) {
            return "midi"
        }
        if AXLocalePolicy.regionKindAudio.containsAny(in: searchable) {
            return "audio"
        }
        return "unknown"
    }

    /// Map a region's vertical midpoint to the track lane that owns it, or
    /// `-1` when no lane plausibly does.
    ///
    /// A region whose midpoint falls INSIDE a header's vertical band belongs
    /// to that track — the common case, and exact. Regions can legitimately
    /// sit slightly outside their band (row padding, partially scrolled
    /// lanes), so a near miss still resolves, but only within one band-height
    /// of tolerance.
    ///
    /// The tolerance is the point of this function. The previous
    /// implementation took the nearest header with `min(by:)` and NO distance
    /// limit, which was safe only because a viewport filter had already
    /// dropped everything off-screen. With that filter gone (so that regions
    /// scrolled out of view are still reported at all), an unbounded nearest
    /// match would hand a region thousands of points below the last readable
    /// header that header's index — turning "excluded" into "confidently
    /// mislabelled", which is the worse failure by far. Beyond the tolerance
    /// this returns -1, which callers already understand as "track unknown".
    private static func trackIndexForRegion(
        midY: CGFloat,
        bands: [(index: Int, minY: CGFloat, maxY: CGFloat)]
    ) -> Int {
        guard !bands.isEmpty else { return -1 }

        if let containing = bands.first(where: { midY >= $0.minY && midY <= $0.maxY }) {
            return containing.index
        }

        func gap(_ band: (index: Int, minY: CGFloat, maxY: CGFloat)) -> CGFloat {
            midY < band.minY ? band.minY - midY : midY - band.maxY
        }

        guard let nearest = bands.min(by: { gap($0) < gap($1) }) else { return -1 }
        let tolerance = max(nearest.maxY - nearest.minY, 1)
        return gap(nearest) <= tolerance ? nearest.index : -1
    }

    /// Walk the arrange area's "Track Content" group, collect every
    /// AXLayoutItem region with parsed bar positions and its underlying AX
    /// element handle. Shared across `defaultGetRegions`,
    /// `selectedRegionInfo`, and `lastRegionInfo`.
    static func enumerateRegionItems(
        runtime: AXLogicProElements.Runtime = .production
    ) -> Result<RegionEnumerationResult, RegionEnumerationError> {
        guard let window = AXLogicProElements.mainWindow(runtime: runtime) else {
            return .failure(RegionEnumerationError("Cannot locate Logic Pro main window"))
        }
        let candidates = AXHelpers.findAllDescendants(
            of: window, role: kAXGroupRole, maxDepth: 14, runtime: runtime.ax
        )
        var contentGroup: AXUIElement? = nil
        var genericContentGroup: AXUIElement? = nil
        var groupDescSamples: [String] = []
        for g in candidates {
            let desc = AXHelpers.getDescription(g, runtime: runtime.ax) ?? ""
            if !desc.isEmpty { groupDescSamples.append(desc) }
            if isExplicitTrackContentDescription(desc) {
                contentGroup = g
                break
            }
            if genericContentGroup == nil, isGenericContentDescription(desc) {
                genericContentGroup = g
            }
        }
        if contentGroup == nil {
            contentGroup = genericContentGroup
        }
        guard let content = contentGroup else {
            let detailed = groupDescSamples.prefix(20).map { s -> String in
                let bytes = s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: ",")
                return "'\(s)'(\(s.unicodeScalars.count)=\(bytes))"
            }.joined(separator: " | ")
            return .failure(RegionEnumerationError(
                "Track Content group not found (scanned \(candidates.count) AXGroups; landmarks: \(detailed)). Recovery hint: ensure the Tracks arrange area is visible and not replaced by a modal, editor, or plugin window."
            ))
        }

        let headers = AXLogicProElements.allTrackHeaders(runtime: runtime)
        // Keep each header's full vertical BAND (top..bottom), not just its
        // centre: `trackIndexForRegion` needs to tell "inside this lane" from
        // "merely nearest to it", and a centre alone cannot express that.
        let headerBands: [(index: Int, minY: CGFloat, maxY: CGFloat)] = headers
            .enumerated()
            .compactMap { pair in
                guard let p = AXHelpers.getPosition(pair.element, runtime: runtime.ax),
                      let s = AXHelpers.getSize(pair.element, runtime: runtime.ax) else { return nil }
                return (pair.offset, p.y, p.y + s.height)
            }

        let items = AXHelpers.findAllDescendants(
            of: content, role: "AXLayoutItem", maxDepth: 10, runtime: runtime.ax
        )
        var regions: [(item: AXUIElement, info: RegionInfo)] = []
        var nonRegionCount = 0
        for item in items {
            let help = AXHelpers.getHelp(item, runtime: runtime.ax) ?? ""
            let isRegion = AXLocalePolicy.regionHelpKeyword.containsAny(in: help)
            guard isRegion else { nonRegionCount += 1; continue }
            let name = AXHelpers.getDescription(item, runtime: runtime.ax) ?? ""
            let (startBar, endBar) = parseRegionBars(from: help)
            let kind = classifyRegionKind(name: name, help: help)

            var trackIndex = -1
            if let pos = AXHelpers.getPosition(item, runtime: runtime.ax),
               let size = AXHelpers.getSize(item, runtime: runtime.ax) {
                trackIndex = trackIndexForRegion(
                    midY: pos.y + size.height / 2,
                    bands: headerBands
                )
            }

            regions.append((
                item,
                RegionInfo(
                    name: name,
                    trackIndex: trackIndex,
                    startBar: startBar,
                    endBar: endBar,
                    kind: kind,
                    rawHelp: help
                )
            ))
        }
        return .success(RegionEnumerationResult(
            regions: regions,
            layoutItemCount: items.count,
            nonRegionCount: nonRegionCount
        ))
    }

    /// Currently selected region (AXLayoutItem with AXSelected=true) inside
    /// the arrange area. Returns nil when no AXLayoutItem reports
    /// `kAXSelectedAttribute = true`. Used by `region.move_to_playhead` for
    /// pre/post startBar diff.
    static func selectedRegionInfo(
        runtime: AXLogicProElements.Runtime = .production
    ) -> RegionInfo? {
        guard case .success(let result) = enumerateRegionItems(runtime: runtime) else {
            return nil
        }
        for entry in result.regions {
            if let value: AnyObject = AXHelpers.getAttribute(entry.item, kAXSelectedAttribute, runtime: runtime.ax),
               let n = value as? NSNumber, n.boolValue {
                return entry.info
            }
        }
        return nil
    }

    /// Right-most / latest region. "Last" = the entry with the largest
    /// `startBar`; ties broken by larger `trackIndex`. Used by
    /// `region.select_last` post-state verification.
    static func lastRegionInfo(
        runtime: AXLogicProElements.Runtime = .production
    ) -> RegionInfo? {
        guard case .success(let result) = enumerateRegionItems(runtime: runtime),
              !result.regions.isEmpty else {
            return nil
        }
        let sorted = result.regions.map { $0.info }.sorted { a, b in
            if a.startBar != b.startBar { return a.startBar < b.startBar }
            return a.trackIndex < b.trackIndex
        }
        return sorted.last
    }

    /// The region on whichever track currently reads the highest
    /// `trackIndex` among all enumerated regions, regardless of AX
    /// selection state. Used by `region.bounce`'s post-check: a real bounce
    /// (confirmed live 2026-08-17, visually verified twice against Edgar's
    /// project) creates a new track holding the result — always the
    /// visually-lowest row, hence the highest Y-position-matched
    /// `trackIndex` — but does not reliably leave anything `AXSelected`
    /// afterward, so `selectedRegionInfo` alone can miss a bounce that
    /// genuinely succeeded.
    ///
    /// Deliberately NOT "the region at array index `preTrackCount`"
    /// (tried first, live 2026-08-17): `trackIndex` is assigned by
    /// Y-position match against `allTrackHeaders()`'s array order, which
    /// this project's own AX helpers never guarantee tracks top-to-bottom —
    /// two live attempts at guessing the new header's exact array position
    /// both found nothing, even though the resulting audio region was
    /// visibly on screen. Taking the max `trackIndex` across whatever IS
    /// enumerated sidesteps needing to predict that position at all.
    static func newestTrackRegionInfo(
        runtime: AXLogicProElements.Runtime = .production
    ) -> RegionInfo? {
        guard case .success(let result) = enumerateRegionItems(runtime: runtime),
              !result.regions.isEmpty else {
            return nil
        }
        return result.regions.map { $0.info }.max { $0.trackIndex < $1.trackIndex }
    }

    /// Parse the integer bar from `TransportState.position`
    /// ("Bar.Beat.Division.Tick"). Returns nil when the transport bar is not
    /// reachable or the position string can't be parsed.
    static func currentPlayheadBar(
        runtime: AXLogicProElements.Runtime = .production
    ) -> Int? {
        guard let transport = AXLogicProElements.getTransportBar(runtime: runtime) else {
            return nil
        }
        let state = AXValueExtractors.extractTransportState(from: transport, runtime: runtime.ax)
        let head = state.position.split(separator: ".").first.map(String.init) ?? ""
        return Int(head)
    }

    /// Extract (startBar, endBar) from Logic's localized region help text.
    /// Returns (-1, -1) if neither pattern matches — callers should inspect rawHelp.
    private static func parseRegionBars(from help: String) -> (Int, Int) {
        // Korean: "리전은 1 마디 에서 시작하여 2 마디 에서 끝납니다."
        // English: "Region starts at 128 bars and ends at 129 bars, MIDI region."
        let patterns = [
            #"리전은\s*(\d+)\s*마디.*?시작.*?(\d+)\s*마디.*?끝"#,
            #"(?i)region\s+starts\s+at\s+(?:bar\s+)?(\d+)(?:\s*bars?)?.*?ends\s+at\s+(?:bar\s+)?(\d+)(?:\s*bars?)?"#,
        ]
        for pat in patterns {
            guard let rx = try? NSRegularExpression(pattern: pat, options: [.dotMatchesLineSeparators]) else { continue }
            let range = NSRange(help.startIndex..., in: help)
            guard let m = rx.firstMatch(in: help, range: range), m.numberOfRanges >= 3 else { continue }
            guard let r1 = Range(m.range(at: 1), in: help),
                  let r2 = Range(m.range(at: 2), in: help),
                  let s = Int(help[r1]), let e = Int(help[r2]) else { continue }
            return (s, e)
        }
        return (-1, -1)
    }

    // MARK: - Region repositioning

    /// Move the currently selected region to the playhead position via the
    /// `편집 → 이동 → 재생헤드로` menu (Edit → Move → To Playhead).
    ///
    /// State A path (v3.1.3): pre-snapshot the selected region's startBar via
    /// direct AX, run the menu click, settle, then re-read the same region's
    /// startBar AND the transport playhead bar. If post.startBar matches the
    /// playhead bar (±1 tolerance) → State A `verified:true`. If pre==post
    /// (no movement) or post≠playhead → State B `readback_mismatch`. If we
    /// can't read a selected region pre/post → State B `readback_unavailable`.
    static func defaultMoveSelectedRegionToPlayhead(
        runtime: AXLogicProElements.Runtime = .production,
        executeScript: @Sendable (String) async -> ChannelResult = { await AppleScriptChannel.executeAppleScript($0) },
        settle: @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 350_000_000) }
    ) async -> ChannelResult {
        // Pre-state: snapshot the currently selected region (may be nil if
        // nothing is selected or the AX surface is unreadable).
        let pre = selectedRegionInfo(runtime: runtime)

        let logicProAppleScript = LogicProTarget.appleScriptTarget()
        let script = """
        \(logicProAppleScript.activateByBundleID)
        delay 0.1
        tell application "System Events"
            tell \(logicProAppleScript.systemEventsProcessTarget)
                try
                    click menu item "재생헤드로" of menu 1 of menu item "이동" of menu 1 of menu bar item "편집" of menu bar 1
                on error
                    try
                        click menu item "To Playhead" of menu 1 of menu item "Move" of menu 1 of menu bar item "Edit" of menu bar 1
                    on error errMsg
                        return "MENU_ERROR: " & errMsg
                    end try
                end try
            end tell
        end tell
        return "OK"
        """
        let result = await executeScript(script)
        switch result {
        case .success(let output):
            if output.hasPrefix("MENU_ERROR") {
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: "region.move_to_playhead menu click failed: \(output)"
                ))
            }
            // Settle window so Logic's AX tree updates before we re-read.
            await settle()

            let post = selectedRegionInfo(runtime: runtime)
            let playheadBar = currentPlayheadBar(runtime: runtime)

            // Without a pre-state we can't diff. State B readback_unavailable.
            guard let pre = pre else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "via": "applescript_menu",
                        "note": "no selected region pre-state",
                        "post_start_bar": post?.startBar ?? -1,
                        "playhead_bar": playheadBar ?? -1
                    ]
                ))
            }

            // Post readback unavailable (region disappeared / parser miss).
            guard let post = post, post.startBar > 0 else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "via": "applescript_menu",
                        "pre_start_bar": pre.startBar,
                        "playhead_bar": playheadBar ?? -1,
                        "note": "post startBar not readable"
                    ]
                ))
            }

            let extrasBase: [String: Any] = [
                "via": "applescript_menu",
                "region_name": pre.name,
                "pre_start_bar": pre.startBar,
                "post_start_bar": post.startBar,
                "playhead_bar": playheadBar ?? NSNull()
            ]

            // Verified: post.startBar landed on the playhead bar (±1 tolerance
            // for snap rounding). State A.
            if let head = playheadBar, abs(post.startBar - head) <= 1 {
                var extras = extrasBase
                extras["requested"] = head
                extras["observed"] = post.startBar
                return .success(HonestContract.encodeStateA(extras: extras))
            }

            // Position changed but didn't match playhead — Logic moved it
            // somewhere unexpected (snap behaviour / wrong target).
            if pre.startBar != post.startBar {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackMismatch,
                    extras: extrasBase
                ))
            }

            // pre == post → menu was a no-op (asked to move, nothing moved).
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: extrasBase.merging(["note": "no position change"]) { _, new in new }
            ))
        case .error(let msg):
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "region.move_to_playhead failed: \(msg)"
            ))
        }
    }

    /// Select the most recently created (right-most / largest trackIndex)
    /// region in the arrange area by locating it via AX element position.
    /// Newly imported regions are usually already selected by Logic, but this
    /// provides a fallback when selection state is lost between operations.
    ///
    /// State A path (v3.1.3): after the AppleScript sets selection, re-read
    /// the AX tree to find the currently selected region and the "last"
    /// region (largest startBar). If they match → State A `verified:true`;
    /// otherwise State B `readback_mismatch` / `readback_unavailable`.
    static func defaultSelectLastRegion(
        runtime: AXLogicProElements.Runtime = .production,
        executeScript: @Sendable (String) async -> ChannelResult = { await AppleScriptChannel.executeAppleScript($0) },
        settle: @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 350_000_000) }
    ) async -> ChannelResult {
        let logicProAppleScript = LogicProTarget.appleScriptTarget()
        let script = """
        \(logicProAppleScript.activateByBundleID)
        delay 0.1
        tell application "System Events"
            tell \(logicProAppleScript.systemEventsProcessTarget)
                set mainWin to first window
                set allItems to entire contents of mainWin
                set bestY to 0
                set bestX to 0
                set target to missing value
                repeat with anItem in allItems
                    try
                        if role of anItem is "AXLayoutItem" then
                            set s to size of anItem
                            set w to item 1 of s
                            set h to item 2 of s
                            -- Region heuristic: 20 < width < 2000, 20 < height < 200
                            if w > 20 and w < 2000 and h > 20 and h < 200 then
                                set p to position of anItem
                                set x to item 1 of p
                                set y to item 2 of p
                                if y > bestY or (y = bestY and x > bestX) then
                                    set bestY to y
                                    set bestX to x
                                    set target to anItem
                                end if
                            end if
                        end if
                    end try
                end repeat
                if target is missing value then
                    return "NO_REGION"
                end if
                -- Use AXPress / AXShowMenu may open contextual menu; instead set AXSelected.
                -- No coordinate fallback: a failed AXSelected write returns a typed
                -- marker and the handler fails closed (coordinate-free policy — the
                -- former `click at {center}` fallback was removed with the campaign).
                try
                    set selected of target to true
                    return "SELECTED"
                on error
                    return "SELECT_FAILED"
                end try
            end tell
        end tell
        """
        let result = await executeScript(script)
        switch result {
        case .success(let output):
            if output.contains("NO_REGION") {
                return .error(HonestContract.encodeStateC(
                    error: .elementNotFound,
                    hint: "region.select_last: no region found in arrange area"
                ))
            }
            if output.contains("SELECT_FAILED") {
                // The target region was found but its AXSelected write failed.
                // Fail closed — no coordinate fallback is attempted.
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: "region.select_last: the target region's AXSelected attribute could not be "
                        + "written; no fallback was attempted"
                ))
            }
            // Settle window so Logic's AX tree reflects the new selection
            // before we re-read AXSelected.
            await settle()

            let method = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = lastRegionInfo(runtime: runtime)
            let selected = selectedRegionInfo(runtime: runtime)

            // Without a "last" region we can't even define the target.
            guard let expected = expected else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "via": method.isEmpty ? "applescript" : method,
                        "note": "could not enumerate regions for last-region target"
                    ]
                ))
            }

            // No selected region readback (AXSelected never came back true).
            guard let selected = selected else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: [
                        "via": method.isEmpty ? "applescript" : method,
                        "expected_name": expected.name,
                        "expected_start_bar": expected.startBar,
                        "note": "no AXSelected region post-action"
                    ]
                ))
            }

            let extrasBase: [String: Any] = [
                "via": method.isEmpty ? "applescript" : method,
                "expected_name": expected.name,
                "expected_start_bar": expected.startBar,
                "expected_track_index": expected.trackIndex,
                "selected_name": selected.name,
                "selected_start_bar": selected.startBar,
                "selected_track_index": selected.trackIndex
            ]

            // Match by (name, startBar, trackIndex) triple — the same region
            // identity the resource exposes. State A on full match.
            if selected.name == expected.name
                && selected.startBar == expected.startBar
                && selected.trackIndex == expected.trackIndex {
                return .success(HonestContract.encodeStateA(extras: extrasBase))
            }

            // Selected ≠ last region (AppleScript heuristic picked a
            // different AXLayoutItem than our parsed-bar "last").
            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: extrasBase
            ))
        case .error(let msg):
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "region.select_last failed: \(msg)"
            ))
        }
    }

    /// Bounce the currently selected region in place (MIDI → audio, same
    /// bar position), with a real pre/post AX readback — unlike
    /// `edit.bounce_in_place` (Fase 3 tarea #19), which sends the same
    /// keystroke blind, with no way to confirm anything happened or to
    /// even require a region be selected first.
    ///
    /// Fails closed before ever touching Logic if no region is selected
    /// (`elementNotFound`) — this is the improvement over
    /// `edit.bounce_in_place`, which would fire against whatever Logic's
    /// current selection happens to be, selected region or not.
    ///
    /// Sends `Control+B` via simulated System Events keystroke — the REAL
    /// Key Command binding for "Bounce Regions/Cells in Place…" (confirmed
    /// 2026-08-16 directly from a live Key Command Assignments window: `^B`,
    /// zero conflicts on that chord), not `Cmd+Option+B`. This code sent
    /// Cmd+Option+B from 2026-08-16 through several live-test rounds — that
    /// chord was simply never bound to anything, which is why both this
    /// code AND the user pressing it directly on the keyboard produced only
    /// the macOS "invalid key command" screen flash. An AX-menu-press
    /// alternative (Edit > Bounce or Join > Bounce Regions in Place…) was
    /// tried in between and abandoned: Logic only rebuilds that section of
    /// the Edit menu's AX tree during a REAL menu-tracking session, so a
    /// synthetic `kAXPressAction` on the Edit bar item opened only the
    /// static prefix (Undo/Cut/Copy/Paste/Delete/Select) and never
    /// populated "Bounce or Join" at all. `edit.bounce_in_place`'s own
    /// `CGEventChannel.cmdOption(11)` mapping carries the exact same wrong
    /// chord — worth fixing there too, tracked separately since this
    /// function doesn't call that path.
    ///
    /// The correct chord opens a "Bounce Regions In Place" dialog (Name /
    /// Destination / Source / Normalize, etc.) rather than acting
    /// instantly — confirmed live 2026-08-17. This function clicks its OK
    /// button (default: Destination "New Track", Source "Mute") inside the
    /// same AppleScript round-trip, best-effort — its outcome rides along
    /// in `extras.dialog_confirm` for diagnosis but never gates the result,
    /// since the readback below is the real source of truth either way.
    ///
    /// Also confirmed live: with those defaults, "in place" describes the
    /// TIME position, not the track. Logic creates a brand-new track
    /// holding the bounced audio region (track count +1) and mutes the
    /// original MIDI region on its original track rather than converting
    /// it — it does not reuse `pre.trackIndex`. So State A requires: track
    /// count grew by exactly one, the post-bounce region's `kind` is
    /// `"audio"`, and its bar position matches the original within ±1 bar
    /// (same tolerance as `move_to_playhead`) — NOT the same trackIndex,
    /// which this flow never produces.
    ///
    /// One more live-confirmed wrinkle: Logic does not reliably leave
    /// anything `AXSelected` after a bounce that genuinely succeeded (a
    /// real, waveform-bearing audio region on the new track, selection
    /// simply nil). `selectedRegionInfo` is tried first since it's the more
    /// direct signal when Logic does set it, but when a new track exists
    /// and nothing is selected, `newestTrackRegionInfo` reads whichever
    /// enumerated region has the highest `trackIndex` (the new track is
    /// always visually lowest) instead of reporting an uncertain result for
    /// an operation that provably worked. Anything else — no new track,
    /// still MIDI, or landed somewhere unexpected — is State B, never a
    /// silently-assumed success.
    static func defaultBounceRegionInPlace(
        runtime: AXLogicProElements.Runtime = .production,
        executeScript: @Sendable (String) async -> ChannelResult = { await AppleScriptChannel.executeAppleScript($0) },
        settle: @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 1_500_000_000) }
    ) async -> ChannelResult {
        guard let pre = selectedRegionInfo(runtime: runtime) else {
            return .error(HonestContract.encodeStateC(
                error: .elementNotFound,
                hint: "region.bounce: no region is currently selected — select one first "
                    + "(region.select_last, or click a region in Logic) before bouncing"
            ))
        }
        if pre.kind == "audio" {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "region.bounce: the selected region ('\(pre.name)') is already audio — "
                    + "nothing to bounce"
            ))
        }

        let preTrackCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count

        let logicProAppleScript = LogicProTarget.appleScriptTarget()
        let script = """
        \(logicProAppleScript.activateByBundleID)
        delay 0.1
        tell application "System Events"
            tell \(logicProAppleScript.systemEventsProcessTarget)
                try
                    keystroke "b" using {control down}
                on error errMsg
                    return "KEYSTROKE_ERROR: " & errMsg
                end try
                delay 0.6
                try
                    if not (exists sheet 1 of window 1) then
                        return "OK_NO_SHEET"
                    end if
                    click button "OK" of sheet 1 of window 1
                    return "OK_CONFIRMED"
                on error errMsg2
                    return "OK_CONFIRM_ERROR: " & errMsg2
                end try
            end tell
        end tell
        """
        let result = await executeScript(script)
        switch result {
        case .error(let msg):
            return .error(HonestContract.encodeStateC(
                error: .axWriteFailed,
                hint: "region.bounce failed to send the bounce-in-place shortcut: \(msg)"
            ))
        case .success(let output):
            if output.hasPrefix("KEYSTROKE_ERROR") {
                return .error(HonestContract.encodeStateC(
                    error: .axWriteFailed,
                    hint: "region.bounce keystroke failed: \(output)"
                ))
            }
            // Bounce is real audio processing, not a simple AX write —
            // give Logic meaningfully longer to settle than the 350ms used
            // for selection/position changes elsewhere in this file.
            await settle()

            let postTrackCount = AXLogicProElements.allTrackHeaders(runtime: runtime).count
            let trackCreated = postTrackCount == preTrackCount + 1

            // Live testing (2026-08-17) found Logic does not reliably leave
            // anything AXSelected after a bounce that genuinely succeeded
            // (confirmed visually, twice: the new track's audio region was
            // real, waveform and all — selectedRegionInfo just came back
            // nil both times). Try selection first since it's the more
            // direct signal when Logic does set it; when a track was
            // created and nothing is selected, fall back to the region
            // with the highest trackIndex (the newest track, always
            // visually lowest) rather than reporting an uncertain result
            // for an operation that provably worked.
            let post = selectedRegionInfo(runtime: runtime)
                ?? (trackCreated ? newestTrackRegionInfo(runtime: runtime) : nil)
            let extrasBase: [String: Any] = [
                "via": "system_events_keystroke",
                "dialog_confirm": output,
                "pre_name": pre.name,
                "pre_track_index": pre.trackIndex,
                "pre_start_bar": pre.startBar,
                "pre_kind": pre.kind,
                "pre_track_count": preTrackCount,
                "post_track_count": postTrackCount,
            ]

            guard let post = post else {
                return .success(HonestContract.encodeStateB(
                    reason: .readbackUnavailable,
                    extras: extrasBase.merging(["note": "no selected region, and no region found on the new track, after bounce"]) { _, new in new }
                ))
            }

            var extras = extrasBase
            extras["post_name"] = post.name
            extras["post_track_index"] = post.trackIndex
            extras["post_start_bar"] = post.startBar
            extras["post_kind"] = post.kind

            let positionMatches = abs(post.startBar - pre.startBar) <= 1

            if trackCreated && post.kind == "audio" && positionMatches {
                return .success(HonestContract.encodeStateA(extras: extras))
            }

            return .success(HonestContract.encodeStateB(
                reason: .readbackMismatch,
                extras: extras
            ))
        }
    }

}
