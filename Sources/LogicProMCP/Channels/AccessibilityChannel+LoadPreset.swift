import ApplicationServices
import Foundation

// MARK: - plugin.load_preset (PLAN_PLUGINS_Y_PRESETS.md, FASE C)

/// Loads a named preset into an existing plugin insert through Logic's own
/// Setting menu.
///
/// Why a preset op instead of per-parameter writes: Logic's plugin parameter
/// views are AX-opaque — the Channel EQ census gate FAILED on 2026-07-07 (the
/// Controls view is a hosted remote view that returns 0 elements), and in the
/// project's whole history exactly one parameter became writable. The Setting
/// menu is different: Logic draws it AROUND every plugin, stock or third-party,
/// so it is reachable where the parameters are not. Loading a Claude-written
/// preset file (AmpliTube .aupreset, Logic .pst) through it reaches the
/// parameters without touching the opaque view at all.
///
/// Contract:
///   - State A only when the Setting popup reads back EXACTLY the pressed leaf.
///   - State B when the leaf was pressed but the popup reads something else or
///     cannot be read — the preset may or may not have loaded.
///   - State C with `write_attempted:false` for every refusal before the press:
///     no leaf is ever pressed on a path that did not resolve uniquely.
extension AccessibilityChannel {

    static func defaultLoadPreset(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production,
        frontDocumentPath: FrontDocumentPathProvider = liveFrontDocumentPath,
        activateLogic: @Sendable () -> Bool = { ProcessUtils.activateLogicPro() },
        settleMs: Int = 250,
        windowTimeoutMs: Int = 3_000
    ) async -> ChannelResult {
        let operation = "logic_plugins.load_preset"

        // 1 — schema.
        guard let track = Int(params["track"] ?? ""), track >= 0 else {
            return .error(invalidParamsStateC(operation, "missing or invalid 'track' (Int >= 0)"))
        }
        guard let insert = Int(params["insert"] ?? ""), insert >= 0 else {
            return .error(invalidParamsStateC(operation, "missing or invalid 'insert' (Int >= 0)"))
        }
        let plugin = (params["plugin"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plugin.isEmpty else {
            return .error(invalidParamsStateC(
                operation, "missing 'plugin' — the plugin you expect in that insert, e.g. \"Compressor\" or \"AmpliTube 5\""
            ))
        }
        guard let path = decodePresetPath(params["preset_path"]) else {
            return .error(invalidParamsStateC(
                operation, "missing or invalid 'preset_path' — the Setting-menu path as titles, e.g. [\"Claude\", \"Mi tono\"]"
            ))
        }
        var identity: [String: Any] = ["track_index": track, "insert": insert, "plugin_requested": plugin]

        // 2 — project identity. No MCP tool hands a caller the front document's
        // path today (the audit's `file_path` is the bug tracked as #30), so the
        // gate is enforced only when a path IS supplied; the observed path always
        // goes into the receipt so the affected project is on record.
        let projectPath = await frontDocumentPath()
        identity["project_path_observed"] = projectPath ?? NSNull()
        if let expected = params["project_expected_path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expected.isEmpty {
            guard let projectPath, AppleScriptChannel.projectPathsMatch(expected, projectPath) else {
                identity["project_path_expected"] = expected
                return .error(HonestContract.encodeV2StateC(
                    error: .projectIdentityMismatch,
                    extras: refusal(operation, identity,
                                    attempted: "verify the front document before loading a preset",
                                    observed: projectPath == nil
                                        ? "no front document path could be read"
                                        : "front document path did not match project_expected_path")
                ))
            }
        }

        // 3 — ADR-002 F1: a target_ref resolution threads the bound track name.
        if let guardResult = targetTrackNameGuard(
            operation: operation,
            track: track,
            expectedTrackName: params["expected_track_name"],
            identity: identity,
            runtime: runtime
        ) {
            return guardResult
        }

        // 4 — select the track and prove it (the same ladder set_param_verified uses).
        guard AXLogicProElements.selectTrackViaAX(at: track, runtime: runtime) else {
            return .error(trackSelectionFailedStateC(operation, identity, "AX track selection write failed for track \(track)"))
        }
        guard await verifiedTrackSelected(track: track, runtime: runtime) else {
            return .error(trackSelectionFailedStateC(
                operation, identity, "track \(track) selection could not be verified via AXSelected readback"
            ))
        }

        // 5 — the insert must be readable, occupied, and hold the plugin the
        // caller named. Any plugin: unlike set_param_verified this op needs no
        // catalog entry, because the Setting menu is the same for all of them.
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else {
            return .error(incompleteInventoryStateC(operation, identity, "mixer area was not locatable"))
        }
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard track < strips.count else {
            return .error(incompleteInventoryStateC(operation, identity, "track index \(track) is not present in the visible mixer"))
        }
        let slots = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
        guard pluginInventoryItems(for: slots).complete else {
            return .error(incompleteInventoryStateC(operation, identity, "one or more insert slots are unreadable (complete:false)"))
        }
        guard insert < slots.count, slots[insert].occupied else {
            var extras = refusal(operation, identity,
                                 attempted: "locate the occupied plugin at insert \(insert)",
                                 observed: insert < slots.count
                                     ? "insert \(insert) is empty — no plugin to load a preset into"
                                     : "insert \(insert) is out of range (\(slots.count) slots)")
            if slots.isEmpty {
                let detail = slotAddressingFailureDetail(requestedIndex: insert, slotCount: 0)
                extras["what_was_observed"] = detail.observed
                extras["recovery_hint"] = detail.recoveryHint
            }
            return .error(HonestContract.encodeV2StateC(error: .incompleteInventory, extras: extras))
        }
        let observedPlugin = slots[insert].name
        guard let observedPlugin, pluginNamesMatch(observedPlugin, plugin) else {
            var extras = refusal(operation, identity,
                                 attempted: "verify insert \(insert) holds '\(plugin)' before opening its window",
                                 observed: observedPlugin.map { "insert \(insert) holds '\($0)'" }
                                     ?? "insert \(insert) plugin name was unreadable")
            extras["observed_plugin_name"] = observedPlugin ?? NSNull()
            return .error(HonestContract.encodeV2StateC(error: .targetPluginMismatch, extras: extras))
        }
        identity["plugin_observed"] = observedPlugin

        // 6 — acquire THIS insert's editor window by provenance.
        guard let trackName = AXLogicProElements.trackName(at: track, runtime: runtime) else {
            return .error(windowOpenFailedStateC(operation, identity, "the target track name could not be resolved for window matching"))
        }
        identity["track_name"] = trackName
        // Bring Logic forward so the plugin window and its Setting menu open
        // where the user can see them. (Not the cause of the 2026-09-18 window
        // failures — that was the toggle; see acquirePluginWindowBySlot.)
        // Every check above is read-only, so this is the first UI change.
        let activated = activateLogic()
        try? await Task.sleep(nanoseconds: UInt64(max(settleMs, 0)) * 1_000_000)
        let acquisition = await acquirePluginWindowBySlot(
            slots[insert].element, trackName: trackName, runtime: runtime, timeoutMs: windowTimeoutMs
        )
        guard let window = acquisition.window else {
            let dismissed = dismissStrayMenu(runtime: runtime)
            var diagnostics = acquisition.diagnostics
            diagnostics["logic_activated"] = activated
            diagnostics["stray_menu_dismissed"] = dismissed
            return .error(windowOpenFailedStateC(
                operation, identity,
                acquisition.outcome == "no_open_control"
                    ? "insert \(insert) exposes no \"open\" button to press"
                    : "pressing insert \(insert)'s \"open\" button produced no single new window titled '\(trackName)' (\(acquisition.outcome))",
                diagnostics: diagnostics
            ))
        }

        // 7 — find the Setting popup by what its menu contains.
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .error(windowOpenFailedStateC(operation, identity, "Logic's application element was not readable"))
        }
        var rejected: [[String: Any]] = []
        var setting: (popup: AXUIElement, menu: AXUIElement)?
        for popup in settingPopupCandidates(in: window, runtime: runtime.ax) {
            let value = popupValue(popup, runtime: runtime.ax)
            guard let menu = await openPopupMenu(popup, app: app, settleMs: settleMs, runtime: runtime.ax) else {
                rejected.append(["popup_value": value ?? NSNull(), "outcome": "no_menu_opened"])
                continue
            }
            if isSettingMenu(menu, runtime: runtime.ax) {
                setting = (popup, menu)
                break
            }
            rejected.append([
                "popup_value": value ?? NSNull(), "outcome": "not_the_setting_menu",
                "first_items": Array(menuItems(menu, runtime: runtime.ax).map(\.title).prefix(6)),
            ])
            cancelMenu(menu, runtime: runtime.ax)
            if let own = childMenu(of: popup, runtime: runtime.ax), !CFEqual(own, menu) {
                cancelMenu(own, runtime: runtime.ax)
            }
        }
        guard let setting else {
            var extras = refusal(operation, identity,
                                 attempted: "open the plugin's Setting menu",
                                 observed: "no popup in the plugin window opened a menu containing both 'Save As…' and 'Recall Default'")
            extras["popups_tried"] = rejected
            return .error(HonestContract.encodeV2StateC(error: .elementNotFound, extras: extras))
        }
        let before = popupValue(setting.popup, runtime: runtime.ax)

        // 8 — walk the folders, then resolve the leaf. Nothing is pressed below
        // this point unless it resolves to exactly one enabled item.
        var menu = setting.menu
        for (depth, folder) in path.dropLast().enumerated() {
            let items = menuItems(menu, runtime: runtime.ax)
            let hits = items.filter { $0.title == folder }
            guard hits.count == 1 else {
                cancelMenu(setting.menu, runtime: runtime.ax)
                return .error(pathRefusal(operation, identity, path: path, depth: depth, segment: folder,
                                          hits: hits.count, available: items.map(\.title)))
            }
            _ = AXHelpers.performAction(hits[0].element, kAXPressAction as String, runtime: runtime.ax)
            try? await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
            guard let submenu = childMenu(of: hits[0].element, runtime: runtime.ax) else {
                cancelMenu(setting.menu, runtime: runtime.ax)
                var extras = refusal(operation, identity,
                                     attempted: "open the '\(folder)' folder of the Setting menu",
                                     observed: "'\(folder)' is a preset, not a folder")
                extras["preset_path"] = path
                return .error(HonestContract.encodeV2StateC(error: .elementNotFound, extras: extras))
            }
            menu = submenu
        }
        let leafTitle = path[path.count - 1]
        let items = menuItems(menu, runtime: runtime.ax)
        let leaves = items.filter { $0.title == leafTitle }
        guard leaves.count == 1 else {
            cancelMenu(setting.menu, runtime: runtime.ax)
            return .error(pathRefusal(operation, identity, path: path, depth: path.count - 1, segment: leafTitle,
                                      hits: leaves.count, available: items.map(\.title)))
        }
        let leaf = leaves[0].element
        if let enabled: Bool = AXHelpers.getAttribute(leaf, kAXEnabledAttribute as String, runtime: runtime.ax), !enabled {
            cancelMenu(setting.menu, runtime: runtime.ax)
            var extras = refusal(operation, identity,
                                 attempted: "press the '\(leafTitle)' preset",
                                 observed: "the menu item is disabled")
            extras["preset_path"] = path
            return .error(HonestContract.encodeV2StateC(error: .elementNotFound, extras: extras))
        }
        if childMenu(of: leaf, runtime: runtime.ax) != nil {
            cancelMenu(setting.menu, runtime: runtime.ax)
            var extras = refusal(operation, identity,
                                 attempted: "load '\(leafTitle)'",
                                 observed: "'\(leafTitle)' is a folder; add the preset inside it to preset_path")
            extras["preset_path"] = path
            return .error(HonestContract.encodeV2StateC(error: .folderNotPreset, extras: extras))
        }

        // 9 — the one write.
        _ = AXHelpers.performAction(leaf, kAXPressAction as String, runtime: runtime.ax)

        // Poll rather than sleep once: Logic swaps the plugin state and then
        // repaints the popup, and the gap is not constant.
        var after = popupValue(setting.popup, runtime: runtime.ax)
        let deadline = Date().addingTimeInterval(1.5)
        while after != leafTitle, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            after = popupValue(setting.popup, runtime: runtime.ax)
        }
        // A menu still hanging open after the press would swallow the next
        // operation's input; close it and say so.
        let menuLeftOpen = childMenu(of: setting.popup, runtime: runtime.ax) != nil
            || openMenuOutsideMenuBar(in: app, runtime: runtime.ax) != nil
        if menuLeftOpen {
            cancelMenu(setting.menu, runtime: runtime.ax)
        }

        // 10 — the plugin at that insert must still be the one we loaded into.
        // Re-resolve the mixer FROM SCRATCH: measured live 2026-09-18, the strip
        // element captured in step 5 read back EMPTY after the plugin window was
        // opened and its menu walked, while a fresh inventory a second later read
        // "Compressor" at the same insert. A stale reference is not evidence that
        // the plugin changed.
        var pluginAfter: String?
        let rereadDeadline = Date().addingTimeInterval(1.0)
        repeat {
            pluginAfter = freshPluginName(track: track, insert: insert, runtime: runtime)
            if pluginAfter != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < rereadDeadline

        var extras: [String: Any] = [
            "operation": operation,
            "target_identity": identity,
            "preset_path": path,
            "requested": leafTitle,
            "observed": after ?? NSNull(),
            "popup_value_before": before ?? NSNull(),
            "plugin_after": pluginAfter ?? NSNull(),
            "menu_left_open": menuLeftOpen,
            "window_outcome": acquisition.outcome,
            "write_attempted": true,
        ]
        // Unreadable and different are different findings; the receipt must not
        // turn "could not re-read" into "the plugin changed".
        guard let pluginAfter else {
            extras["what_was_observed"] = "insert \(insert) could not be re-read after the load"
            return .success(HonestContract.encodeV2StateB(reason: .readbackUnavailable, extras: extras))
        }
        guard pluginNamesMatch(pluginAfter, plugin) else {
            extras["what_was_observed"] = "insert \(insert) reads '\(pluginAfter)' after the load, not '\(plugin)'"
            return .success(HonestContract.encodeV2StateB(reason: .readbackMismatch, extras: extras))
        }
        guard let after else {
            return .success(HonestContract.encodeV2StateB(reason: .readbackUnavailable, extras: extras))
        }
        guard after == leafTitle else {
            return .success(HonestContract.encodeV2StateB(reason: .readbackMismatch, extras: extras))
        }
        return .success(HonestContract.encodeV2StateA(extras: extras))
    }

    // MARK: - Pieces

    /// The plugin name at `insert` of `track`, resolved from the mixer root on
    /// every call — never from an element held across UI changes.
    static func freshPluginName(track: Int, insert: Int, runtime: AXLogicProElements.Runtime) -> String? {
        guard let mixer = AXLogicProElements.getMixerArea(runtime: runtime) else { return nil }
        let strips = AXLogicProElements.mixerChannelStrips(in: mixer, runtime: runtime.ax)
        guard strips.indices.contains(track) else { return nil }
        let slots = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
        return slots.indices.contains(insert) ? slots[insert].name : nil
    }

    /// `preset_path` travels as a JSON array of menu titles: names contain
    /// spaces, slashes and apostrophes ("80's"), so no separator is safe.
    static func decodePresetPath(_ raw: String?) -> [String]? {
        guard let raw, let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let titles = array.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard titles.count == array.count, !titles.isEmpty, !titles.contains(where: \.isEmpty) else { return nil }
        return titles
    }

    static func pluginNamesMatch(_ observed: String, _ requested: String) -> Bool {
        observed.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(requested.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// Every plugin editor window whose title is the track's name. Plugin
    /// windows are titled by TRACK, so a track with three plugins has three
    /// same-titled windows — the title alone never identifies an insert.
    static func pluginEditorWindows(titled trackName: String, runtime: AXLogicProElements.Runtime) -> [AXUIElement] {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else { return [] }
        let windows: [AXUIElement] = AXHelpers.getAttribute(app, kAXWindowsAttribute, runtime: runtime.ax) ?? []
        let target = trackName.trimmingCharacters(in: .whitespacesAndNewlines)
        return windows.filter { window in
            AXLogicProElements.isPluginEditorWindow(window, runtime: runtime.ax)
                && AXHelpers.getRole(window, runtime: runtime.ax) == (kAXWindowRole as String)
                && (AXHelpers.getTitle(window, runtime: runtime.ax) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) == target
        }
    }

    /// What pressing the insert's "open" button produced.
    struct WindowAcquisition {
        var window: AXUIElement?
        /// opened | reopened | no_open_control | no_new_window | ambiguous
        var outcome: String
        var presses: Int
        var windowsBefore: Int
        var windowsAfter: Int
        var raised: Bool

        var diagnostics: [String: Any] {
            ["window_outcome": outcome, "open_presses": presses,
             "plugin_windows_before": windowsBefore, "plugin_windows_after": windowsAfter]
        }
    }

    /// Identify an insert's editor window WITHOUT a parameter slider, by
    /// provenance: the window that APPEARS in Logic's window list when this
    /// insert's "open" button is pressed.
    ///
    /// Measured live 2026-09-18 (AXPress on the Compressor's "open"):
    ///   - the button is a TOGGLE — a second press closed the window;
    ///   - the window it opens is NOT main or focused, so "which window of
    ///     this track is front" never identified it. That check sent the old
    ///     ladder on to the slot's "list" button, which opens the plug-in
    ///     chooser — a menu that left Logic unable to answer AppleScript.
    /// So only the "open" button is pressed, identity is set difference, and a
    /// press that CLOSES one of this track's windows means ours was already
    /// open: press once more to bring it back.
    static func acquirePluginWindowBySlot(
        _ slot: AXUIElement,
        trackName: String,
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int = 3_000
    ) async -> WindowAcquisition {
        let before = pluginEditorWindows(titled: trackName, runtime: runtime)
        var result = WindowAcquisition(window: nil, outcome: "no_open_control", presses: 0,
                                       windowsBefore: before.count, windowsAfter: before.count, raised: false)
        guard let open = rankedPluginSlotOpenControls(in: slot, runtime: runtime.ax)
            .first(where: { $0.rank == 0 })?.element else { return result }

        var baseline = before
        result.outcome = "no_new_window"
        for attempt in 0..<2 {
            _ = pressElement(open, runtime: runtime.ax)        // 12.3 reports non-zero even when it opens
            result.presses += 1
            var closedOurs = false
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
            repeat {
                let now = pluginEditorWindows(titled: trackName, runtime: runtime)
                result.windowsAfter = now.count
                let appeared = now.filter { window in !baseline.contains { CFEqual($0, window) } }
                if appeared.count == 1 {
                    result.window = appeared[0]
                    result.outcome = attempt == 0 ? "opened" : "reopened"
                    result.raised = raise(appeared[0], runtime: runtime.ax)
                    return result
                }
                if appeared.count > 1 {
                    result.outcome = "ambiguous"
                    return result
                }
                if now.count < baseline.count {
                    closedOurs = true
                    baseline = now
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            } while Date() < deadline
            if !closedOurs { return result }
        }
        return result
    }

    /// Best effort: make the acquired window the one Logic treats as front,
    /// so the Setting menu opens where the user can see it.
    private static func raise(_ window: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        _ = AXHelpers.setAttribute(window, kAXMainAttribute as String, true as CFTypeRef, runtime: runtime)
        return AXHelpers.performAction(window, kAXRaiseAction as String, runtime: runtime)
    }

    /// Popups in the plugin window, the historical value-based match first and
    /// the rest in document order. The Compressor alone carries three (Setting,
    /// Side Chain, View), so each is confirmed by its menu before use.
    static func settingPopupCandidates(in window: AXUIElement, runtime: AXHelpers.Runtime) -> [AXUIElement] {
        let popups = AXHelpers.findAllDescendants(of: window, role: kAXPopUpButtonRole as String, maxDepth: 8, runtime: runtime)
        let byValue = popups.filter { popup in
            let value = popupValue(popup, runtime: runtime) ?? ""
            return AXLocalePolicy.settingPopupValue.labels.contains { value.contains($0) }
        }
        let rest = popups.filter { popup in !byValue.contains { CFEqual($0, popup) } }
        return Array((byValue + rest).prefix(4))
    }

    static func popupValue(_ popup: AXUIElement, runtime: AXHelpers.Runtime) -> String? {
        guard let value = AXHelpers.getValue(popup, runtime: runtime) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The same AX-only ladder scan_plugin_presets proved on 12.3: fire, wait,
    /// then OBSERVE — AXShowMenu reports -25206 there even when the menu opens.
    ///
    /// WHERE to observe matters. Measured live 2026-09-18: the historical
    /// `PluginInspector.findOpenSettingMenuAX` searches the WHOLE app for any
    /// AXMenu with ≥5 items, and the app tree includes the menu bar — it
    /// returned the Apple menu ("About This Mac", "Force Quit…") after the real
    /// Setting popup was pressed. The fingerprint rejected it, so nothing was
    /// pressed, but the right menu was never found. So: first the popup's OWN
    /// child menu (where macOS attaches an open popup menu), then a global
    /// search that never descends into the menu bar.
    static func openPopupMenu(
        _ popup: AXUIElement,
        app: AXUIElement,
        settleMs: Int,
        runtime: AXHelpers.Runtime
    ) async -> AXUIElement? {
        for action in [kAXShowMenuAction as String, kAXPressAction as String] {
            _ = AXHelpers.performAction(popup, action, runtime: runtime)
            try? await Task.sleep(nanoseconds: UInt64(max(settleMs, 350)) * 1_000_000)
            if let own = childMenu(of: popup, runtime: runtime) {
                return own
            }
            if let menu = openMenuOutsideMenuBar(in: app, runtime: runtime) {
                return menu
            }
        }
        return nil
    }

    /// Depth-first search for an open AXMenu (≥5 items) that skips the
    /// AXMenuBar subtree entirely — the bar's menus are never a plugin's.
    static func openMenuOutsideMenuBar(
        in element: AXUIElement,
        depth: Int = 0,
        maxDepth: Int = 6,
        runtime: AXHelpers.Runtime
    ) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        let role = AXHelpers.getRole(element, runtime: runtime)
        if role == (kAXMenuBarRole as String) { return nil }
        if role == (kAXMenuRole as String), AXHelpers.getChildren(element, runtime: runtime).count >= 5 {
            return element
        }
        for child in AXHelpers.getChildren(element, runtime: runtime) {
            if let found = openMenuOutsideMenuBar(in: child, depth: depth + 1, maxDepth: maxDepth, runtime: runtime) {
                return found
            }
        }
        return nil
    }

    static func isSettingMenu(_ menu: AXUIElement, runtime: AXHelpers.Runtime) -> Bool {
        let titles = Set(menuItems(menu, runtime: runtime).map { normalizedMenuTitle($0.title) })
        func has(_ set: AXLocalePolicy.LabelSet) -> Bool {
            set.labels.contains { titles.contains(normalizedMenuTitle($0)) }
        }
        return has(AXLocalePolicy.settingMenuSaveAs) && has(AXLocalePolicy.settingMenuRecallDefault)
    }

    static func normalizedMenuTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["…", "..."] where t.hasSuffix(suffix) {
            t.removeLast(suffix.count)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func menuItems(_ menu: AXUIElement, runtime: AXHelpers.Runtime) -> [(title: String, element: AXUIElement)] {
        AXHelpers.getChildren(menu, runtime: runtime).compactMap { child in
            guard AXHelpers.getRole(child, runtime: runtime) == (kAXMenuItemRole as String) else { return nil }
            let title = (AXHelpers.getTitle(child, runtime: runtime) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : (title, child)
        }
    }

    static func childMenu(of item: AXUIElement, runtime: AXHelpers.Runtime) -> AXUIElement? {
        AXHelpers.getChildren(item, runtime: runtime).first {
            AXHelpers.getRole($0, runtime: runtime) == (kAXMenuRole as String)
        }
    }

    static func cancelMenu(_ menu: AXUIElement, runtime: AXHelpers.Runtime) {
        _ = AXHelpers.performAction(menu, kAXCancelAction as String, runtime: runtime)
    }

    /// A menu Logic left open (outside the menu bar) blocks its AppleScript
    /// handling — live 2026-09-18 the plug-in chooser did exactly that. After
    /// a failed window step, close it rather than leave Logic stuck.
    static func dismissStrayMenu(runtime: AXLogicProElements.Runtime) -> Bool {
        guard let app = AXLogicProElements.appRoot(runtime: runtime),
              let menu = openMenuOutsideMenuBar(in: app, runtime: runtime.ax) else { return false }
        cancelMenu(menu, runtime: runtime.ax)
        return true
    }

    private static func refusal(
        _ operation: String,
        _ identity: [String: Any],
        attempted: String,
        observed: String
    ) -> [String: Any] {
        [
            "operation": operation,
            "target_identity": identity,
            "what_was_attempted": attempted,
            "what_was_observed": observed,
            "safe_to_retry": false,
            "write_attempted": false,
        ]
    }

    /// A path segment that is missing or repeated. The titles that ARE there go
    /// back to the caller: "not found" alone forces a blind retry, while the
    /// real sibling list turns the next attempt into a lookup.
    private static func pathRefusal(
        _ operation: String,
        _ identity: [String: Any],
        path: [String],
        depth: Int,
        segment: String,
        hits: Int,
        available: [String]
    ) -> String {
        var extras = refusal(
            operation, identity,
            attempted: "find '\(segment)' at level \(depth + 1) of the Setting menu",
            observed: hits == 0
                ? "no item titled '\(segment)' at that level"
                : "\(hits) items are titled '\(segment)' at that level; nothing was pressed"
        )
        extras["preset_path"] = path
        extras["available_at_level"] = Array(available.prefix(60))
        return HonestContract.encodeV2StateC(error: .elementNotFound, extras: extras)
    }
}
