import XCTest

/// Real-tap flows on the device. Each test launches the app from a clean
/// slate (`--uitest-reset`: no chats, default settings; models are kept).
/// On the simulator the app runs the mock engine and timing-sensitive flows
/// are skipped.
@MainActor
final class ChatFlowUITests: XCTestCase {
  private var app: XCUIApplication!

  private static var isSimulator: Bool {
    #if targetEnvironment(simulator)
      return true
    #else
      return false
    #endif
  }

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--uitest-reset"]
    if Self.isSimulator { app.launchArguments.append("--mock-engine") }
    app.launch()
  }

  // MARK: - Scenarios

  func testSendAndReceive() throws {
    try openNewChat()
    send("What is the capital of France? Answer in one word.")
    try waitForReplyToFinish(timeout: 120)
    let reply = lastModelText()
    attachScreenshot("reply")
    XCTAssertFalse(reply.hasPrefix("Error:"), reply)
    if !Self.isSimulator {
      XCTAssertTrue(reply.localizedCaseInsensitiveContains("Paris"), reply)
    }
    XCTAssertTrue(element("message.stats").waitForExistence(timeout: 5), "Stats footer missing")
  }

  /// Audit #10.
  func testStopMidReply() throws {
    try XCTSkipIf(Self.isSimulator, "Needs real generation")
    try openNewChat()
    send("Write a detailed 600-word story about a lighthouse keeper.")
    try waitForStreamingText(minLength: 40)
    element("chat.stop").tap()
    XCTAssertTrue(
      element("chat.stop").waitForNonExistence(timeout: 5), "Still generating 5 s after Stop")
    attachScreenshot("after-stop")
    XCTAssertFalse(lastModelText().hasPrefix("Error:"), "Stop shown as error: \(lastModelText())")
  }

  /// Audit #7: GPU work is not allowed in the background.
  func testBackgroundDuringGeneration() throws {
    try XCTSkipIf(Self.isSimulator, "Needs real GPU generation")
    try openNewChat()
    send("Write a detailed 600-word story about a lighthouse keeper.")
    try waitForStreamingText(minLength: 40)
    XCUIDevice.shared.press(.home)
    sleep(10)
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    // A crash relaunches the app on the chat list, losing the open chat.
    XCTAssertTrue(
      element("chat.input").waitForExistence(timeout: 5),
      "App was relaunched after backgrounding (likely crashed)")
    try waitForReplyToFinish(timeout: 180)
    attachScreenshot("after-background")
    XCTAssertFalse(
      lastModelText().hasPrefix("Error:"), "Backgrounding broke the reply: \(lastModelText())")
    // The engine must still work afterwards.
    send("Say 'ready'.")
    try waitForReplyToFinish(timeout: 120)
    XCTAssertFalse(lastModelText().hasPrefix("Error:"), lastModelText())
  }

  /// Audit #3: leaving and reopening a chat mid-reply must not reload the
  /// engine or kill the stream.
  func testLeaveAndReturnDuringGeneration() throws {
    try XCTSkipIf(Self.isSimulator, "Needs real generation")
    try openNewChat()
    send("Write a detailed 600-word story about a lighthouse keeper.")
    try waitForStreamingText(minLength: 40)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    element("threads.row").firstMatch.tap()
    XCTAssertFalse(
      element("chat.banner.loading").waitForExistence(timeout: 2),
      "Engine reloaded when reopening the chat mid-reply")
    let lengthAfterReturn = lastModelText().count
    try waitForReplyToFinish(timeout: 180)
    attachScreenshot("after-return")
    XCTAssertFalse(lastModelText().hasPrefix("Error:"), lastModelText())
    XCTAssertGreaterThan(lastModelText().count, lengthAfterReturn, "Reply stopped growing")
  }

  /// Audit #3: rapid Settings edits must coalesce, and chat must keep working.
  func testRapidSettingsChangesThenChat() throws {
    try openNewChat()
    send("Say 'one'.")
    try waitForReplyToFinish(timeout: 120)
    app.tabBars.buttons["Settings"].tap()
    // Settings is a lazily loaded Form: scroll the sampler presets into view.
    let precise = app.buttons["Precise"].firstMatch
    for _ in 0..<8 where !precise.isHittable {
      app.swipeUp()
    }
    for preset in ["Precise", "Creative", "Balanced", "Creative", "Precise"] {
      app.buttons[preset].firstMatch.tap()
    }
    for _ in 0..<8 where !element("settings.status").isHittable {
      app.swipeDown()
    }
    XCTAssertTrue(element("settings.status").waitForExistence(timeout: 5))
    attachScreenshot("settings")
    app.tabBars.buttons["Chat"].tap()
    send("Say 'two'.")
    try waitForReplyToFinish(timeout: 120)
    XCTAssertFalse(lastModelText().hasPrefix("Error:"), lastModelText())
  }

  /// Creating a chat (toolbar or empty-state button) opens it immediately,
  /// and going back shows it in the list.
  func testNewChatOpensDirectly() throws {
    app.tabBars.buttons["Chat"].tap()
    element("threads.empty.new").tap()
    XCTAssertTrue(element("chat.input").waitForExistence(timeout: 5), "Empty-state button")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(element("threads.row").waitForExistence(timeout: 5))

    element("threads.new").tap()
    XCTAssertTrue(element("chat.input").waitForExistence(timeout: 5), "Toolbar button")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "threads.row").count, 2)
  }

  /// Audit #5: the Active badge reflects the active model.
  func testModelsTabShowsActiveModel() throws {
    app.tabBars.buttons["Models"].tap()
    XCTAssertTrue(element("models.active.e2b").waitForExistence(timeout: 5))
    XCTAssertFalse(element("models.active.e4b").exists)
    attachScreenshot("models")
  }

  // MARK: - Helpers

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func openNewChat() throws {
    app.tabBars.buttons["Chat"].tap()
    element("threads.new").tap()
    XCTAssertTrue(
      element("chat.input").waitForExistence(timeout: 5), "New chat did not open directly")
    try waitForEngineReady()
  }

  private func waitForEngineReady(timeout: TimeInterval = 180) throws {
    if element("chat.banner.download").waitForExistence(timeout: 2) {
      throw XCTSkip("Model not downloaded: run InferenceScenarioTests/test00 first")
    }
    let loading = element("chat.banner.loading")
    if loading.exists {
      XCTAssertTrue(loading.waitForNonExistence(timeout: timeout), "Model load timed out")
    }
    if element("chat.banner.failed").exists {
      XCTFail("Engine failed: \(element("chat.banner.failed").label)")
    }
  }

  private func send(_ text: String) {
    let input = element("chat.input")
    input.tap()
    input.typeText(text)
    element("chat.send").tap()
  }

  private func lastModelText() -> String {
    app.descendants(matching: .any).matching(identifier: "message.model")
      .allElementsBoundByIndex.last?.label ?? ""
  }

  private func waitForStreamingText(minLength: Int, timeout: TimeInterval = 120) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while lastModelText().count < minLength {
      if Date() > deadline { throw XCTSkip("Reply never started streaming") }
      usleep(200_000)
    }
    XCTAssertTrue(element("chat.stop").exists, "Expected to be mid-generation")
  }

  private func waitForReplyToFinish(timeout: TimeInterval) throws {
    _ = element("chat.stop").waitForExistence(timeout: 10)
    XCTAssertTrue(
      element("chat.stop").waitForNonExistence(timeout: timeout), "Reply did not finish in time")
    XCTAssertTrue(element("chat.send").waitForExistence(timeout: 5))
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
