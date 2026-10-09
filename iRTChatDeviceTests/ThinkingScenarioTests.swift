import XCTest

@testable import iRTChat

/// Long Thinking-mode scenarios (~2.5 min). Opt-in: HARNESS_THINKING=1.
final class ThinkingScenarioTests: DeviceTestCase {

  override func setUp() async throws {
    try await super.setUp()
    guard ProcessInfo.processInfo.environment["HARNESS_THINKING"] == "1" else {
      throw XCTSkip("Set HARNESS_THINKING=1 to run long Thinking scenarios")
    }
  }

  /// Gallery issue #703 reports E4B crashing or hanging with Thinking mode on
  /// (A19 Pro, 12 GB). Same scenario here, with growing thinking budgets.
  func test01_ThinkingBudgets() async throws {
    try await requireLoadedModel()
    let prompts = [
      ("math", "What is 17 * 23? Think it through.", 512),
      (
        "code_issue703",
        "Write PHP and Python code that sorts an array of integers in ascending order, and explain the difference between the two approaches.",
        1_024
      ),
      ("logic", "A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost? Reason carefully.", 2_048),
    ]
    var results: [[String: Any]] = []
    for (label, prompt, budget) in prompts {
      appState.options.enableThinking = true
      appState.options.thinkingBudget = budget
      await appState.applyCurrentOptions()
      let started = Date()
      let exchange = await harness.ask(prompt, in: harness.newThread())
      let entry: [String: Any] = [
        "case": label, "budget": budget,
        "thinkingEnabled": appState.resolved?.thinkingBudget != nil,
        "seconds": Date().timeIntervalSince(started),
        "thoughtLength": exchange.reply?.thought.count ?? 0,
        "replyLength": exchange.text.count,
        "replyPrefix": String(exchange.text.prefix(160)),
        "decodeTokPerSec": exchange.reply?.stats?.decodeTokensPerSecond ?? -1,
        "outputTokens": exchange.reply?.stats?.outputTokens ?? -1,
        "error": appState.generationError ?? "",
        "footprintGB": Double(MemoryProbe.footprintBytes()) / 1e9,
        "availableGB": Double(MemoryProbe.availableBytes()) / 1e9,
      ]
      results.append(entry)
      harness.record("e4b_02_thinking", ["results": results], in: self)
      XCTAssertTrue(exchange.accepted, "\(label): not accepted")
      XCTAssertFalse(exchange.text.isEmpty, "\(label): empty reply")
      XCTAssertFalse(exchange.text.hasPrefix(ChatTurn.errorPrefix), "\(label): \(exchange.text)")
      XCTAssertFalse(exchange.reply?.thought.isEmpty ?? true, "\(label): no reasoning streamed")
    }
    // Normal chat must still work after thinking runs.
    appState.options.enableThinking = false
    await appState.applyCurrentOptions()
    let after = await harness.ask("Say 'ready'.", in: harness.newThread())
    harness.record("e4b_02_thinking", ["results": results, "afterThinking": after.text], in: self)
    XCTAssertFalse(after.text.hasPrefix(ChatTurn.errorPrefix), after.text)
  }
}
