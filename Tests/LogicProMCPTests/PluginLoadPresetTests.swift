@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// logic_plugins.load_preset at the channel layer (PLAN_PLUGINS_Y_PRESETS FASE C).
///
/// The fixture mirrors the verified-plugin live fixture (track headers, mixer
/// strip, insert slots, a plugin window titled by track) and adds what this op
/// walks: the Setting popup, its menu, a "Claude" folder and a leaf. Pressing a
/// leaf repaints the popup with the leaf's title, the way Logic does.
///
/// The insert's buttons behave as measured live 2026-09-18: "open" TOGGLES the
/// plugin window in and out of Logic's window list, and the window it opens is
/// NOT main or focused; "list" opens the plug-in chooser (which must never be
/// pressed); pressing the slot group itself does nothing.
private final class PresetFixture: @unchecked Sendable {
    let b = FakeAXRuntimeBuilder()
    let runtime: AXLogicProElements.Runtime
    let popup: AXUIElement
    let pressedLeaves = MutableBox<[String]>([])
    let activations = MutableBox<Int>(0)
    let openPresses = MutableBox<Int>(0)
    let listPressed = MutableBox<Bool>(false)

    static let trackName = "Audio 1"

    init(
        slotPlugin: String = "Compressor",
        popupValue: String = "Manual",
        leafTitles: [String] = ["Prueba", "Otra"],
        repaintTo: String? = nil,                 // popup value after a press; nil = the leaf title
        leafIsFolder: Bool = false,
        mixerRebuildsOnLoad: Bool = false,
        appleMenuInMenuBar: Bool = false,
        sideChainPopupFirst: Bool = false,
        windowInitiallyOpen: Bool = false,
        openHasNoEffect: Bool = false,
        siblingWindowOpen: Bool = false,          // another insert of the same track has its window open
        chooserAlreadyOpen: Bool = false          // the plug-in chooser menu is up before the call
    ) {
        let b = self.b
        let app = b.element(1)
        let arrange = b.element(2)
        let headers = b.element(3)
        let mixer = b.element(4)
        let pluginWindow = b.element(5)
        let setting = b.element(6)
        let settingMenu = b.element(7)
        let claudeFolder = b.element(8)
        let claudeMenu = b.element(9)

        // Track header + mixer strip with the plugin at insert 0.
        let row = b.element(100)
        b.setAttribute(row, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        b.setAttribute(row, kAXDescriptionAttribute as String, "1개의 ‘\(Self.trackName)’ 트랙")
        b.setAttribute(row, kAXSelectedAttribute as String, true)
        b.setAttribute(headers, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(headers, kAXDescriptionAttribute as String, "트랙 헤더")
        b.setChildren(headers, [row])

        let slot = b.element(200)
        let bypass = b.element(201)
        let open = b.element(202)
        let list = b.element(203)
        b.setAttribute(slot, kAXRoleAttribute as String, kAXGroupRole as String)
        b.setAttribute(slot, kAXDescriptionAttribute as String, slotPlugin)
        b.setChildren(slot, [bypass, open, list])
        b.setAttribute(list, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(list, kAXDescriptionAttribute as String, "list")
        b.setAttribute(bypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(bypass, kAXDescriptionAttribute as String, "바이패스")
        b.setAttribute(bypass, kAXValueAttribute as String, 0)
        b.setAttribute(open, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(open, kAXDescriptionAttribute as String, "열기")
        let strip = b.element(300)
        b.setAttribute(strip, kAXRoleAttribute as String, kAXLayoutItemRole as String)
        b.setChildren(strip, [slot])
        b.setAttribute(mixer, kAXRoleAttribute as String, "AXLayoutArea")
        b.setAttribute(mixer, kAXDescriptionAttribute as String, "Mixer")
        b.setChildren(mixer, [strip])
        b.setAttribute(arrange, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(arrange, kAXTitleAttribute as String, "Prueba — Tracks")
        b.setChildren(arrange, [headers, mixer])

        // Setting menu: the fingerprint items, a "Claude" folder, and presets.
        func item(_ id: Int, _ title: String) -> AXUIElement {
            let el = b.element(id)
            b.setAttribute(el, kAXRoleAttribute as String, kAXMenuItemRole as String)
            b.setAttribute(el, kAXTitleAttribute as String, title)
            return el
        }
        let fingerprint = ["Copy", "Paste", "Save As…", "Save A Copy As…", "Recall Default"]
            .enumerated().map { item(400 + $0.offset, $0.element) }
        b.setAttribute(claudeFolder, kAXRoleAttribute as String, kAXMenuItemRole as String)
        b.setAttribute(claudeFolder, kAXTitleAttribute as String, "Claude")
        b.setAttribute(settingMenu, kAXRoleAttribute as String, kAXMenuRole as String)
        b.setChildren(settingMenu, fingerprint + [claudeFolder])
        let leaves = leafTitles.enumerated().map { item(500 + $0.offset, $0.element) }
        if leafIsFolder {
            let inner = b.element(599)
            b.setAttribute(inner, kAXRoleAttribute as String, kAXMenuRole as String)
            b.setChildren(leaves[0], [inner])
        }
        b.setAttribute(claudeMenu, kAXRoleAttribute as String, kAXMenuRole as String)
        b.setChildren(claudeMenu, leaves)

        b.setAttribute(setting, kAXRoleAttribute as String, kAXPopUpButtonRole as String)
        b.setAttribute(setting, kAXValueAttribute as String, popupValue)

        // Optional Side Chain popup whose menu lacks the fingerprint.
        var popups = [setting]
        let sideChain = b.element(10)
        let sideChainMenu = b.element(11)
        if sideChainPopupFirst {
            b.setAttribute(sideChain, kAXRoleAttribute as String, kAXPopUpButtonRole as String)
            b.setAttribute(sideChain, kAXValueAttribute as String, "Internal")
            b.setAttribute(sideChainMenu, kAXRoleAttribute as String, kAXMenuRole as String)
            b.setChildren(sideChainMenu, ["Internal", "Input", "Bus 1", "Bus 2", "Audio 2"]
                .enumerated().map { item(600 + $0.offset, $0.element) })
            popups = [sideChain, setting]
        }

        b.setAttribute(pluginWindow, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(pluginWindow, kAXSubroleAttribute as String, kAXDialogSubrole as String)
        b.setAttribute(pluginWindow, kAXTitleAttribute as String, Self.trackName)
        b.setAttribute(pluginWindow, kAXMainAttribute as String, false)
        b.setAttribute(pluginWindow, kAXFocusedAttribute as String, false)
        // `isPluginEditorWindow` requires the chrome Logic draws on every plugin
        // window: a close button and a toggle labeled exactly "bypass".
        let close = b.element(30), windowBypass = b.element(31)
        b.setAttribute(close, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(windowBypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(windowBypass, kAXDescriptionAttribute as String, "bypass")
        b.setAttribute(pluginWindow, kAXCloseButtonAttribute as String, close)
        b.setChildren(pluginWindow, [windowBypass] + popups)

        let sibling = b.element(40), siblingClose = b.element(41), siblingBypass = b.element(42)
        b.setAttribute(sibling, kAXRoleAttribute as String, kAXWindowRole as String)
        b.setAttribute(sibling, kAXTitleAttribute as String, Self.trackName)
        b.setAttribute(siblingClose, kAXRoleAttribute as String, kAXButtonRole as String)
        b.setAttribute(siblingBypass, kAXRoleAttribute as String, kAXCheckBoxRole as String)
        b.setAttribute(siblingBypass, kAXDescriptionAttribute as String, "bypass")
        b.setAttribute(sibling, kAXCloseButtonAttribute as String, siblingClose)
        b.setChildren(sibling, [siblingBypass])

        // The plug-in chooser the "list" button opens: a big menu outside the menu bar.
        let chooser = b.element(50)
        b.setAttribute(chooser, kAXRoleAttribute as String, kAXMenuRole as String)
        b.setChildren(chooser, ["Channel EQ", "Compressor", "ChromaVerb", "Gain", "Delay", "AmpliTube"]
            .enumerated().map { item(800 + $0.offset, $0.element) })

        // The live trap (2026-09-18): the menu bar's Apple menu is in the same
        // app tree and has ≥5 items, so a whole-app "any open menu" search finds
        // it before the Setting menu.
        var appChildren: [AXUIElement] = []
        if appleMenuInMenuBar {
            let bar = b.element(20), barItem = b.element(21), appleMenu = b.element(22)
            b.setAttribute(bar, kAXRoleAttribute as String, kAXMenuBarRole as String)
            b.setAttribute(barItem, kAXRoleAttribute as String, kAXMenuBarItemRole as String)
            b.setAttribute(appleMenu, kAXRoleAttribute as String, kAXMenuRole as String)
            b.setChildren(appleMenu, ["About This Mac", "System Information", "System Settings…",
                                      "App Store…", "Recent Items", "Force Quit…"]
                .enumerated().map { item(700 + $0.offset, $0.element) })
            b.setChildren(barItem, [appleMenu])
            b.setChildren(bar, [barItem])
            appChildren.append(bar)
        }
        let baseAppChildren = appChildren
        b.setChildren(app, baseAppChildren + (chooserAlreadyOpen ? [chooser] : []))
        let windowsWithout = [arrange] + (siblingWindowOpen ? [sibling] : [])
        b.setAttribute(app, kAXWindowsAttribute as String,
                       windowsWithout + (windowInitiallyOpen ? [pluginWindow] : []))
        b.setAttribute(app, kAXMainWindowAttribute as String, arrange)
        let pluginWindowOpen = MutableBox<Bool>(windowInitiallyOpen)

        let keys = (slot: b.elementID(slot), open: b.elementID(open), list: b.elementID(list),
                    chooser: b.elementID(chooser), setting: b.elementID(setting),
                    sideChain: b.elementID(sideChain), claude: b.elementID(claudeFolder),
                    leaves: leaves.map { b.elementID($0) })
        let pressed = pressedLeaves
        let activations = self.activations
        let openPresses = self.openPresses
        let listPressed = self.listPressed
        self.popup = setting
        self.runtime = b.makeLogicRuntime(
            appElement: app,
            setAttributeHandler: { [b] el, attribute, value in
                b.setAttribute(el, attribute, value)
                return true
            },
            performActionHandler: { [b] el, action in
                let key = b.elementID(el)
                if action == (kAXCancelAction as String) {
                    if key == keys.chooser { b.setChildren(app, baseAppChildren); return true }
                    b.setChildren(setting, []); b.setChildren(sideChain, [])
                    return true
                }
                if key == keys.slot { return false }        // the group itself does nothing
                if key == keys.list {
                    listPressed.value = true
                    b.setChildren(app, baseAppChildren + [chooser])
                    return true
                }
                if key == keys.open {
                    openPresses.value += 1
                    if openHasNoEffect { return false }
                    pluginWindowOpen.value.toggle()      // measured: a toggle, never main/focused
                    b.setAttribute(app, kAXWindowsAttribute as String,
                                   windowsWithout + (pluginWindowOpen.value ? [pluginWindow] : []))
                    return false                         // real 12.3: acts, reports non-zero
                }
                if key == keys.setting, action == (kAXShowMenuAction as String) {
                    b.setChildren(setting, [settingMenu])
                    return false
                }
                if key == keys.sideChain, action == (kAXShowMenuAction as String) {
                    b.setChildren(sideChain, [sideChainMenu])
                    return false
                }
                if key == keys.claude, action == (kAXPressAction as String) {
                    b.setChildren(claudeFolder, [claudeMenu])
                    return true
                }
                if let i = keys.leaves.firstIndex(of: key), action == (kAXPressAction as String) {
                    let title = leafTitles[i]
                    pressed.value.append(title)
                    if !leafIsFolder || i != 0 {
                        b.setAttribute(setting, kAXValueAttribute as String, repaintTo ?? title)
                        b.setChildren(setting, [])       // the menu closes after a pick
                    }
                    if mixerRebuildsOnLoad {
                        // Live 2026-09-18: the strip held from before the load reads
                        // empty afterwards; a fresh walk finds the plugin in a new one.
                        let fresh = b.element(301)
                        b.setAttribute(fresh, kAXRoleAttribute as String, kAXLayoutItemRole as String)
                        b.setChildren(fresh, [slot])
                        b.setChildren(strip, [])
                        b.setChildren(mixer, [fresh])
                    }
                    return true
                }
                return true
            }
        )
    }

    func run(_ path: [String], plugin: String = "Compressor") async -> ChannelResult {
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: path), as: UTF8.self)
        return await AccessibilityChannel.defaultLoadPreset(
            params: ["track": "0", "insert": "0", "plugin": plugin, "preset_path": json],
            runtime: runtime,
            frontDocumentPath: { "/tmp/Prueba.logicx" },
            activateLogic: { [activations] in activations.value += 1; return true },
            settleMs: 1,
            windowTimeoutMs: 300
        )
    }
}

// MARK: - scan_plugin_presets, targeted (same fixture: same window and menu)

extension PresetFixture {
    /// Live Logic exposes a folder's submenu as an AXMenu child before it is
    /// opened; that is how the scan's walker tells folders from presets.
    func exposeClaudeSubmenu() { b.setChildren(b.element(8), [b.element(9)]) }

    func scan(plugin: String = "Compressor") async -> ChannelResult {
        await AccessibilityChannel.runLivePluginPresetScan(
            runtime: runtime, settleMs: 0,
            target: .init(track: 0, insert: 0, plugin: plugin),
            activateLogic: { [activations] in activations.value += 1; return true },
            windowTimeoutMs: 300
        )
    }
}

/// Every node path in a scan result (the encoder escapes "/", so decode).
private func scannedPaths(_ result: ChannelResult) -> Set<String> {
    guard let data = result.message.data(using: .utf8),
          let cache = try? JSONDecoder().decode(PluginPresetCache.self, from: data) else { return [] }
    var paths = Set<String>()
    func visit(_ node: PluginPresetNode) {
        paths.insert(node.path)
        node.children.forEach(visit)
    }
    visit(cache.root)
    return paths
}

@Suite("scan_plugin_presets targeted")
struct PluginScanPresetsTargetedTests {
    @Test("lists one insert's Setting menu, folders included, and loads nothing")
    func listsWithoutLoading() async {
        let f = PresetFixture(popupValue: "Prueba Claude threshold -31.5")   // a loaded preset's name
        f.exposeClaudeSubmenu()
        let result = await f.scan()
        #expect(result.isSuccess)
        #expect(result.message.contains("\"pluginName\":\"Compressor\""))
        let paths = scannedPaths(result)
        #expect(paths.contains("Claude/Prueba"))
        #expect(paths.contains("Claude/Otra"))
        #expect(paths.contains("Recall Default"))
        #expect(f.pressedLeaves.value.isEmpty)       // walking never presses a preset
        #expect(f.openPresses.value == 1)
        #expect(isFalseFact(f.listPressed.value))

        // Why the target exists: the legacy scan looks for a popup reading
        // "Preset"/"Default" and finds nothing once a preset is loaded.
        let legacy = await AccessibilityChannel.runLivePluginPresetScan(runtime: f.runtime, settleMs: 0)
        #expect(!legacy.isSuccess)
        #expect(legacy.message.contains("No plugin window with Setting dropdown found"))
    }

    @Test("the wrong plugin in the insert is refused before any window opens")
    func wrongPluginRefused() async {
        let f = PresetFixture(slotPlugin: "ChromaVerb")
        let result = await f.scan(plugin: "Compressor")
        #expect(!result.isSuccess)
        #expect(result.message.contains("holds 'ChromaVerb', not 'Compressor'"))
        #expect(f.openPresses.value == 0)
        #expect(f.activations.value == 0)
    }

    @Test("Side Chain and the Apple menu are never taken for the Setting menu")
    func fingerprintHolds() async {
        let f = PresetFixture(appleMenuInMenuBar: true, sideChainPopupFirst: true)
        f.exposeClaudeSubmenu()
        let result = await f.scan()
        #expect(result.isSuccess)
        #expect(result.message.contains("Recall Default"))
        #expect(!result.message.contains("About This Mac"))
        #expect(!result.message.contains("Bus 1"))
    }

    @Test("the Setting menu's own commands come back as actions, not presets")
    func commandsAreActions() async {
        let f = PresetFixture()
        f.exposeClaudeSubmenu()
        let result = await f.scan()
        guard let data = result.message.data(using: .utf8),
              let cache = try? JSONDecoder().decode(PluginPresetCache.self, from: data) else {
            Issue.record("scan did not return a preset cache"); return
        }
        let kinds = Dictionary(uniqueKeysWithValues: cache.root.children.map { ($0.name, $0.kind) })
        #expect(kinds["Save As…"] == .action)
        #expect(kinds["Recall Default"] == .action)
        #expect(kinds["Copy"] == .action)
        #expect(kinds["Claude"] == .folder)
        let leaf = cache.root.children.first { $0.name == "Claude" }?.children.first { $0.name == "Prueba" }
        #expect(leaf?.kind == .leaf)                    // a preset named like nothing special stays a preset
    }

    @Test("an already-open window is reopened, and a dead 'open' fails closed")
    func windowStates() async {
        let open = PresetFixture(windowInitiallyOpen: true)
        open.exposeClaudeSubmenu()
        #expect(await open.scan().isSuccess)
        #expect(open.openPresses.value == 2)

        let dead = PresetFixture(openHasNoEffect: true)
        let result = await dead.scan()
        #expect(!result.isSuccess)
        #expect(result.message.contains("did not open (no_new_window"))
        #expect(isFalseFact(dead.listPressed.value))
    }
}

/// Under this repo's swift-testing 0.99.0 + Swift 6.4, `#expect(a == b)` never
/// fails when the operands are Bool (measured 2026-09-18: `t == false`,
/// `t == f`, `opt as? Bool == false` all pass). Bool facts are therefore
/// checked through these, whose comparison runs outside the macro.
func isTrueFact(_ value: Any?) -> Bool { (value as? Bool) == true }
func isFalseFact(_ value: Any?) -> Bool { (value as? Bool) == false }

private func body(_ result: ChannelResult) -> [String: Any] {
    let text: String
    switch result {
    case .success(let s), .error(let s): text = s
    }
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

@Suite("logic_plugins.load_preset")
struct PluginLoadPresetTests {

    @Test("a unique leaf under the Setting menu loads and reads back as State A")
    func loadsAndReadsBack() async {
        let f = PresetFixture()
        let result = await f.run(["Claude", "Prueba"])
        let obj = body(result)
        #expect(obj["state"] as? String == "A")
        #expect(obj["requested"] as? String == "Prueba")
        #expect(obj["observed"] as? String == "Prueba")
        #expect(obj["popup_value_before"] as? String == "Manual")
        #expect(f.pressedLeaves.value == ["Prueba"])
    }

    /// Regression, measured live 2026-09-18: the whole-app menu search returned
    /// the Apple menu from the menu bar, the fingerprint rejected it, and the
    /// real Setting menu was never found. The popup's own menu must win.
    @Test("the menu bar's Apple menu is never mistaken for the Setting menu")
    func menuBarDoesNotShadowTheSettingMenu() async {
        let f = PresetFixture(appleMenuInMenuBar: true, sideChainPopupFirst: true)
        let obj = body(await f.run(["Claude", "Prueba"]))
        #expect(obj["state"] as? String == "A", "got \(obj)")
        #expect(f.pressedLeaves.value == ["Prueba"])
    }

    @Test("a popup whose menu lacks the fingerprint (Side Chain) is skipped, not used")
    func sideChainPopupIsSkipped() async {
        let f = PresetFixture(sideChainPopupFirst: true)
        let obj = body(await f.run(["Claude", "Prueba"]))
        #expect(obj["state"] as? String == "A")
    }

    @Test("the popup's loaded name cannot hide it: 'Manual' or a preset name both work")
    func popupValueDoesNotMatter() async {
        for value in ["Manual", "CensoComp-valores2", "#default"] {
            let f = PresetFixture(popupValue: value)
            #expect(body(await f.run(["Claude", "Prueba"]))["state"] as? String == "A", "\(value)")
        }
    }

    @Test("a missing leaf is State C with the real titles, and nothing is pressed")
    func missingLeafListsWhatIsThere() async {
        let f = PresetFixture()
        let obj = body(await f.run(["Claude", "No existe"]))
        #expect(obj["state"] as? String == "C")
        #expect(isFalseFact(obj["write_attempted"]))
        #expect((obj["available_at_level"] as? [String]) == ["Prueba", "Otra"])
        #expect(f.pressedLeaves.value.isEmpty)
    }

    @Test("a Setting-menu command is never pressed as if it were a preset")
    func commandIsRefused() async {
        for command in ["Delete", "Save As…", "Save As...", "recall default", "Copy"] {
            let f = PresetFixture()
            let obj = body(await f.run([command]))
            #expect(obj["state"] as? String == "C")
            #expect(obj["error"] as? String == "invalid_params")
            #expect(isFalseFact(obj["write_attempted"]))
            #expect(f.activations.value == 0)            // refused before Logic is touched
            #expect(f.openPresses.value == 0)
        }
        // A folder named like a command is fine two levels down: only the root holds commands.
        let nested = PresetFixture(leafTitles: ["Delete", "Otra"])
        #expect(body(await nested.run(["Claude", "Delete"]))["state"] as? String == "A")
    }

    @Test("a repeated leaf title is refused rather than guessed")
    func repeatedLeafIsRefused() async {
        let f = PresetFixture(leafTitles: ["Prueba", "Prueba"])
        let obj = body(await f.run(["Claude", "Prueba"]))
        #expect(obj["state"] as? String == "C")
        #expect(f.pressedLeaves.value.isEmpty)
    }

    @Test("a folder at the end of the path is State C folder_not_preset")
    func folderIsNotAPreset() async {
        let f = PresetFixture(leafIsFolder: true)
        let obj = body(await f.run(["Claude", "Prueba"]))
        #expect(obj["error"] as? String == "folder_not_preset")
        #expect(f.pressedLeaves.value.isEmpty)
    }

    /// Regression, measured live 2026-09-18: the load succeeded (the popup read
    /// back the exact leaf) but the receipt said the insert "no longer reads as
    /// Compressor" — because the strip element held since before the load read
    /// empty, not because the plugin changed.
    @Test("a mixer rebuilt by the load is re-read fresh and still reaches State A")
    func staleStripIsReReadFresh() async {
        let f = PresetFixture(mixerRebuildsOnLoad: true)
        let obj = body(await f.run(["Claude", "Prueba"]))
        #expect(obj["state"] as? String == "A", "got \(obj)")
        #expect(obj["plugin_after"] as? String == "Compressor")
    }

    @Test("a readback that differs from the pressed leaf is State B, never A")
    func readbackMismatchIsStateB() async {
        let f = PresetFixture(repaintTo: "Algo más")
        let obj = body(await f.run(["Claude", "Prueba"]))
        #expect(obj["state"] as? String == "B")
        #expect(obj["reason"] as? String == "readback_mismatch")
        #expect(obj["observed"] as? String == "Algo más")
    }

    @Test("the wrong plugin in the insert is refused before any window opens")
    func wrongPluginIsRefused() async {
        let f = PresetFixture(slotPlugin: "ChromaVerb")
        let obj = body(await f.run(["Claude", "Prueba"]))
        #expect(obj["error"] as? String == "target_plugin_mismatch")
        #expect(isFalseFact(obj["write_attempted"]))
        #expect(f.pressedLeaves.value.isEmpty)
        #expect(f.activations.value == 0)          // a refusal never pulls Logic to the front
    }

    @Test("a closed window opened by 'open' is used though Logic never makes it main")
    func closedWindowOpensWithoutBecomingMain() async {
        // Live 2026-09-18: the old "which window is front" test never saw it,
        // pressed on, and the slot's "list" button opened the plug-in chooser.
        let f = PresetFixture()
        let obj = body(await f.run(["Claude", "Prueba"]))
        #expect(obj["state"] as? String == "A")
        #expect(obj["window_outcome"] as? String == "opened")
        #expect(f.openPresses.value == 1)
        #expect(isFalseFact(f.listPressed.value))
        #expect(f.activations.value == 1)
    }

    @Test("an already-open window is closed by the toggle and brought back by one more press")
    func openWindowIsReopened() async {
        let f = PresetFixture(windowInitiallyOpen: true)
        let obj = body(await f.run(["Claude", "Prueba"]))
        #expect(obj["state"] as? String == "A")
        #expect(obj["window_outcome"] as? String == "reopened")
        #expect(f.openPresses.value == 2)
        #expect(isFalseFact(f.listPressed.value))
    }

    @Test("another insert's window with the same title is never taken for ours")
    func siblingWindowIsIgnored() async {
        for initiallyOpen in [false, true] {
            let f = PresetFixture(windowInitiallyOpen: initiallyOpen, siblingWindowOpen: true)
            let obj = body(await f.run(["Claude", "Prueba"]))
            #expect(obj["state"] as? String == "A")
            #expect(obj["window_outcome"] as? String == (initiallyOpen ? "reopened" : "opened"))
            #expect(f.pressedLeaves.value == ["Prueba"])
        }
    }

    @Test("re-picking the preset the popup already shows is flagged already_selected")
    func alreadySelectedIsFlagged() async {
        let fresh = body(await PresetFixture(popupValue: "Otra").run(["Claude", "Prueba"]))
        #expect(isFalseFact(fresh["already_selected"]))
        let again = body(await PresetFixture(popupValue: "Prueba").run(["Claude", "Prueba"]))
        #expect(again["state"] as? String == "A")
        #expect(isTrueFact(again["already_selected"]))
        #expect(isFalseFact(again["menu_left_open"]))
    }

    @Test("an 'open' that raises nothing fails closed, never presses 'list', and clears a stray menu")
    func deadOpenFailsClosed() async {
        let f = PresetFixture(openHasNoEffect: true, chooserAlreadyOpen: true)
        let obj = body(await f.run(["Claude", "Prueba"]))
        #expect(obj["state"] as? String == "C")
        #expect(obj["error"] as? String == "window_open_failed")
        #expect(isFalseFact(obj["write_attempted"]))
        #expect(obj["window_outcome"] as? String == "no_new_window")
        #expect(isTrueFact(obj["stray_menu_dismissed"]))
        #expect(f.openPresses.value == 1)
        #expect(isFalseFact(f.listPressed.value))
        #expect(f.pressedLeaves.value.isEmpty)
    }

    @Test("plugin names match case-insensitively; paths decode from JSON only")
    func helpers() {
        #expect(AccessibilityChannel.pluginNamesMatch("AmpliTube", " amplitube "))
        #expect(!AccessibilityChannel.pluginNamesMatch("AmpliTube", "AmpliTube 5"))
        #expect(AccessibilityChannel.decodePresetPath(#"["Claude","80's"]"#) == ["Claude", "80's"])
        #expect(AccessibilityChannel.decodePresetPath(#"["Claude",""]"#) == nil)
        #expect(AccessibilityChannel.decodePresetPath("Claude/Prueba") == nil)
        #expect(AccessibilityChannel.normalizedMenuTitle("Save As…") == "save as")
        #expect(AccessibilityChannel.normalizedMenuTitle("Save As...") == "save as")
    }
}
