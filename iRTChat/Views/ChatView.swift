import PhotosUI
import SwiftUI

struct ChatView: View {
  @Environment(AppState.self) private var appState
  let thread: ChatThread

  @State private var draft = ""
  @State private var pendingImage: Data?
  @State private var photoItem: PhotosPickerItem?
  @State private var recorder = AudioRecorder()
  @State private var showLibrary = false
  @FocusState private var inputFocused: Bool
  @Namespace private var inputNamespace

  var body: some View {
    // Sorted once per render (not per use: this re-renders while streaming).
    let turns = thread.orderedTurns
    VStack(spacing: 0) {
      mismatchBanner
      engineBanner
      noticeBanner
      messagesList(turns)
      pendingBar
      inputBar
    }
    .background(ambientBackground)
    .navigationTitle(thread.title)
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(isPresented: $showLibrary) { ModelLibraryView() }
    .alert(
      "Microphone access denied",
      isPresented: $recorder.permissionDenied
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Enable microphone access in Settings to send voice messages.")
    }
    .onChange(of: recorder.errorMessage) { _, message in
      if let message { appState.generationError = "Recording failed: \(message)" }
    }
    .task(id: thread.id) {
      await appState.activate(thread)
    }
  }

  private var ambientBackground: some View {
    LinearGradient(
      colors: [.accentColor.opacity(0.07), .clear],
      startPoint: .top, endPoint: .center
    )
    .ignoresSafeArea()
  }

  // MARK: - Banners

