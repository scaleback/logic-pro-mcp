@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

// #346 — exhaustive, deterministic truth table for the pure modal-reconciliation
// core (classify + decide). No AX / live Logic; the live reader + executor are
// verified separately. Enum `==` comparisons below are non-optional Bool
// expressions (NOT the dead `#expect(optionalBool == true)` pattern).

private func makeSignals(
    sheetPresent: Bool = false,
    sheetDescription: String = "",
    createButtonPresent: Bool = false,
    cancelButtonPresent: Bool = false,
    cancelButtonEnabled: Bool = true,
    deleteConfirmButtonPresent: Bool = false,
    strayMenuOpen: Bool = false,
    topLevelAlertPresent: Bool = false,
    topLevelAlertButtonCount: Int = 0,
    topLevelAlertPrimaryButton: String = "",
    createButtonTitle: String = "",
    cancelButtonTitle: String = "",
    deletePrimaryTitle: String = ""
) -> ModalReconciliation.ModalSignals {
    ModalReconciliation.ModalSignals(
        sheetPresent: sheetPresent,
        sheetDescription: sheetDescription,
        createButtonPresent: createButtonPresent,
        cancelButtonPresent: cancelButtonPresent,
        cancelButtonEnabled: cancelButtonEnabled,
        deleteConfirmButtonPresent: deleteConfirmButtonPresent,
        strayMenuOpen: strayMenuOpen,
        topLevelAlertPresent: topLevelAlertPresent,
        topLevelAlertButtonCount: topLevelAlertButtonCount,
        topLevelAlertPrimaryButton: topLevelAlertPrimaryButton,
        createButtonTitle: createButtonTitle,
        cancelButtonTitle: cancelButtonTitle,
        deletePrimaryTitle: deletePrimaryTitle
    )
}

// MARK: - classify

@Test func testClassifyMandatoryNewTrackViaDisabledCancel() {
    // Live shape: Create enabled, Cancel present-but-disabled (Escape inert).
    let signals = makeSignals(
        sheetPresent: true,
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: false
    )
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

@Test func testClassifyMandatoryNewTrackViaDescription() {
    // Description alone identifies the sheet even if button state is unreadable.
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "New Track"
    )
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

@Test func testClassifyDeleteConfirm() {
    let signals = makeSignals(
        sheetPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: true,
        deleteConfirmButtonPresent: true
    )
    #expect(ModalReconciliation.classify(signals) == .deleteConfirm)
}

@Test func testClassifyStrayMenu() {
    let signals = makeSignals(sheetPresent: false, strayMenuOpen: true)
    #expect(ModalReconciliation.classify(signals) == .strayMenu)
}

@Test func testClassifyUnknownSheet() {
    // A sheet with none of the recognised signals — never auto-dismissed.
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "Some Other Sheet",
        createButtonPresent: false,
        cancelButtonPresent: true,
        cancelButtonEnabled: true
    )
    #expect(ModalReconciliation.classify(signals) == .unknownSheet)
}

@Test func testClassifyNone() {
    #expect(ModalReconciliation.classify(makeSignals()) == .none)
}

@Test func testClassifySheetWinsOverStrayMenu() {
    // A present sheet is the stronger blocker even if a menu also reads open.
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "New Track",
        strayMenuOpen: true
    )
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

// MARK: - discriminator: disabled Cancel is the mandatory-sheet signal

@Test func testDisabledCancelIsTheMandatoryDiscriminator() {
    // Two sheets identical except Cancel's enabled state (and no "New Track"
    // description): disabled Cancel => mandatory; enabled Cancel => ordinary
    // cancelable sheet (unknown, fail-closed) — never auto-Created.
    let mandatory = makeSignals(
        sheetPresent: true,
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: false
    )
    let ordinary = makeSignals(
        sheetPresent: true,
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: true
    )
    #expect(ModalReconciliation.classify(mandatory) == .mandatoryNewTrack)
    #expect(ModalReconciliation.classify(ordinary) == .unknownSheet)
}

@Test func testDeleteConfirmWithDisabledCancelIsNotMisreadAsNewTrack() {
    // A delete-confirm sheet has NO Create button, so a disabled Cancel must not
    // promote it to mandatoryNewTrack (the createButtonPresent conjunct guards).
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "Delete channel strips",
        createButtonPresent: false,
        cancelButtonPresent: true,
        cancelButtonEnabled: false,
        deleteConfirmButtonPresent: true
    )
    #expect(ModalReconciliation.classify(signals) == .deleteConfirm)
}

