import SwiftUI

struct ContentView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    TabView {
      ThreadListView()
        .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
      ModelLibraryView()
        .tabItem { Label("Models", systemImage: "internaldrive") }
        .badge(downloadBadge)
      SettingsView()
        .tabItem { Label("Settings", systemImage: "gearshape") }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
  }

  private var downloadBadge: Int {
    appState.isMock || appState.store.activeSpecDownloaded ? 0 : 1
  }
}

extension ModelStore {
  var activeSpecDownloaded: Bool { isDownloaded(activeSpec) }
}
