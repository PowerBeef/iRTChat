import SwiftData
import SwiftUI

@main
struct iRTChatApp: App {
  @State private var appState: AppState
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

    let state = AppState(useMockEngine: useMock)
    state.modelContext = ModelContext(container)
    _appState = State(initialValue: state)
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(appState)
    }
    .modelContainer(container)
  }
}
