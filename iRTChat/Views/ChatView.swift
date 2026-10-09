import PhotosUI
import SwiftData
import SwiftUI

/// A conversation, or a new chat (`thread == nil`) that is saved when its
/// first message is sent.
struct ChatView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var context
  let thread: ChatThread?

  @State private var draft = ""
  @State private var pendingImage: Data?
  @State private var photoItem: PhotosPickerItem?
  @State private var recorder = AudioRecorder()
  @State private var showLibrary = false
  @State private var reader = SpeechReader()
  /// The user message being edited in the composer, if any.
  @State private var editingTurn: ChatTurn?
  @FocusState private var inputFocused: Bool
  @Namespace private var inputNamespace

  var body: some View {
    // Computed once per render (not per use: this re-renders while streaming).
    let turns = thread?.orderedTurns ?? []
    let versions = versionGroups()
    VStack(spacing: 0) {
      engineBanner
      noticeBanner
      messagesList(turns, versions: versions)
      editingBar
      pendingBar
      inputBar
    }
    .background(ambientBackground)
    .navigationTitle(thread?.title ?? "iRTChat")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showLibrary) {
      NavigationStack {
        ModelLibraryView()
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showLibrary = false }
            }
          }
      }
    }
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
    .task(id: thread?.id) {
      if let thread {
        await appState.activate(thread)
      } else if appState.isMock || appState.store.activeSpecDownloaded {
        // Warm the model up while the first message is typed.
        await appState.ensureEngineLoaded()
      }
    }
    .onChange(of: thread?.id) { old, _ in
      // Switching chats (not saving a new one) starts with a clean composer.
      guard old != nil else { return }
      reader.stop()
      editingTurn = nil
      draft = ""
      pendingImage = nil
    }
    .onDisappear { reader.stop() }
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

  private func messagesList(_ turns: [ChatTurn], versions: [VersionKey: [ChatTurn]]) -> some View {
    Group {
      if turns.isEmpty {
        emptyState
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: DS.spaceLG) {
              ForEach(turns) { turn in
                MessageBubbleView(
                  turn: turn, isStreaming: isLiveBubble(turn, in: turns),
                  toolStatus: appState.toolStatus,
                  versions: versions[VersionKey(turn)] ?? [],
                  actions: actions(for: turn))
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
      Text("Chat with \(appState.store.activeSpec.displayName)")
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

  // MARK: - Message actions

  struct VersionKey: Hashable {
    var parentID: UUID?
    var role: String
    init(_ turn: ChatTurn) {
      parentID = turn.parentID
      role = turn.roleRaw
    }
  }

  /// Turns that are versions of each other (same parent and role), only
  /// where there is more than one.
  private func versionGroups() -> [VersionKey: [ChatTurn]] {
    // Unlinked (legacy, never migrated) threads have no parents to group by.
    guard let thread, thread.activeLeafID != nil else { return [:] }
    return Dictionary(grouping: thread.turns, by: VersionKey.init)
      .filter { $0.value.count > 1 }
      .mapValues { $0.sorted { $0.createdAt < $1.createdAt } }
  }

  private func actions(for turn: ChatTurn) -> MessageActions {
    guard let thread else { return MessageActions() }
    return MessageActions(
      isBusy: appState.isGenerating,
      isSpeaking: reader.speakingID == turn.id,
      canRegenerate: !turn.isUser && appState.canRegenerate(turn, in: thread),
      regenerate: {
        reader.stop()
        Haptics.send()
        Task { await appState.regenerate(turn, in: thread) }
      },
      edit: { startEditing(turn) },
      speak: { reader.toggle(turn.text, id: turn.id) },
      selectVersion: { version in
        withAnimation(.snappy) { appState.selectVersion(version, in: thread) }
      })
  }

  private func startEditing(_ turn: ChatTurn) {
    editingTurn = turn
    draft = turn.text
    pendingImage = nil
    recorder.discard()
    inputFocused = true
  }

  private func cancelEditing() {
    editingTurn = nil
    draft = ""
  }

  @ViewBuilder
  private var editingBar: some View {
    if editingTurn != nil {
      HStack(spacing: 8) {
        Image(systemName: "pencil")
        Text("Editing message")
          .font(.caption)
          .accessibilityIdentifier("chat.editing")
        Spacer()
        Button("Cancel", action: cancelEditing)
          .font(.caption)
          .buttonStyle(.glass)
          .controlSize(.small)
          .accessibilityIdentifier("chat.editing.cancel")
      }
      .padding(.horizontal)
      .padding(.vertical, 4)
    }
  }

  private func scrollSignature(_ turns: [ChatTurn]) -> String {
    let last = turns.last
    return "\(turns.count)-\(last?.text.count ?? 0)-\(last?.thought.count ?? 0)"
  }

  private func isLiveBubble(_ turn: ChatTurn, in turns: [ChatTurn]) -> Bool {
    appState.generatingThreadID == thread?.id && turn.id == turns.last?.id && !turn.isUser
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
      .disabled(appState.isGenerating || editingTurn != nil)
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
      .disabled(appState.isGenerating || editingTurn != nil)
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
    reader.stop()
    if let editingTurn, let thread {
      let text = draft
      draft = ""
      self.editingTurn = nil
      inputFocused = false
      Haptics.send()
      Task {
        let accepted = await appState.edit(editingTurn, text: text, in: thread)
        if !accepted, draft.isEmpty {
          draft = text
          self.editingTurn = editingTurn
        }
      }
      return
    }
    let text = draft
    let image = pendingImage
    let audioURL = recorder.finishedURL
    draft = ""
    pendingImage = nil
    inputFocused = false
    Haptics.send()
    let target = thread ?? appState.newThread(in: context)
    Task {
      let accepted = await appState.send(
        text: text, imageData: image, audioFileURL: audioURL, in: target)
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
