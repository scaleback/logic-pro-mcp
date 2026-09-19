@preconcurrency import ApplicationServices
import Foundation
import Testing
@testable import LogicProMCP

/// On-demand state polling (default since 2026-09-19, see
/// `ServerConfig.StatePollMode`): Logic aborted mid-recording with the helper as
/// the voucher of the event being handled and no command in flight, so Batuta
/// no longer polls in the background. The cache is refreshed once right before
/// a call — and a burst of calls must not multiply the reads.

private func countingRuntime(_ reads: MutableBox<Int>) -> AccessibilityChannel.Runtime {
    .init(
        isTrusted: { true },
        isLogicProRunning: { true },
        appRoot: { nil },
        transportState: { .success("{}") },
        toggleTransportButton: { _ in .success("{}") },
        setTempo: { _ in .success("{}") },
        setCycleRange: { _ in .success("{}") },
        tracks: { .success("[]") },
        selectedTrack: { .success("{}") },
        selectTrack: { _ in .success("{}") },
        setTrackToggle: { _, _ in .success("{}") },
        renameTrack: { _ in .success("{}") },
        mixerState: { .success("[]") },
        channelStrip: { _ in .success("{}") },
        setMixerValue: { _, _ in .success("{}") },
        projectInfo: { reads.value += 1; return .success("{}") },   // first read of every cycle
        markers: { .success("[]") }
    )
}

private func makePoller(_ reads: MutableBox<Int>) -> StatePoller {
    StatePoller(
        axChannel: AccessibilityChannel(runtime: countingRuntime(reads)),
        cache: StateCache(),
        runtime: .init(hasVisibleWindow: { true }, dialogPresent: { false })
    )
}

@Test func testOnDemandIsTheDefaultStatePollMode() {
    guard ProcessInfo.processInfo.environment["LOGIC_MCP_STATE_POLL"] == nil else { return }
    #expect(ServerConfig.statePollMode == .onDemand)
}

@Test func testBurstOfCallsReusesOneRefresh() async {
    let reads = MutableBox(0)
    let poller = makePoller(reads)
    await poller.refreshIfStale()
    await poller.refreshIfStale()
    await poller.refreshIfStale()
    #expect(reads.value == 1)
    #expect(!(await poller.isRunning))              // no background loop was started
}

@Test func testRefreshRunsAgainOnceTheReuseWindowHasPassed() async {
    let reads = MutableBox(0)
    let poller = makePoller(reads)
    await poller.refreshIfStale(reuseNs: 0)
    await poller.refreshIfStale(reuseNs: 0)
    #expect(reads.value == 2)
}

@Test func testNothingIsReadUntilSomethingAsks() async throws {
    let reads = MutableBox(0)
    _ = makePoller(reads)
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(reads.value == 0)
}