// MARK: - decide

@Test func testDecideMandatoryNewTrackAlwaysClicksCreate() {
    #expect(ModalReconciliation.decide(kind: .mandatoryNewTrack, isDeleteContext: true) == .clickCreate)
    #expect(ModalReconciliation.decide(kind: .mandatoryNewTrack, isDeleteContext: false) == .clickCreate)
}

@Test func testDecideDeleteConfirmInDeleteContext() {
    #expect(ModalReconciliation.decide(kind: .deleteConfirm, isDeleteContext: true) == .confirmDelete)
}

@Test func testDecideDeleteConfirmOutsideDeleteContextFailsClosed() {
    let decision = ModalReconciliation.decide(kind: .deleteConfirm, isDeleteContext: false)
    #expect(decision == .failClosed("unexpected delete-confirm sheet"))
    // Must NOT confirm a delete the caller did not request.
    #expect(decision != .confirmDelete)
}

@Test func testDecideStrayMenuEscapes() {
    #expect(ModalReconciliation.decide(kind: .strayMenu, isDeleteContext: false) == .escapeMenu)
}

@Test func testDecideUnknownSheetFailsClosedAndIsNotDismissed() {
    let decision = ModalReconciliation.decide(kind: .unknownSheet, isDeleteContext: true)
    #expect(decision == .failClosed("unexpected blocking sheet"))
    // A "Save changes?" could lose data — assert we never auto-dismiss/act.
    #expect(decision != .clickCreate)
    #expect(decision != .confirmDelete)
    #expect(decision != .escapeMenu)
    #expect(decision != .noAction)
}

@Test func testDecideNoneIsNoAction() {
    #expect(ModalReconciliation.decide(kind: .none, isDeleteContext: true) == .noAction)
    #expect(ModalReconciliation.decide(kind: .none, isDeleteContext: false) == .noAction)
}

// MARK: - end-to-end pipeline (classify -> decide)

@Test func testPipelineNewTrackSheetAutoCreates() {
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "New Track",
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: false
    )
    let kind = ModalReconciliation.classify(signals)
    #expect(kind == .mandatoryNewTrack)
    #expect(ModalReconciliation.decide(kind: kind, isDeleteContext: true) == .clickCreate)
}

@Test func testPipelineDeleteConfirmConfirmsInDeleteContext() {
    let signals = makeSignals(
        sheetPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: true,
        deleteConfirmButtonPresent: true
    )
    let kind = ModalReconciliation.classify(signals)
    #expect(kind == .deleteConfirm)
    #expect(ModalReconciliation.decide(kind: kind, isDeleteContext: true) == .confirmDelete)
}

// MARK: - top-level informational alerts (#346 increment 2)

@Test func testSingleButtonTopLevelAlertIsAcknowledged() {
    // Live shape: top-level AXDialog "alert" with a single "OK" button.
    let signals = makeSignals(
        sheetPresent: false,
        topLevelAlertPresent: true,
        topLevelAlertButtonCount: 1,
        topLevelAlertPrimaryButton: "OK"
    )
    let kind = ModalReconciliation.classify(signals)
    #expect(kind == .informationalAlert)
    #expect(ModalReconciliation.decide(kind: kind, isDeleteContext: false) == .acknowledgeAlert)
    #expect(ModalReconciliation.decide(kind: kind, isDeleteContext: true) == .acknowledgeAlert)
}

@Test func testTwoButtonTopLevelDialogIsNeverAcknowledged() {
    // DATA-LOSS SAFETY GUARD: a 2+ button dialog is a CHOICE (e.g. Save /
    // Don't Save / Cancel) and must NEVER be auto-dismissed — classify to
    // unknownSheet, decide to failClosed, and assert it is not acknowledged.
    let signals = makeSignals(
        sheetPresent: false,
        topLevelAlertPresent: true,
        topLevelAlertButtonCount: 2,
        topLevelAlertPrimaryButton: "Save"
    )
    let kind = ModalReconciliation.classify(signals)
    #expect(kind == .unknownSheet)
    let decision = ModalReconciliation.decide(kind: kind, isDeleteContext: false)
    #expect(decision == .failClosed("unexpected blocking sheet"))
    #expect(decision != .acknowledgeAlert)
}

