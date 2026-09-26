import Foundation
import Testing
@testable import LogicProMCP

/// The server process runs under the App Sandbox, where its own Accessibility
/// calls return nil — every AX read has to go through the unsandboxed helper.
/// Two server guards were still reading AX directly and therefore failed closed
/// the moment the sandbox came back (live 2026-09-19: `load_preset` refused with
/// `header_unreadable` because `expected_name` could not be corroborated).
///
/// This test pins the boundary: outside `Channels/` and `Accessibility/` (which
/// run inside the helper), the only files allowed to name AX directly are the
/// ones listed here, each for a stated reason. A new name in this list is a
/// decision, not an accident: either route it through the helper, or say why it
/// may stay and what it degrades to when the read comes back nil.
private func repositoryRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

/// Files that still read Accessibility from the server, and what happens under
/// the sandbox (all of them degrade to "unreadable", never to a false green).
private let knownDirectAXFiles: [String: String] = [
    "Server/LogicProServer.swift":
        "MCU control-surface readback (volume/pan/automation/selected track): comes back nil, so the MCU route reports unverified and the accessibility route through the helper takes over.",
    "Saga/SagaExecution.swift":
        "SagaLiveReadback.production: nil readings make a saga step fail closed instead of claiming verification.",
    "Dispatchers/TrackDispatcher+RecordSequence.swift":
        "Live track-header count/name around a MIDI import: nil means record_sequence reports import_unverified instead of a wrong track.",
    "Dispatchers/SystemDispatcher.swift":
        "Logic's UI locale for health/diagnostics: falls back to \"unknown\".",
    "Dispatchers/DispatcherSupport.swift":
        "Default argument for the blocking-dialog identity in a refusal payload; production passes the helper-read value, so only the identity fields would be missing.",
    "MIDIReadback/EventListMIDINoteReadbackProvider.swift":
        "Reads Logic's Event List window for MIDI note readback: nil makes the readback unavailable, which the caller reports as unverified.",
    "MIDIReadback/EventListReadbackCollector.swift":
        "Same Event List readback path.",
    "Utilities/SetupDoctor.swift":
        "Diagnostic default for `logic-pro-mcp doctor`: reports a dialog it can see; under the sandbox it reports none, which is a weaker diagnostic, never a wrong refusal.",
    "State/StatePoller.swift":
        "Runtime.production's synchronous dialog closures, kept as the deterministic test seam; production injects readBlockingDialog, which asks the helper.",
]

private func serverSideSwiftFiles() throws -> [(relative: String, source: String)] {
    let root = repositoryRootURL().appendingPathComponent("Sources/LogicProMCP", isDirectory: true)
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    var files: [(String, String)] = []
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        guard !relative.hasPrefix("Channels/"), !relative.hasPrefix("Accessibility/") else { continue }
        files.append((relative, try String(contentsOf: url, encoding: .utf8)))
    }
    return files
}

/// Code, not prose: a mention inside a comment is documentation, not a call.
private func namesAXOutsideComments(_ source: String) -> Bool {
    for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("//") || line.hasPrefix("///") || line.hasPrefix("*") { continue }
        let code = line.components(separatedBy: "//").first ?? line
        // `AXLogicProElements.BlockingDialogInfo` is a type the server passes
        // around; naming it is not reading Accessibility.
        let calls = code.replacingOccurrences(of: "AXLogicProElements.BlockingDialogInfo", with: "")
        if calls.contains("AXLogicProElements.") || calls.contains("AXHelpers.") || calls.contains("AXUIElementCreate") {
            return true
        }
    }
    return false
}

@Test func testTheServerReadsAccessibilityOnlyThroughTheHelper() throws {
    let offenders = try serverSideSwiftFiles()
        .filter { namesAXOutsideComments($0.source) }
        .map(\.relative)
        .filter { knownDirectAXFiles[$0] == nil }
        .sorted()

    #expect(offenders.isEmpty, """
        These server-side files read Accessibility directly, which returns nil under the \
        App Sandbox: \(offenders.joined(separator: ", ")). Route the read through the helper \
        (a channel operation + AXFacts), or add the file to knownDirectAXFiles with the \
        reason and what it degrades to.
        """)
}

@Test func testTheIdentityAndDialogGuardsNoLongerReadAXThemselves() throws {
    let sources = try serverSideSwiftFiles()
    func source(_ relative: String) throws -> String {
        guard let text = sources.first(where: { $0.relative == relative })?.source else {
            Issue.record("missing \(relative)")
            return ""
        }
        // Code only: these files still DESCRIBE the old reads in their comments.
        var codeLines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            codeLines.append(line.components(separatedBy: "//")[0])
        }
        return codeLines.joined(separator: "\n")
    }
    // The two guards that the sandbox broke: they now read what the helper saw.
    #expect(!(try source("Server/OperationHandlerRegistry.swift").contains("AXLogicProElements.trackName")))
    #expect(!(try source("Server/LogicProServer.swift").contains("AXLogicProElements.dialogPresent")))
    #expect(!(try source("Projects/ProjectExportExecutor.swift").contains("AXLogicProElements.dialogPresent")))
}

@Test func testFactsAreUnreadUntilSomethingPublishesThem() {
    let facts = AXFacts()
    #expect(facts.trackNames == nil)
    #expect(facts.trackName(at: 0) == nil)
    #expect(isFalseFact(facts.dialogPresent))

    facts.update(trackNames: [0: "Audio 1", 1: "Audio 2"], blockingDialog: nil)
    #expect(facts.trackName(at: 1) == "Audio 2")
    #expect(isFalseFact(facts.dialogPresent))

    let dialog = AXLogicProElements.BlockingDialogInfo(
        title: "Save changes?", role: "AXSheet", owningWindow: "Untitled",
        buttonTitles: ["Cancel", "Save"], recoveryAction: "Cancel"
    )
    facts.update(trackNames: [0: "Audio 1"], blockingDialog: dialog)
    #expect(isTrueFact(facts.dialogPresent))
    #expect(facts.blockingDialog?.buttonTitles == ["Cancel", "Save"])

    // A failed read is published as unread, never as "no tracks" or "no dialog"
    // standing in for a live value.
    facts.update(trackNames: nil, blockingDialog: nil)
    #expect(facts.trackNames == nil)
    facts.clear()
    #expect(facts.current.updatedAt == nil)
}
