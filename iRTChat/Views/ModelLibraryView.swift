import SwiftUI

struct ModelLibraryView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(spacing: DS.spaceLG) {
          ForEach(ModelCatalog.all) { spec in
            ModelCardView(spec: spec)
          }
          Text(
            "Models download from Hugging Face (litert-community) and stay on-device. Keep the app open while downloading."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        }
        .padding()
      }
      .navigationTitle("Models")
      .onAppear { appState.store.refreshStates() }
    }
  }
}

private struct ModelCardView: View {
  @Environment(AppState.self) private var appState
  let spec: ModelSpec

  private var state: ModelStore.DownloadState {
    appState.store.states[spec.id] ?? .notDownloaded
  }

  private var isActive: Bool { appState.store.activeModelID == spec.id }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.spaceMD) {
      HStack(spacing: 12) {
        Image(systemName: spec.requiresRoomyDevice ? "cpu.fill" : "bolt.fill")
          .font(.callout)
          .frame(width: DS.iconLG, height: DS.iconLG)
          .glassEffect(.regular.tint(.accentColor), in: .circle)
        VStack(alignment: .leading, spacing: 2) {
          Text(spec.displayName).font(.headline)
          Text(spec.tagline).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if isActive {
          Text("Active")
            .font(.caption2).bold()
            .accessibilityIdentifier("models.active.\(spec.id.rawValue)")
            .padding(.horizontal, 10)
            .padding(.vertical, DS.spaceXS)
            .glassEffect(.regular.tint(.accentColor), in: .capsule)
        }
      }
      Text(spec.sizeDisplay).font(.caption).foregroundStyle(.secondary)

      if spec.requiresRoomyDevice, !DeviceProfile.current.supportsE4B {
        Label(
          "Not advised on this device (\(DeviceProfile.current.summary)).",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }

      controls
    }
    .padding()
    .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusCard))
  }

  @ViewBuilder
  private var controls: some View {
    switch state {
    case .notDownloaded:
      Button("Download") { appState.store.startDownload(spec) }
        .buttonStyle(.glassProminent)
        .controlSize(.regular)
        .accessibilityIdentifier("models.download.\(spec.id.rawValue)")
    case .downloading(let progress):
      VStack(alignment: .leading, spacing: 8) {
        ProgressView(value: progress) {
          Text("Downloading… \(Int(progress * 100))%")
            .font(.caption)
        }
        HStack {
          Button("Pause") { appState.store.pauseDownload(spec) }
          Button("Cancel", role: .cancel) { appState.store.cancelDownload(spec) }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
      }
    case .paused(let progress):
      HStack {
        Button("Resume") { appState.store.startDownload(spec) }
          .buttonStyle(.glassProminent)
          .controlSize(.small)
        Button("Cancel", role: .cancel) { appState.store.cancelDownload(spec) }
          .buttonStyle(.glass)
          .controlSize(.small)
        Spacer()
        Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
      }
    case .verifying:
      HStack {
        ProgressView().controlSize(.small)
        Text("Verifying…").font(.caption)
      }
    case .ready:
      HStack {
        if !isActive {
          Button("Use this model") {
            Task { await appState.switchModel(to: spec.id) }
          }
          .buttonStyle(.glassProminent)
          .controlSize(.small)
          .accessibilityIdentifier("models.use.\(spec.id.rawValue)")
        }
        Spacer()
        Button("Delete", role: .destructive) { Task { await appState.deleteModel(spec) } }
          .buttonStyle(.glass)
          .controlSize(.small)
      }
    case .failed(let message):
      VStack(alignment: .leading, spacing: 8) {
        Text(message).font(.caption).foregroundStyle(.red)
        Button("Retry") { appState.store.startDownload(spec) }
          .buttonStyle(.glass)
          .controlSize(.small)
      }
    }
  }
}