@Test func testZeroButtonTopLevelAlertFailsClosed() {
    // Present but no identifiable single button ⇒ cannot safely acknowledge.
    let signals = makeSignals(
        sheetPresent: false,
        topLevelAlertPresent: true,
        topLevelAlertButtonCount: 0
    )
    #expect(ModalReconciliation.classify(signals) == .unknownSheet)
}

@Test func testMainWindowSheetOutranksTopLevelAlert() {
    // Both present ⇒ the main-window sheet wins (sheet is the stronger blocker).
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "New Track",
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: false,
        topLevelAlertPresent: true,
        topLevelAlertButtonCount: 1,
        topLevelAlertPrimaryButton: "OK"
    )
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

@Test func testTopLevelAlertOutranksStrayMenu() {
    let signals = makeSignals(
        sheetPresent: false,
        strayMenuOpen: true,
        topLevelAlertPresent: true,
        topLevelAlertButtonCount: 1,
        topLevelAlertPrimaryButton: "OK"
    )
    #expect(ModalReconciliation.classify(signals) == .informationalAlert)
}

@Test func testDecideInformationalAlertAcknowledgesInAnyContext() {
    #expect(ModalReconciliation.decide(kind: .informationalAlert, isDeleteContext: true) == .acknowledgeAlert)
    #expect(ModalReconciliation.decide(kind: .informationalAlert, isDeleteContext: false) == .acknowledgeAlert)
}

// MARK: - create-path preflight scope (#348)

@Test func testPreflightCreateScopeDoesNotClickCreateForMandatoryNewTrack() {
    // DOUBLE-CREATE GUARD: in create scope the mandatory New Track sheet still
    // DECIDES clickCreate, but preflight must NOT PERFORM it — createTrackViaMenu
    // opens/confirms its own dialog, so acting here would create two tracks.
    #expect(ModalReconciliation.decide(kind: .mandatoryNewTrack, isDeleteContext: false) == .clickCreate)
    #expect(!ModalReconciliation.preflightShouldPerform(kind: .mandatoryNewTrack, clearMandatoryNewTrack: false))
}

@Test func testPreflightDefaultScopeClearsMandatoryNewTrack() {
    // Default scope (any other caller) still auto-clears the mandatory sheet.
    #expect(ModalReconciliation.preflightShouldPerform(kind: .mandatoryNewTrack, clearMandatoryNewTrack: true))
}

@Test func testPreflightCreateScopeStillAcknowledgesAlert() {
    #expect(ModalReconciliation.decide(kind: .informationalAlert, isDeleteContext: false) == .acknowledgeAlert)
    #expect(ModalReconciliation.preflightShouldPerform(kind: .informationalAlert, clearMandatoryNewTrack: false))
}

@Test func testPreflightCreateScopeStillEscapesStrayMenu() {
    #expect(ModalReconciliation.decide(kind: .strayMenu, isDeleteContext: false) == .escapeMenu)
    #expect(ModalReconciliation.preflightShouldPerform(kind: .strayMenu, clearMandatoryNewTrack: false))
}

@Test func testPreflightNeverActsOnDeleteConfirmUnknownOrNone() {
    for clear in [true, false] {
        #expect(!ModalReconciliation.preflightShouldPerform(kind: .deleteConfirm, clearMandatoryNewTrack: clear))
        #expect(!ModalReconciliation.preflightShouldPerform(kind: .unknownSheet, clearMandatoryNewTrack: clear))
        #expect(!ModalReconciliation.preflightShouldPerform(kind: .none, clearMandatoryNewTrack: clear))
    }
}

// MARK: - locale-aware classification (#350, Korean Logic)

@Test func testClassifyKoreanMandatoryNewTrackViaDisabledCancel() {
    // Logic 12.3 ko: 생성 / 취소(disabled) / desc 새로운 트랙. Must classify as the
    // mandatory New Track sheet just like English, not fall to .unknownSheet.
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "새로운 트랙",
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: false,
        createButtonTitle: "생성",
        cancelButtonTitle: "취소"
    )
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

