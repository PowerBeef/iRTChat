import XCTest

@testable import iRTChat

/// Opt-in E4B scenarios (3.7 GB download, memory-limit probing). Enable with
/// the test-runner env var HARNESS_E4B=1 (MobileBuildMCP: testRunnerEnv
/// `HARNESS_E4B=1`; xcodebuild: `TEST_RUNNER_HARNESS_E4B=1`).
final class E4BScenarioTests: DeviceTestCase {

  override func setUp() async throws {
    try await super.setUp()
    guard ProcessInfo.processInfo.environment["HARNESS_E4B"] == "1" else {
      throw XCTSkip("Set HARNESS_E4B=1 to run E4B scenarios")
    }
  }

  override func tearDown() async throws {
    try await super.tearDown()
    await appState.switchModel(to: .e2b)
  }

  func test01_LoadAndReplyE4B() async throws {
    let downloadSeconds = try await harness.ensureDownloaded(ModelCatalog.e4b, timeout: 5400)
    let availableBefore = MemoryProbe.availableBytes()
    await appState.switchModel(to: .e4b)
    let loaded = appState.resolved != nil
    let loadLog = await harness.liveEngine?.loadLog ?? []
    var values = harness.resolvedSummary()
    values["downloadSeconds"] = downloadSeconds
    values["loaded"] = loaded
    values["engineState"] = "\(appState.engineState)"
    values["loadLog"] = loadLog
    values["availableBeforeGB"] = Double(availableBefore) / 1e9
    if loaded {
      let exchange = await harness.ask(
        "Explain photosynthesis in three sentences.", in: harness.newThread())
      values.merge(DeviceHarness.stats(exchange.reply?.stats)) { $1 }
      values["reply"] = exchange.text
      XCTAssertFalse(exchange.text.hasPrefix("Error:"), exchange.text)
    }
    harness.record("e4b_01_load", values, in: self)
    XCTAssertTrue(loaded, "E4B failed to load: \(appState.engineState)\n\(loadLog)")
  }
}
