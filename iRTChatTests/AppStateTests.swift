import SwiftData
import XCTest

@testable import iRTChat

/// Engine-lifecycle and thread ↔ conversation regressions, driven through the
/// scripted mock engine with an in-memory store.
@MainActor
final class AppStateTests: XCTestCase {
  private static let defaultsKeys = ["activeModelID", "selectedThreadID", "inferenceOptions"]
  private var savedDefaults: [String: Any] = [:]
  private var container: ModelContainer!
  private var appState: AppState!
  private var mock: MockChatEngine { appState.engine as! MockChatEngine }
  private var context: ModelContext { container.mainContext }

  override func setUp() async throws {
    for key in Self.defaultsKeys {
      savedDefaults[key] = UserDefaults.standard.object(forKey: key)
    }
    container = try ModelContainer(
      for: ChatThread.self, ChatTurn.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    appState = AppState(useMockEngine: true)
    appState.store.activeModelID = .e2b
    appState.modelContext = container.mainContext
  }

  override func tearDown() async throws {
    appState = nil
    container = nil
    for key in Self.defaultsKeys {
      if let value = savedDefaults[key] {
        UserDefaults.standard.set(value, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
  }

  func testMockModeSendsWithoutDownloadedModel() async {
    let thread = appState.newThread(in: context)
    let accepted = await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertTrue(accepted)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Hi", "Hello from the mock engine!"])
    XCTAssertEqual(appState.engineState, .ready)
    XCTAssertFalse(appState.isGenerating)
  }

  func testConcurrentLoadsCoalesceIntoOne() async {
    await mock.setLoadDelay(.milliseconds(200))
    let state: AppState = appState
    async let first = state.ensureEngineLoaded()
    async let second = state.ensureEngineLoaded()
    let results = await [first, second]
    XCTAssertEqual(results, [true, true])
    let loads = await mock.loadCount
    XCTAssertEqual(loads, 1)
  }

  func testSwitchingThreadsReplaysTheOpenThreadsHistory() async {
    let a = appState.newThread(in: context)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: a)
    let b = appState.newThread(in: context)

    // Opening B must not continue A's native conversation.
    await appState.activate(b)
    var log = await mock.reseedLog
    XCTAssertEqual(log.last, [])

    // Re-opening A restores A's context.
    await appState.activate(a)
    log = await mock.reseedLog
    XCTAssertEqual(log.last, ["Hi", "Hello from the mock engine!"])
    XCTAssertEqual(appState.selectedThreadID, a.id)
  }

  func testReopeningSameThreadDoesNotReseed() async {
    let thread = appState.newThread(in: context)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    let before = await mock.reseedLog.count
    await appState.activate(thread)
    await appState.activate(thread)
    let after = await mock.reseedLog.count
    XCTAssertEqual(before, after)
  }

  func testSendRejectedForOtherModelsThreadPersistsNothing() async {
    let thread = ChatThread(modelID: .e4b)
    context.insert(thread)
    let accepted = await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertFalse(accepted)
    XCTAssertTrue(thread.turns.isEmpty)
    XCTAssertNotNil(appState.generationError)
  }

  // MARK: - Context window (audit #15)

  func testTrimmedContextSendsAndShowsNotice() async {
    await mock.setFitResult(.success(true))
    let thread = appState.newThread(in: context)
    let accepted = await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertTrue(accepted)
    XCTAssertEqual(thread.turns.count, 2)
    XCTAssertNotNil(appState.generationError, "User should learn older messages were dropped")
  }

  func testMessageTooLongIsRejectedWithoutPersisting() async {
    await mock.setFitResult(.failure(.messageTooLong))
    let thread = appState.newThread(in: context)
    let accepted = await appState.send(
      text: "Very long", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertFalse(accepted)
    XCTAssertTrue(thread.turns.isEmpty)
    XCTAssertEqual(appState.generationError, ChatError.messageTooLong.displayMessage)
  }

  func testFailedRepliesAreNotReplayedAsHistory() {
    let thread = ChatThread()
    context.insert(thread)
    thread.turns.append(ChatTurn(role: .user, text: "Hi"))
    thread.turns.append(ChatTurn(role: .model, text: ChatTurn.errorPrefix + "boom"))
    thread.turns.append(ChatTurn(role: .user, text: "Again"))
    XCTAssertEqual(thread.textHistory.map(\.text), ["Hi", "Again"])
  }

  func testOptionChangeDoesNotLoadAnUnloadedModel() async {
    appState.options.samplerPreset = .creative
    await appState.applyCurrentOptions()
    let loads = await mock.loadCount
    XCTAssertEqual(loads, 0)
  }
}
