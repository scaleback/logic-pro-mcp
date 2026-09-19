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
        settleMs: Int = 250
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
        guard let window = await acquirePluginWindowBySlot(slots[insert].element, trackName: trackName, runtime: runtime) else {
            return .error(windowOpenFailedStateC(
                operation, identity,
                "no plugin window titled '\(trackName)' came to the front after pressing insert \(insert)",
                diagnostics: ["plugin_windows_titled_track": pluginEditorWindows(titled: trackName, runtime: runtime).count]
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
        let menuLeftOpen = PluginInspector.findOpenSettingMenuAX(in: app, runtime: runtime.ax) != nil
        if menuLeftOpen {
            cancelMenu(setting.menu, runtime: runtime.ax)
        }

        // 10 — the plugin at that insert must still be the one we loaded into.
        let slotsAfter = AXLogicProElements.audioPluginInsertSlots(in: strips[track], runtime: runtime.ax)
        let pluginAfter = slotsAfter.indices.contains(insert) ? slotsAfter[insert].name : nil

        var extras: [String: Any] = [
            "operation": operation,
            "target_identity": identity,
            "preset_path": path,
            "requested": leafTitle,
            "observed": after ?? NSNull(),
            "popup_value_before": before ?? NSNull(),
            "plugin_after": pluginAfter ?? NSNull(),
            "menu_left_open": menuLeftOpen,
            "write_attempted": true,
        ]
        guard let pluginAfter, pluginNamesMatch(pluginAfter, plugin) else {
            extras["what_was_observed"] = "the insert no longer reads as '\(plugin)' after the load"
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

    /// Identify an insert's editor window WITHOUT a parameter slider.
    ///
    /// set_param_verified tells same-titled windows apart by a known slider;
    /// this op exists precisely for plugins with no readable sliders. So it uses
    /// provenance instead: first no plugin window of this track may be front,
    /// then the insert is pressed, and a window of this track that is front
    /// afterwards can only have been raised by that press. Two front windows is
    /// ambiguity, and fails closed.
    static func acquirePluginWindowBySlot(
        _ slot: AXUIElement,
        trackName: String,
        runtime: AXLogicProElements.Runtime,
        timeoutMs: Int = 1_250
    ) async -> AXUIElement? {
        for window in pluginEditorWindows(titled: trackName, runtime: runtime)
        where pluginWindowIsFront(window, runtime: runtime.ax) {
            guard demotePluginWindowBeforeAcquisition(window, runtime: runtime) else { return nil }
        }
        let ranked = rankedPluginSlotOpenControls(in: slot, runtime: runtime.ax)
        let attempts = ranked.filter { $0.rank == 0 }.map(\.element)
            + [slot]
            + ranked.filter { $0.rank != 0 }.map(\.element)
        for element in attempts {
            // Real Logic 12.3 can report a non-zero AX status for a press that
            // DID open the window: trust the observed window, not the return.
            _ = pressElement(element, runtime: runtime.ax)
            let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
            repeat {
                let front = pluginEditorWindows(titled: trackName, runtime: runtime)
                    .filter { pluginWindowIsFront($0, runtime: runtime.ax) }
                if front.count == 1 { return front[0] }
                if front.count > 1 { return nil }
                try? await Task.sleep(nanoseconds: 100_000_000)
            } while Date() < deadline
        }
        return nil
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
    static func openPopupMenu(
        _ popup: AXUIElement,
        app: AXUIElement,
        settleMs: Int,
        runtime: AXHelpers.Runtime
    ) async -> AXUIElement? {
        for action in [kAXShowMenuAction as String, kAXPressAction as String] {
            _ = AXHelpers.performAction(popup, action, runtime: runtime)
            try? await Task.sleep(nanoseconds: UInt64(max(settleMs, 350)) * 1_000_000)
            if let menu = PluginInspector.findOpenSettingMenuAX(in: app, runtime: runtime) {
                return menu
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
