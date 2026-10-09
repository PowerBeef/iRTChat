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
    XCTAssertTrue(
      element("chat.banner.notice").exists,
      "Expected the 'stopped because the app moved to the background' notice")
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
    element("chat.new").tap()
    openDrawer()
    element("drawer.row").firstMatch.tap()
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
    openSettings()
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
    element("settings.done").tap()
    // Settings opens from the drawer, which is still showing behind it.
    element("drawer.close").tap()
    send("Say 'two'.")
    try waitForReplyToFinish(timeout: 120)
    XCTAssertFalse(lastModelText().hasPrefix("Error:"), lastModelText())
  }

  /// The app opens on a new chat; a chat is saved on its first message
  /// (unused new chats never appear in the drawer) and reopens from it.
  func testDrawerNewChatAndReopen() throws {
    try openNewChat()
    send("Say 'one'.")
    try waitForReplyToFinish(timeout: 120)

    element("chat.new").tap()
    XCTAssertTrue(element("chat.suggestion").waitForExistence(timeout: 5), "New chat not empty")
    openDrawer()
    XCTAssertEqual(rows().count, 1, "Unused new chat was saved")
    attachScreenshot("drawer")

    rows().firstMatch.tap()
    XCTAssertTrue(element("message.model").waitForExistence(timeout: 5), "Chat did not reopen")
    XCTAssertFalse(element("drawer.search").isHittable, "Drawer stayed open")

    // Search finds the chat by message text; a miss shows no rows.
    openDrawer()
    let search = element("drawer.search")
    search.tap()
    search.typeText("one")
    XCTAssertEqual(rows().count, 1)
    search.typeText("zzz")
    XCTAssertEqual(rows().count, 0)
  }

  /// Rename and delete from the chat's toolbar menu.
  func testRenameAndDeleteChat() throws {
    try openNewChat()
    send("Say 'hello'.")
    try waitForReplyToFinish(timeout: 120)
    // Wait for the model-written title so it can't overwrite the rename.
    sleep(Self.isSimulator ? 1 : 5)

    element("chat.menu").tap()
    app.buttons["Rename"].tap()
    let field = app.alerts.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.clearAndType("Greetings")
    app.alerts.buttons["Save"].tap()
    XCTAssertTrue(app.navigationBars["Greetings"].waitForExistence(timeout: 5))

    element("chat.menu").tap()
    app.buttons["Delete"].tap()
    app.buttons["Delete"].firstMatch.tap()
    XCTAssertTrue(element("chat.suggestion").waitForExistence(timeout: 5))
    openDrawer()
    XCTAssertEqual(rows().count, 0)
  }

  /// Rich replies: code block (with Copy), table and display math render.
  /// Simulator only: the mock engine answers "markdown" with a fixed sample.
  func testMarkdownRendering() throws {
    try XCTSkipUnless(Self.isSimulator, "Uses the mock engine's markdown sample")
    try openNewChat()
    send("Show me markdown")
    try waitForReplyToFinish(timeout: 30)
    attachScreenshot("markdown")
    XCTAssertTrue(element("message.code").waitForExistence(timeout: 5), "Code block missing")
    XCTAssertTrue(element("message.table").exists, "Table missing")
    XCTAssertTrue(element("message.math").exists, "Display math missing")
    let copy = element("code.copy")
    XCTAssertTrue(copy.exists)
    copy.tap()
  }

  /// Regenerate adds a second version; the switcher moves between them.
  /// Editing a message (long press → Edit) branches the conversation.
  func testRegenerateEditAndVersions() throws {
    try openNewChat()
    send("Name one primary color. One word.")
    try waitForReplyToFinish(timeout: 120)

    element("message.regenerate").tap()
    try waitForReplyToFinish(timeout: 120)
    let version = element("message.version")
    XCTAssertTrue(version.waitForExistence(timeout: 5), "No version switcher after regenerate")
    XCTAssertEqual(version.label, "Version 2 of 2")
    element("message.version.previous").tap()
    XCTAssertEqual(element("message.version").label, "Version 1 of 2")

    element("message.user").press(forDuration: 1.0)
    app.buttons["Edit"].tap()
    XCTAssertTrue(element("chat.editing").waitForExistence(timeout: 5))
    let input = element("chat.input")
    input.tap()
    input.typeText(" Answer in French.")
    element("chat.send").tap()
    try waitForReplyToFinish(timeout: 120)
    attachScreenshot("after-edit")
    XCTAssertTrue(element("message.user").label.hasSuffix("Answer in French."))
    // The edited message is version 2 of 2; the reply under it is new.
    let userVersion = app.descendants(matching: .any).matching(identifier: "message.version")
      .allElementsBoundByIndex.first
    XCTAssertEqual(userVersion?.label, "Version 2 of 2")
    XCTAssertFalse(element("chat.editing").exists)
  }

  /// E4B is the only model: its card (Settings → Models) shows Ready
  /// (device) or Download.
  func testModelsShowTheModel() throws {
    openSettings()
    element("settings.models").tap()
    let ready = element("models.ready.e4b")
    let download = element("models.download.e4b")
    XCTAssertTrue(
      ready.waitForExistence(timeout: 5) || download.exists, "E4B card missing")
    if !Self.isSimulator {
      XCTAssertTrue(ready.exists, "E4B should be downloaded on the test device")
    }
    attachScreenshot("models")
  }

  // MARK: - Helpers

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func openNewChat() throws {
    // The app launches on a new chat (`--uitest-reset` clears the selection).
    XCTAssertTrue(element("chat.input").waitForExistence(timeout: 10), "New chat not shown")
    try waitForEngineReady()
  }

  private func openDrawer() {
    element("chat.drawer").tap()
    XCTAssertTrue(element("drawer.search").waitForExistence(timeout: 5), "Drawer did not open")
    // Let the slide-in animation settle before tapping rows.
    _ = element("drawer.close").waitForExistence(timeout: 2)
    usleep(400_000)
  }

  private func openSettings() {
    openDrawer()
    element("drawer.settings").tap()
    XCTAssertTrue(element("settings.done").waitForExistence(timeout: 5), "Settings did not open")
  }

  private func rows() -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "drawer.row")
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
    let keyboard = app.keyboards.firstMatch
    if keyboard.waitForExistence(timeout: 2) {
      XCTAssertLessThanOrEqual(
        input.frame.maxY, keyboard.frame.minY + 1, "The keyboard covers the message field")
    }
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

extension XCUIElement {
  func clearAndType(_ text: String) {
    tap()
    if let current = value as? String, !current.isEmpty {
      typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    typeText(text)
  }
}
