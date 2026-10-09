import SwiftData
import SwiftUI

@main
struct iRTChatApp: App {
  @State private var appState: AppState
  @Environment(\.scenePhase) private var scenePhase
  let container: ModelContainer

  init() {
    // `--mock-engine` launch arg (or IRT_MOCK_ENGINE=1 env) runs the scripted
    // engine: full UI without a 2 GB model. Used for simulator smoke tests.
    let args = ProcessInfo.processInfo.arguments
    let env = ProcessInfo.processInfo.environment
    let useMock = args.contains("--mock-engine") || env["IRT_MOCK_ENGINE"] != nil

    let schema = Schema([ChatThread.self, ChatTurn.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    do {
      container = try ModelContainer(for: schema, configurations: [configuration])
    } catch {
      fatalError("Could not create ModelContainer: \(error)")
    }

    // `--uitest-reset`: start UI tests from a clean slate (no chats, default
    // settings). Downloaded models are kept.
    if args.contains("--uitest-reset") {
      try? container.mainContext.delete(model: ChatTurn.self)
      try? container.mainContext.delete(model: ChatThread.self)
      try? container.mainContext.save()
      for key in ["inferenceOptions", "enableTools", "selectedThreadID", "activeModelID"] {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }

    let state = AppState(useMockEngine: useMock)
    // Must be the same context the views use (`.modelContainer` injects
    // mainContext): turns are appended to view-owned threads, then saved here.
    state.modelContext = container.mainContext
    _appState = State(initialValue: state)
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(appState)
    }
    .modelContainer(container)
    .onChange(of: scenePhase) { _, phase in
      Log.lifecycle.info(
        "scenePhase=\(String(describing: phase), privacy: .public) generating=\(appState.isGenerating)"
      )
    }
  }
}