@Test func testClassifyKoreanNewTrackViaDescriptionOnly() {
    // The localized description alone (새로운 트랙) identifies the sheet, even if
    // the disabled-Cancel signal were unreadable.
    let signals = makeSignals(sheetPresent: true, sheetDescription: "새로운 트랙")
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

@Test func testClassifyKoreanCancelableSheetIsNotMandatory() {
    // Korean sheet with 취소 ENABLED and a non-New-Track description must NOT be
    // misclassified as mandatory (no auto-Create) — it is an unknown sheet.
    let signals = makeSignals(
        sheetPresent: true,
        sheetDescription: "다른 시트",
        createButtonPresent: true,
        cancelButtonPresent: true,
        cancelButtonEnabled: true,
        createButtonTitle: "생성",
        cancelButtonTitle: "취소"
    )
    #expect(ModalReconciliation.classify(signals) == .unknownSheet)
}

@Test func testClassifyEnglishNewTrackDescriptionStillMatches() {
    // English description path still works after the LabelSet migration.
    let signals = makeSignals(sheetPresent: true, sheetDescription: "New Track")
    #expect(ModalReconciliation.classify(signals) == .mandatoryNewTrack)
}

// MARK: - AXLocalePolicy LabelSets added for the reconciler (#350)

@Test func testCreateButtonLabelSetMatchesEnAndKo() {
    #expect(AXLocalePolicy.createButton.matches("Create"))
    #expect(AXLocalePolicy.createButton.matches("생성"))
    #expect(!AXLocalePolicy.createButton.matches("취소"))
    #expect(!AXLocalePolicy.createButton.matches("Delete"))
}

@Test func testNewTrackSheetDescriptionLabelSetMatchesEnAndKo() {
    #expect(AXLocalePolicy.newTrackSheetDescription.matches("New Track"))
    #expect(AXLocalePolicy.newTrackSheetDescription.matches("새로운 트랙"))
    #expect(!AXLocalePolicy.newTrackSheetDescription.matches("Some Other Sheet"))
    // Diacritic-SENSITIVE: an accented English variant must NOT match.
    #expect(!AXLocalePolicy.newTrackSheetDescription.matches("Nèw Track"))
}

@Test func testDeleteTracksPrimaryButtonLabelSetEnglishOnly() {
    #expect(AXLocalePolicy.deleteTracksPrimaryButton.matches("Delete Tracks and Content"))
    // KO variant intentionally absent (unverified) — must not match a guess.
    #expect(!AXLocalePolicy.deleteTracksPrimaryButton.matches("트랙 및 콘텐츠 삭제"))
}

// MARK: - #545-class: per-track delete confirm sheets

/// Builds a Logic-shaped window carrying one AXSheet whose buttons sit one
/// AXGroup below it — the real shape, measured upstream on Logic 12.3: Logic
/// never vends `AXSheets`, the sheet is reachable only as an AXChildren member
/// with role AXSheet, and `every button of sheet` returns 0 because they live
/// in a nested group.
private func makeDeleteSheetFixture(
    buttonTitles: [String],
    sheetDescription: String
) -> (builder: FakeAXRuntimeBuilder, runtime: AXLogicProElements.Runtime) {
    let builder = FakeAXRuntimeBuilder()
    let app = builder.element(7_000)
    let window = builder.element(7_001)
    let sheet = builder.element(7_002)
    let buttonGroup = builder.element(7_003)

    builder.setAttribute(app, kAXMainWindowAttribute as String, window)
    builder.setAttribute(window, kAXRoleAttribute as String, kAXWindowRole as String)

    builder.setAttribute(sheet, kAXRoleAttribute as String, kAXSheetRole as String)
    builder.setAttribute(sheet, kAXDescriptionAttribute as String, sheetDescription)

    builder.setAttribute(buttonGroup, kAXRoleAttribute as String, kAXGroupRole as String)
    builder.setAttribute(buttonGroup, kAXDescriptionAttribute as String, "group")

    let buttons: [AXUIElement] = buttonTitles.enumerated().map { idx, title in
        let b = builder.element(7_010 + idx)
        builder.setAttribute(b, kAXRoleAttribute as String, kAXButtonRole as String)
        builder.setAttribute(b, kAXTitleAttribute as String, title)
        return b
    }
    builder.setChildren(buttonGroup, buttons)
    builder.setChildren(sheet, [buttonGroup])
    builder.setChildren(window, [sheet])

    return (builder, builder.makeLogicRuntime(appElement: app))
}

/// The regression itself. `track.delete` on a track that carries regions raises
/// "Delete Track and Regions?", whose primary button is labelled exactly
/// `Delete`. The reconciler's structural net was `hasPrefix("Delete ")`, and
/// `"Delete".hasPrefix("Delete ")` is FALSE — one trailing space from matching
/// — so the sheet classified as `.unknownSheet` and failed closed.
///
/// Failing closed here is not a mere refusal: the sheet stays on screen, and
/// every later operation in any surface returns State C until a human clears
/// it. Reported upstream as MongLong0214/logic-pro-mcp#545.
@Test func testDeleteTrackAndRegionsSheetIsRecognizedAsDeleteConfirm() {
    let fixture = makeDeleteSheetFixture(
        buttonTitles: ["Cancel", "Delete"],
        sheetDescription: "Delete Track and Regions?"
    )

    let signals = AccessibilityChannel.readModalSignals(runtime: fixture.runtime)

    #expect(signals.sheetPresent)
    #expect(signals.cancelButtonPresent)
    #expect(signals.deleteConfirmButtonPresent, "a bare 'Delete' primary must be recognized")
    // The executor clicks the label we captured, so it must be the real one.
    #expect(signals.deletePrimaryTitle == "Delete")
    #expect(ModalReconciliation.classify(signals) == .deleteConfirm)
}

/// Live Loops variant, same two-button Cancel/Delete shape. Measured upstream
/// on a Live Loops project; it must be covered by the same change rather than
/// waiting for its own follow-up.
@Test func testDeleteTrackAndCellsSheetIsRecognizedAsDeleteConfirm() {
    let fixture = makeDeleteSheetFixture(
        buttonTitles: ["Cancel", "Delete"],
        sheetDescription: "Delete Track and Cells?"
    )

    let signals = AccessibilityChannel.readModalSignals(runtime: fixture.runtime)
    #expect(signals.deleteConfirmButtonPresent)
    #expect(ModalReconciliation.classify(signals) == .deleteConfirm)
}

/// The channel-strip sheet that already worked must keep working — the fix
/// replaced a prefix guess with labelled matching, and dropping this label
/// while fixing the other would trade one gap for another.
@Test func testDeleteTracksAndContentSheetStaysRecognized() {
    let fixture = makeDeleteSheetFixture(
        buttonTitles: ["Cancel", "Delete Tracks and Content"],
        sheetDescription: "Delete channel strips?"
    )

    let signals = AccessibilityChannel.readModalSignals(runtime: fixture.runtime)
    #expect(signals.deleteConfirmButtonPresent)
    #expect(signals.deletePrimaryTitle == "Delete Tracks and Content")
    #expect(ModalReconciliation.classify(signals) == .deleteConfirm)
}

/// Recognition must not widen into "any sheet with a button". An unrelated
/// two-button sheet still fails closed — the guard the delete family sits
/// behind is the whole reason a wrong match is dangerous.
@Test func testUnrelatedTwoButtonSheetStillFailsClosed() {
    let fixture = makeDeleteSheetFixture(
        buttonTitles: ["Cancel", "Save"],
        sheetDescription: "Save changes before closing?"
    )

    let signals = AccessibilityChannel.readModalSignals(runtime: fixture.runtime)
    #expect(!signals.deleteConfirmButtonPresent)
    #expect(ModalReconciliation.classify(signals) == .unknownSheet)
    #expect(ModalReconciliation.decide(kind: .unknownSheet, isDeleteContext: true)
        == .failClosed("unexpected blocking sheet"))
}

@Test func testDeleteConfirmPrimaryButtonLabelSetEnglishOnly() {
    #expect(AXLocalePolicy.deleteConfirmPrimaryButton.matches("Delete"))
    // The exact string the old prefix net could never match.
    #expect(!"Delete".hasPrefix("Delete "))
    // KO/JA intentionally absent (unverified) — must not match a guess.
    #expect(!AXLocalePolicy.deleteConfirmPrimaryButton.matches("삭제"))
}