  @ViewBuilder
  private var mismatchBanner: some View {
    if thread.modelID != appState.store.activeModelID {
      HStack {
        Text("This chat uses \(ModelCatalog.spec(for: thread.modelID).displayName).")
          .font(.caption)
        Spacer()
        Button("Switch") {
          Task {
            await appState.switchModel(to: thread.modelID)
            await appState.activate(thread)
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .padding(DS.padMD)
      .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusBanner))
      .padding(.horizontal)
      .padding(.top, 6)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("chat.banner.mismatch")
    }
  }

  @ViewBuilder
  private var engineBanner: some View {
    switch appState.engineState {
    case .idle:
      if !appState.isMock, !appState.store.isDownloaded(appState.store.activeSpec) {
        HStack {
          Text("Download \(appState.store.activeSpec.displayName) to start chatting.")
            .font(.caption)
            .accessibilityIdentifier("chat.banner.download")
          Spacer()
          Button("Models") { showLibrary = true }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(DS.padMD)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusBanner))
        .padding(.horizontal)
        .padding(.top, 6)
      }
    case .loading(let progress):
      HStack {
        ProgressView().controlSize(.small)
        Text(progress).font(.caption).accessibilityIdentifier("chat.banner.loading")
        Spacer()
      }
      .padding(DS.padMD)
      .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusBanner))
      .padding(.horizontal)
      .padding(.top, 6)
    case .failed(let message):
      HStack {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.red)
        Text(message).font(.caption).accessibilityIdentifier("chat.banner.failed")
        Spacer()
        Button("Retry") { Task { await appState.ensureEngineLoaded() } }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
      .padding(DS.padMD)
      .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusBanner))
      .padding(.horizontal)
      .padding(.top, 6)
    case .ready, .generating:
      EmptyView()
    }
  }

  @ViewBuilder
  private var noticeBanner: some View {
    if let error = appState.generationError {
      HStack {
        Image(systemName: "info.circle")
        Text(error).font(.caption).accessibilityIdentifier("chat.banner.notice")
        Spacer()
        Button("Dismiss") { appState.generationError = nil }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
      .padding(DS.padMD)
      .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusBanner))
      .padding(.horizontal)
      .padding(.top, 6)
    }
  }

  // MARK: - Messages

  private func messagesList(_ turns: [ChatTurn]) -> some View {
    Group {
      if turns.isEmpty {
        emptyState
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: DS.spaceLG) {
              ForEach(turns) { turn in
                MessageBubbleView(turn: turn, isStreaming: isLiveBubble(turn, in: turns))
                  .id(turn.id)
              }
              Color.clear.frame(height: 1).id("bottom")
            }
            .padding()
          }
          .onChange(of: scrollSignature(turns)) {
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
          }
        }
      }
    }
  }

  private var suggestions: [String] {
    [
      "Explain black holes like I'm five",
      "Write a haiku about the sea",
      "Give me three dinner ideas",
    ]
  }

  private var emptyState: some View {
    VStack(spacing: DS.spaceLG) {
      Spacer()
      Image(systemName: "sparkles")
        .font(.title2)
        .frame(width: DS.heroMark, height: DS.heroMark)
        .glassEffect(.regular.tint(.accentColor), in: .circle)
      Text("Chat with \(ModelCatalog.spec(for: thread.modelID).displayName)")
        .font(.title3)
        .bold()
        .multilineTextAlignment(.center)
      Text("Private and on-device. Pick a starter or write your own.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      GlassEffectContainer(spacing: 8) {
        VStack(spacing: 8) {
          ForEach(suggestions, id: \.self) { suggestion in
            Button(action: { sendSuggestion(suggestion) }) {
              HStack {
                Text(suggestion)
                  .font(.callout)
                  .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .padding(.horizontal, 16)
              .padding(.vertical, DS.padMD)
              .glassEffect(.regular.interactive(), in: .capsule)
            }
            .accessibilityIdentifier("chat.suggestion")
          }
        }
      }
      .padding(.top, 6)
      Spacer()
    }
    .padding(.horizontal, 24)
  }

  private func sendSuggestion(_ text: String) {
    draft = text
    send()
  }

  private func scrollSignature(_ turns: [ChatTurn]) -> String {
    let last = turns.last
    return "\(turns.count)-\(last?.text.count ?? 0)-\(last?.thought.count ?? 0)"
  }

  private func isLiveBubble(_ turn: ChatTurn, in turns: [ChatTurn]) -> Bool {
    appState.generatingThreadID == thread.id && turn.id == turns.last?.id && !turn.isUser
  }

  // MARK: - Pending attachments

  @ViewBuilder
  private var pendingBar: some View {
    if pendingImage != nil || recorder.finishedURL != nil || recorder.isRecording {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          if let data = pendingImage, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
              .resizable()
              .scaledToFill()
              .frame(width: DS.controlTarget, height: DS.controlTarget)
              .clipShape(.rect(cornerRadius: DS.radiusThumb))
              .onTapGesture { pendingImage = nil }
          }
          if recorder.isRecording {
            Label(
              String(format: "%.0fs / %.0fs", recorder.elapsed, AudioRecorder.maxDuration),
              systemImage: "record.circle"
            )
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.red), in: .capsule)
          } else if recorder.finishedURL != nil {
            Label("Voice ready (\(Int(recorder.elapsed))s)", systemImage: "waveform")
              .font(.caption)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .glassEffect(.regular, in: .capsule)
              .onTapGesture { recorder.discard() }
          }
          Spacer()
          if pendingImage != nil || recorder.finishedURL != nil {
            Button("Clear") {
              pendingImage = nil
              recorder.discard()
            }
            .font(.caption)
            .buttonStyle(.glass)
            .controlSize(.small)
          }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
      }
    }
  }

  // MARK: - Input

  private var inputBar: some View {
    GlassEffectContainer(spacing: DS.spaceMD) {
      HStack(alignment: .bottom, spacing: DS.spaceMD) {
        inputButtons
        TextField("Message", text: $draft, axis: .vertical)
          .lineLimit(1...6)
          .textFieldStyle(.plain)
          .padding(.horizontal, 14)
          .padding(.vertical, DS.padMD)
          .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusCard))
          .focused($inputFocused)
          .accessibilityIdentifier("chat.input")
          .disabled(appState.isGenerating)
        actionButton
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
  }

  private var inputButtons: some View {
    HStack(spacing: DS.spaceMD) {
      PhotosPicker(selection: $photoItem, matching: .images) {
        Image(systemName: "photo")
          .frame(width: DS.controlTarget, height: DS.controlTarget)
          .glassEffect(.regular.interactive(), in: .circle)
      }
      .disabled(appState.isGenerating)
      .onChange(of: photoItem) { _, item in
        Task {
          if let item, let data = try? await item.loadTransferable(type: Data.self) {
            pendingImage = ImagePreparer.prepare(data) ?? data
          }
          photoItem = nil
        }
      }

      Button(action: { Task { await recorder.toggle() } }) {
        Image(systemName: recorder.isRecording ? "stop.fill" : "mic")
          .frame(width: DS.controlTarget, height: DS.controlTarget)
          .glassEffect(
            recorder.isRecording ? .regular.tint(.red).interactive() : .regular.interactive(),
            in: .circle)
      }
      .disabled(appState.isGenerating)
    }
  }

  @ViewBuilder
  private var actionButton: some View {
    if appState.isGenerating {
      Button(action: { appState.stop() }) {
        Image(systemName: "stop.fill")
          .frame(width: DS.controlTarget, height: DS.controlTarget)
          .glassEffect(.regular.tint(.red).interactive(), in: .circle)
          .glassEffectID("action", in: inputNamespace)
      }
      .accessibilityLabel("Stop generating")
      .accessibilityIdentifier("chat.stop")
    } else {
      Button(action: send) {
        Image(systemName: "arrow.up")
          .font(.headline)
          .frame(width: DS.controlTarget, height: DS.controlTarget)
          .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
          .glassEffectID("action", in: inputNamespace)
      }
      .disabled(!canSend)
      .opacity(canSend ? 1 : 0.45)
      .accessibilityLabel("Send")
      .accessibilityIdentifier("chat.send")
    }
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || pendingImage != nil || recorder.finishedURL != nil
  }

  private func send() {
    let text = draft
    let image = pendingImage
    let audioURL = recorder.finishedURL
    draft = ""
    pendingImage = nil
    inputFocused = false
    Haptics.send()
    Task {
      let accepted = await appState.send(
        text: text, imageData: image, audioFileURL: audioURL, in: thread)
      if accepted {
        recorder.discard()
      } else {
        // Nothing was sent: give the user their input back (the recording
        // was never discarded).
        if draft.isEmpty { draft = text }
        if pendingImage == nil { pendingImage = image }
      }
    }
  }
}
