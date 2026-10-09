import SwiftUI

/// First launch: what iRTChat is, and the one-time model download (which
/// continues in the background). "Not now" leaves it for the chat banner.
struct OnboardingView: View {
  @Environment(AppState.self) private var appState
  var onFinish: () -> Void

  private var spec: ModelSpec { appState.store.activeSpec }
  private var state: ModelStore.DownloadState {
    appState.store.states[spec.id] ?? .notDownloaded
  }

  /// Shown until the user finishes or skips it, and only when there's
  /// something to download (existing installs skip it).
  nonisolated static func shouldShow(done: Bool, isMock: Bool, downloaded: Bool) -> Bool {
    !done && !isMock && !downloaded
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          header
          features
        }
        .padding(.horizontal, 28)
        .padding(.top, 48)
        .padding(.bottom, 24)
      }
      footer
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }
    .background(
      LinearGradient(
        colors: [.accentColor.opacity(0.12), .clear], startPoint: .top, endPoint: .center
      )
      .ignoresSafeArea()
    )
    .onAppear { appState.store.refreshStates() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: "sparkles")
        .font(.title)
        .frame(width: 64, height: 64)
        .glassEffect(.regular.tint(.accentColor), in: .circle)
      Text("Welcome to iRTChat")
        .font(.largeTitle.bold())
      Text("A capable AI assistant that runs entirely on your iPhone.")
        .font(.title3)
        .foregroundStyle(.secondary)
    }
  }

  private var features: some View {
    VStack(alignment: .leading, spacing: 20) {
      feature(
        "lock.shield", "Private by design",
        "Your chats, photos and voice never leave this iPhone.")
      feature(
        "airplane", "Works offline",
        "Once downloaded, the model needs no connection or account.")
      feature(
        "photo.on.rectangle.angled", "Sees and listens",
        "Ask about photos, or send a voice message.")
      feature(
        "lightbulb", "Thinks it through",
        "Turn on Think for step-by-step reasoning on harder questions.")
    }
  }

  private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey)
    -> some View
  {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: symbol)
        .font(.title3)
        .foregroundStyle(Color.accentColor)
        .frame(width: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var footer: some View {
    VStack(spacing: 12) {
      switch state {
      case .notDownloaded:
        note("\(spec.displayName) · \(spec.sizeDisplay) one-time download. Wi-Fi recommended.")
        primary("Download \(spec.displayName)", id: "onboarding.download") {
          appState.store.startDownload(spec)
        }
      case .downloading(let progress):
        ProgressView(value: progress) {
          HStack {
            Text("Downloading \(spec.displayName)…")
            Spacer()
            Text("\(Int(progress * 100))%").monospacedDigit()
          }
          .font(.subheadline)
        }
        .accessibilityIdentifier("onboarding.progress")
        note("You can leave the app: the download continues in the background.")
        Button("Pause") { appState.store.pauseDownload(spec) }
          .buttonStyle(.glass)
      case .paused(let progress):
        note("Paused at \(Int(progress * 100))%.")
        primary("Resume download", id: "onboarding.download") {
          appState.store.startDownload(spec)
        }
      case .failed(let message):
        note(message)
          .foregroundStyle(.red)
        primary("Try again", id: "onboarding.download") { appState.store.startDownload(spec) }
      case .ready:
        note("\(spec.displayName) is ready.")
        primary("Start chatting", id: "onboarding.start", action: onFinish)
      }
      if state != .ready {
        Button("Not now", action: onFinish)
          .font(.subheadline)
          .accessibilityIdentifier("onboarding.skip")
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
  }

  private func primary(_ title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
    .buttonStyle(.glassProminent)
    .controlSize(.large)
    .accessibilityIdentifier(id)
  }
}
