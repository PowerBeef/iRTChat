import XCTest

@testable import iRTChat

/// Tool budgets (KV-cache safety) and helper-task parsing.
final class ToolHostTests: XCTestCase {
  override func tearDown() {
    ToolBudget.end()
    super.tearDown()
  }

  func testCallLimitIsEnforcedPerReply() {
    ToolBudget.begin(.init(maxResultBytes: 100, maxCalls: 2))
    XCTAssertNotNil(ToolBudget.claim())
    XCTAssertNotNil(ToolBudget.claim())
    XCTAssertNil(ToolBudget.claim(), "Third call must be refused")
    ToolBudget.begin(.init(maxResultBytes: 100, maxCalls: 2))
    XCTAssertNotNil(ToolBudget.claim(), "A new reply starts a fresh budget")
  }

  func testNoToolsWhenToolsAreOff() {
    ToolBudget.begin(.init(maxResultBytes: 100, maxCalls: 0))
    XCTAssertNil(ToolBudget.claim())
  }

  func testResultsAreTrimmedToBudgetAndAccounted() {
    let limits = ToolBudget.Limits(maxResultBytes: 10, maxCalls: 1)
    ToolBudget.begin(limits)
    let fitted = ToolBudget.fit("héllo wörld, this is long", limits)
    XCTAssertLessThanOrEqual(fitted.utf8.count, 10)
    XCTAssertTrue(fitted.hasSuffix("…"))
    XCTAssertEqual(ToolBudget.resultBytes, fitted.utf8.count)
    XCTAssertEqual(ToolBudget.fit("ok", limits), "ok")
  }

  func testCalculatorRefusesBeyondTheLimitAndRecordsActivity() async throws {
    ToolBudget.begin(.init(maxResultBytes: 100, maxCalls: 1))
    let cursor = ToolActivity.cursor
    var tool = CalculatorTool()
    tool.expression = "6*7"
    let first = try await tool.run() as? [String: Any]
    XCTAssertEqual(first?["result"] as? Double, 42)
    let second = try await tool.run() as? [String: Any]
    XCTAssertNotNil(second?["error"])
    XCTAssertEqual(ToolActivity.records(since: cursor).map(\.summary), ["Calculated 6*7"])
  }

  func testTitleParsing() {
    XCTAssertEqual(HelperTasks.parseTitle(Data(#"{"title":"Lighthouse Keepers"}"#.utf8)), "Lighthouse Keepers")
    XCTAssertEqual(HelperTasks.cleanTitle(#"  "Trip to Kyoto."  "#), "Trip to Kyoto")
    XCTAssertEqual(HelperTasks.cleanTitle("Title: Bread\n baking"), "Title: Bread baking")
    XCTAssertNil(HelperTasks.cleanTitle(" ** "))
    XCTAssertNil(HelperTasks.parseTitle(Data("not json".utf8)))
    let long = HelperTasks.cleanTitle(String(repeating: "word ", count: 30))
    XCTAssertLessThanOrEqual(long?.count ?? 0, HelperTasks.maxTitleLength)
    XCTAssertFalse(long?.hasSuffix(" ") ?? true)
  }

  func testTitlePromptIsBounded() {
    let prompt = HelperTasks.titlePrompt(
      user: String(repeating: "a", count: 5_000), reply: String(repeating: "b", count: 5_000))
    XCTAssertLessThan(prompt.utf8.count, 1_600)
  }
}
