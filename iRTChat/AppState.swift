import Foundation
import LiteRTLM
import SwiftData
import UIKit

/// Result of an on-demand benchmark run (1024 prefill / 256 decode tokens,
/// matching Google's published methodology).
struct BenchmarkReport: Codable, Sendable, Equatable {
  var modelID: ModelID
  var backend: String
  var prefillTokensPerSecond: Double
  var decodeTokensPerSecond: Double
  var timeToFirstToken: Double
  var date: Date

  var summaryLine: String {
    String(
      format: "%.0f prefill · %.0f decode tok/s · TTFT %.1fs",
      prefillTokensPerSecond, decodeTokensPerSecond, timeToFirstToken)
  }
}

/// Main-actor UI state: engine lifecycle, generation pipeline, options.
@Observable
@MainActor
final class AppState {
  let store: ModelStore
  let engine: any ChatEngineProtocol

  var engineState: ChatEngineState = .idle
  var resolved: ResolvedInference?
  var options = InferenceOptions() {
    didSet { persistOptions() }
  }
  var enableTools = true {
    didSet { UserDefaults.standard.set(enableTools, forKey: "enableTools") }
  }
  var selectedThreadID: UUID? {
    didSet {
      UserDefaults.standard.set(selectedThreadID?.uuidString, forKey: "selectedThreadID")
    }
  }

  var isGenerating = false
  /// The chat whose reply is streaming (only it shows the live cursor and
  /// can't be deleted mid-reply).
  var generatingThreadID: UUID?
  /// What a running tool is doing ("Searched the web for …"), shown in the
  /// live reply; nil when no tool has run in the current reply.
  var toolStatus: String?
  var generationError: String?
  var isBenchmarking = false
  var benchmarkReport: BenchmarkReport? {
    didSet {
      if let report = benchmarkReport,
        let data = try? JSONEncoder().encode(report)
      {
        UserDefaults.standard.set(data, forKey: "benchmarkReport")
      }
    }
  }

  var modelContext: ModelContext?

  /// Thread whose text history the native conversation currently holds.
  @ObservationIgnored private var conversationThreadID: UUID?
  /// True while the native conversation holds no turns (fresh load / empty reseed).
  @ObservationIgnored private var conversationIsEmpty = true
  /// Tail of the engine-lifecycle queue (see ``serialized(_:)``).
  @ObservationIgnored private var lifecycleTail: Task<Void, Never>?
  @ObservationIgnored private var applyOptionsTask: Task<Void, Never>?
  /// Settings changed mid-reply; applied once the reply finishes.
  @ObservationIgnored private var pendingOptionsApply = false

  private var memoryWarningObserver: NSObjectProtocol?

  init(useMockEngine: Bool = false, store: ModelStore? = nil) {
    self.store = store ?? ModelStore()
    self.engine =
      useMockEngine ? MockChatEngine() : LiteRTChatEngine()
    if let data = UserDefaults.standard.data(forKey: "inferenceOptions"),
      let decoded = try? JSONDecoder().decode(InferenceOptions.self, from: data)
    {
      self.options = decoded
    }
    self.enableTools = UserDefaults.standard.object(forKey: "enableTools") as? Bool ?? true
    if let raw = UserDefaults.standard.string(forKey: "selectedThreadID") {
      self.selectedThreadID = UUID(uuidString: raw)
    }
    if let data = UserDefaults.standard.data(forKey: "benchmarkReport"),
      let report = try? JSONDecoder().decode(BenchmarkReport.self, from: data)
    {
      self.benchmarkReport = report
    }
    // iOS sends memory warnings long before it terminates apps (E4B kept
    // working with ~0.8 GB left in the 8 GB simulation), so only stop a reply
    // when memory is actually nearly exhausted (also checked while streaming).
    memoryWarningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Log.lifecycle.warning("memory warning (\(MemoryProbe.summary, privacy: .public))")
      Task { @MainActor in self.stopIfMemoryIsExhausted() }
    }
  }

  var isMock: Bool { engine is MockChatEngine }

  /// Stop a running reply (keeping its text) if the app is about to run out
  /// of memory.
  private func stopIfMemoryIsExhausted() {
    guard isGenerating, DeviceProfile.shouldStopForMemory(availableBytes: MemoryProbe.availableBytes())
    else { return }
    Log.lifecycle.error("low memory: stopping reply (\(MemoryProbe.summary, privacy: .public))")
    stop()
    generationError = "Reply stopped to free memory. Closing other apps can help."
  }

  private func persistOptions() {
    if let data = try? JSONEncoder().encode(options) {
      UserDefaults.standard.set(data, forKey: "inferenceOptions")
    }
  }

  // MARK: - Engine lifecycle

  /// Run engine-lifecycle work (load, switch, options, benchmark, delete) one
  /// at a time. The engine actor is reentrant across its long awaits, so
  /// without this two loads could interleave and briefly hold two engines.
  /// Never call from inside an operation that is already serialized.
  private func serialized<T: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async -> T
  ) async -> T {
    let previous = lifecycleTail
    let task = Task { @MainActor in
      await previous?.value
      return await operation()
    }
    lifecycleTail = Task { @MainActor in _ = await task.value }
    return await task.value
  }

  /// Load the active model if needed. Returns true when ready to generate.
  @discardableResult
  func ensureEngineLoaded() async -> Bool {
    await serialized { await self.loadIfNeeded() }
  }

  private func isActiveModelLoaded() async -> Bool {
    guard await engine.isLoaded, await engine.currentModelID == store.activeModelID else {
      return false
    }
    switch engineState {
    case .ready, .generating: return true
    case .idle, .loading, .failed: return false
    }
  }

  private func loadIfNeeded() async -> Bool {
    if await isActiveModelLoaded() { return true }
    // Never tear down an engine that is mid-reply or benchmarking.
    if isGenerating || isBenchmarking { return false }
    let spec = store.activeSpec
    let url: URL
    if isMock {
      // The scripted engine never reads the file.
      url = store.localURL(for: spec) ?? FileManager.default.temporaryDirectory
    } else {
      guard store.isDownloaded(spec), let local = store.localURL(for: spec) else {
        engineState = .failed(message: "\(spec.displayName) is not downloaded.")
        return false
      }
      url = local
    }
    engineState = .loading(progress: "Loading \(spec.displayName)…")
    // `load` replaces the native conversation with an empty one.
    conversationThreadID = nil
    conversationIsEmpty = true
    do {
      let plan = try await engine.load(
        spec: spec, modelURL: url, options: options,
        memoryBytes: DeviceProfile.current.physicalMemoryBytes,
        enableTools: enableTools
      )
      resolved = plan
      engineState = .ready
      return true
    } catch {
      let message = (error as? ChatError)?.displayMessage ?? error.localizedDescription
      engineState = .failed(message: message)
      return false
    }
  }

  private func unloadEngine() async {
    await engine.unload()
    resolved = nil
    conversationThreadID = nil
    conversationIsEmpty = true
    engineState = .idle
  }

  /// Delete a downloaded model, unloading it first if the engine holds it.
  func deleteModel(_ spec: ModelSpec) async {
    await serialized {
      if await self.engine.currentModelID == spec.id {
        guard !self.isGenerating, !self.isBenchmarking else {
          self.generationError = "Wait for the current reply to finish before deleting the model."
          return
        }
        await self.unloadEngine()
      }
      self.store.deleteModel(spec)
    }
  }

  // MARK: - Options

  /// Settings entry point: coalesces rapid edits (steppers, toggles, text)
  /// into a single apply instead of one engine reload per tap.
  func scheduleApplyOptions() {
    applyOptionsTask?.cancel()
    applyOptionsTask = Task {
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      await self.applyCurrentOptions()
    }
  }

  /// Apply the current options: cheap reseed when only conversation-level
  /// settings changed, full reload for backend / KV-cache changes.
  func applyCurrentOptions() async {
    await serialized { await self.applyOptionsLocked() }
  }

  private func applyOptionsLocked() async {
    // Not loaded: options are picked up by the next load. Never load a
    // multi-GB model just because a setting changed.
    guard await engine.isLoaded else { return }
    if isGenerating || isBenchmarking {
      pendingOptionsApply = true
      return
    }
    let newOptions = options
    if let live = engine as? LiteRTChatEngine {
      if await live.engineSettingsChanged(for: newOptions) {
        Log.engine.info("options: engine-level change, full reload")
        await unloadEngine()
        _ = await loadIfNeeded()
      } else {
        let history = selectedThreadHistory()
        Log.engine.info("options: conversation-level change, reseed \(history.count) turns")
        do {
          resolved = try await live.updateConversationOptions(
            newOptions, enableTools: enableTools, history: history)
          conversationThreadID = selectedThreadID
          conversationIsEmpty = history.isEmpty
        } catch {
          generationError = (error as? ChatError)?.displayMessage ?? error.localizedDescription
        }
      }
    } else if engine is MockChatEngine {
      resolved = InferencePlanner.resolve(
        options: newOptions, model: store.activeModelID,
        memoryBytes: DeviceProfile.current.physicalMemoryBytes)
    }
  }

  private func selectedThreadHistory() -> [(role: ChatRole, text: String)] {
    guard let context = modelContext, let id = selectedThreadID else { return [] }
    let descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == id })
    return (try? context.fetch(descriptor))?.first?.textHistory ?? []
  }

  // MARK: - Threads ↔ native conversation

  /// Make `thread` the conversation the native engine holds. Loads the model
  /// if needed and replays the thread's text history, so context never bleeds
  /// between chats (or is lost on relaunch).
  @discardableResult
  func activate(_ thread: ChatThread) async -> Bool {
    selectedThreadID = thread.id
    let threadID = thread.id
    let history = thread.textHistory
    return await serialized {
      await self.prepareConversation(threadID: threadID, history: history)
    }
  }

  private func prepareConversation(
    threadID: UUID, history: [(role: ChatRole, text: String)]
  ) async -> Bool {
    guard await loadIfNeeded() else { return false }
    if conversationThreadID == threadID { return true }
    // Never swap the conversation out from under a live reply.
    if isGenerating { return false }
    if !(history.isEmpty && conversationIsEmpty) {
      Log.engine.info("reseed for thread switch: \(history.count) turns")
      do {
        try await engine.reseed(history: history)
      } catch {
        generationError = (error as? ChatError)?.displayMessage ?? error.localizedDescription
        return false
      }
    }
    conversationThreadID = threadID
    conversationIsEmpty = history.isEmpty
    return true
  }

  // MARK: - Generation

  /// Send a message in `thread`. Returns false when the message was not
  /// accepted (nothing was persisted), so the caller can restore the draft.
  @discardableResult
  func send(text: String, imageData: Data?, audioFileURL: URL?, in thread: ChatThread) async
    -> Bool
  {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty || imageData != nil || audioFileURL != nil else { return false }
    return await generate(
      prompt: prompt, imageData: imageData, audioFileURL: audioFileURL, in: thread,
      history: nil
    ) {
      thread.append(
        ChatTurn(role: .user, text: prompt, imageData: imageData, hasAudio: audioFileURL != nil))
      if thread.title == "New chat" {
        thread.title = Self.title(prompt: prompt, hasImage: imageData != nil)
      }
    }
  }

  /// Whether `reply`'s prompt can be answered again. Voice recordings aren't
  /// kept, so replies to voice-only messages can't be regenerated.
  func canRegenerate(_ reply: ChatTurn, in thread: ChatThread) -> Bool {
    guard !reply.isUser, let prompt = promptTurn(of: reply, in: thread) else { return false }
    return !prompt.hasAudio || !prompt.text.isEmpty
  }

  /// Answer `reply`'s prompt again as a new version of the reply (the old
  /// one stays reachable through the version switcher).
  @discardableResult
  func regenerate(_ reply: ChatTurn, in thread: ChatThread) async -> Bool {
    guard canRegenerate(reply, in: thread), let prompt = promptTurn(of: reply, in: thread) else {
      return false
    }
    return await generate(
      prompt: prompt.text, imageData: prompt.imageData, audioFileURL: nil, in: thread,
      history: thread.textHistory(before: prompt), replacing: reply
    ) {}
  }

  /// Replace `userTurn` with `text` as a new version and answer it. The
  /// original message and its replies stay reachable as the older version.
  @discardableResult
  func edit(_ userTurn: ChatTurn, text: String, in thread: ChatThread) async -> Bool {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard userTurn.isUser, !prompt.isEmpty || userTurn.imageData != nil else { return false }
    return await generate(
      prompt: prompt, imageData: userTurn.imageData, audioFileURL: nil, in: thread,
      history: thread.textHistory(before: userTurn)
    ) {
      thread.addVersion(ChatTurn(role: .user, text: prompt, imageData: userTurn.imageData), of: userTurn)
    }
  }

  /// Show `turn`'s version (and the conversation after it).
  func selectVersion(_ turn: ChatTurn, in thread: ChatThread) {
    guard !isGenerating || generatingThreadID != thread.id else { return }
    thread.selectBranch(through: turn)
    try? modelContext?.save()
    // The engine holds the previous branch: rebuild it on the next message.
    if conversationThreadID == thread.id { conversationThreadID = nil }
  }

  private func promptTurn(of reply: ChatTurn, in thread: ChatThread) -> ChatTurn? {
    guard let parentID = reply.parentID else { return nil }
    return thread.turns.first { $0.id == parentID && $0.isUser }
  }

  /// Shared generation path. `history` is the text before the new prompt
  /// when the engine must be rebuilt from an earlier point (regenerate,
  /// edit); nil continues the visible branch. Once the message is accepted,
  /// `persist` attaches the user turn (if any), then the reply is added —
  /// as a new version of `replacing` when given.
  private func generate(
    prompt: String, imageData: Data?, audioFileURL: URL?, in thread: ChatThread,
    history rewound: [(role: ChatRole, text: String)]?, replacing: ChatTurn? = nil,
    persist: () -> Void
  ) async -> Bool {
    guard !isGenerating, !isBenchmarking else { return false }
    guard let context = modelContext else { return false }
    generationError = nil

    let threadID = thread.id
    selectedThreadID = threadID
    let history = rewound ?? thread.textHistory
    let ready = await serialized {
      // Rewinding: the engine holds later turns that must not stay in context.
      if rewound != nil, self.conversationThreadID == threadID { self.conversationThreadID = nil }
      return await self.prepareConversation(threadID: threadID, history: history)
    }
    guard ready else { return false }

    // The engine may have degraded to text-only (model without executors).
    if imageData != nil, resolved?.enableVision != true {
      generationError = "This session is text-only, so images are disabled."
      return false
    }
    if audioFileURL != nil, resolved?.enableAudio != true {
      generationError = "This session is text-only, so voice messages are disabled."
      return false
    }

    // Keep the KV cache from overflowing (native heap corruption → crash):
    // trim the replayed history if this message + a reply wouldn't fit.
    let fit: Result<Bool, ChatError> = await serialized {
      do {
        return .success(
          try await self.engine.fitContext(
            text: prompt, imageData: imageData, audioFileURL: audioFileURL, history: history))
      } catch {
        return .failure(
          error as? ChatError ?? .underlying(message: error.localizedDescription))
      }
    }
    switch fit {
    case .success(let trimmed):
      if trimmed {
        conversationThreadID = threadID
        generationError =
          "Older messages were dropped from the model's memory to fit its context window."
      }
    case .failure(let error):
      generationError = error.displayMessage
      return false
    }

    // Placeholder model turn, mutated live as chunks stream in.
    persist()
    let reply = ChatTurn(role: .model)
    if let replacing {
      thread.addVersion(reply, of: replacing)
    } else {
      thread.append(reply)
    }
    try? context.save()

    isGenerating = true
    generatingThreadID = threadID
    engineState = .generating
    conversationIsEmpty = false

    let stream = engine.send(text: prompt, imageData: imageData, audioFileURL: audioFileURL)
    await consume(stream, into: reply, context: context)

    isGenerating = false
    generatingThreadID = nil
    engineState = .ready
    if pendingOptionsApply {
      pendingOptionsApply = false
      await applyCurrentOptions()
    }
    await generateTitleIfNeeded(for: thread)
    return true
  }

  /// After the first exchange, replace the provisional title (the first
  /// words of the first message) with a short model-written one.
  func generateTitleIfNeeded(for thread: ChatThread) async {
    let path = thread.orderedTurns
    guard path.count == 2, let first = path.first, first.isUser,
      let reply = path.last, !reply.isUser, !reply.text.isEmpty,
      !reply.text.hasPrefix(ChatTurn.errorPrefix)
    else { return }
    let provisional = Self.title(prompt: first.text, hasImage: first.imageData != nil)
    guard thread.title == provisional else { return }  // renamed by the user
    let prompt = HelperTasks.titlePrompt(
      user: first.text.isEmpty ? provisional : first.text, reply: reply.text)
    let output: Data? = await serialized {
      guard !self.isGenerating, await self.engine.isLoaded else { return nil }
      let data: Data?
      do {
        data = try await self.engine.helperJSON(
          prompt: prompt, schemaJSON: HelperTasks.titleSchema,
          maxOutputTokens: HelperTasks.titleMaxOutputTokens)
      } catch {
        Log.engine.error("title helper failed: \(String(describing: error), privacy: .public)")
        data = nil
      }
      // The helper replaced the engine's conversation with an empty one:
      // rebuild this chat from history on its next message.
      self.conversationThreadID = nil
      self.conversationIsEmpty = true
      return data
    }
    guard let output, let title = HelperTasks.parseTitle(output), thread.title == provisional
    else {
      Log.engine.error(
        "title helper unusable: \(output.map { String(decoding: $0, as: UTF8.self) } ?? "nil", privacy: .public)")
      return
    }
    thread.title = title
    try? modelContext?.save()
  }

  /// Chat title from the first message; attachment-only messages get a label.
  static func title(prompt: String, hasImage: Bool) -> String {
    if !prompt.isEmpty { return String(prompt.prefix(42)) }
    return hasImage ? "Photo" : "Voice message"
  }

  private func consume(
    _ stream: AsyncThrowingStream<ChatEvent, Error>, into reply: ChatTurn, context: ModelContext
  ) async {
    // Stream into a plain accumulator and publish to the SwiftData model at
    // ~10 Hz: per-token model writes re-render (and re-parse markdown for)
    // the whole bubble 40-100 times a second.
    var accumulator = StreamAccumulator()
    var lastFlush = ContinuousClock.now
    func flush() {
      reply.text = accumulator.text
      reply.thought = accumulator.thought
      if reply.toolNames != accumulator.toolNames { reply.toolNames = accumulator.toolNames }
      if reply.parts.toolActivity != accumulator.toolActivity {
        var parts = reply.parts
        parts.toolActivity = accumulator.toolActivity
        reply.parts = parts
      }
      lastFlush = .now
    }
    toolStatus = nil
    defer { toolStatus = nil }
    do {
      for try await event in stream {
        switch event {
        case .chunk(let chunk):
          accumulator.append(chunk)
          if let latest = chunk.toolActivity.last { toolStatus = latest.summary }
          if ContinuousClock.now - lastFlush >= .milliseconds(100) {
            flush()
            stopIfMemoryIsExhausted()
          }
        case .finished(let stats):
          reply.stats = stats
        }
      }
      flush()
      try? context.save()
      Haptics.complete()
    } catch let error as ChatError {
      flush()
      switch error {
      case .generationCancelled, .replyTruncated:
        if case .replyTruncated = error { generationError = error.displayMessage }
        if reply.text.isEmpty {
          reply.thread?.removeLeaf(reply)
          context.delete(reply)
        }
        try? context.save()
        // LiteRT-LM leaves a cancelled conversation unusable: rebuild it from
        // the thread's history (incl. the partial reply) before the next send.
        conversationThreadID = nil
      default:
        reply.text = reply.text.isEmpty ? ChatTurn.errorPrefix + error.displayMessage : reply.text
        try? context.save()
        Haptics.error()
      }
    } catch {
      flush()
      reply.text = reply.text.isEmpty ? ChatTurn.errorPrefix + error.localizedDescription : reply.text
      try? context.save()
      Haptics.error()
    }
  }

  func stop() {
    Task { await engine.cancel() }
  }

  /// iOS doesn't allow GPU work in the background: stop a running reply
  /// deliberately (keeping the partial text) instead of letting Metal
  /// command buffers fail or the app be terminated.
  func enterBackground() {
    guard isGenerating else { return }
    Log.lifecycle.info("background: stopping generation")
    stop()
    generationError = "Reply stopped because iRTChat moved to the background."
  }

  // MARK: - Benchmark

  /// Run a text benchmark (1024 prefill / 256 decode) on the active model.
  /// Unloads the chat engine first so the benchmark has full memory; the
  /// engine reloads lazily on the next chat.
  func runBenchmark() async {
    await serialized { await self.runBenchmarkLocked() }
  }

  private func runBenchmarkLocked() async {
    guard !isBenchmarking, !isGenerating else { return }
    let spec = store.activeSpec
    guard store.isDownloaded(spec), let url = store.localURL(for: spec) else {
      generationError = "\(spec.displayName) is not downloaded."
      return
    }
    isBenchmarking = true
    await unloadEngine()
    engineState = .loading(progress: "Benchmarking \(spec.displayName)…")
    defer {
      isBenchmarking = false
      engineState = .idle
    }
    do {
      let useGPU = options.backendPreference == .gpu
      let cacheDir = try LiteRTChatEngine.cacheDirectory()
      // Extract Sendable scalars inside the task: BenchmarkInfo itself is not Sendable.
      let result = try await Task.detached(priority: .userInitiated) {
        () -> (prefill: Double, decode: Double, ttft: Double) in
        let info = try await LiteRTLM.benchmark(
          modelPath: url.path,
          backend: useGPU ? .gpu : .cpu(),
          prefillTokens: 1024,
          decodeTokens: 256,
          cacheDir: cacheDir
        )
        return (
          info.lastPrefillTokensPerSecond, info.lastDecodeTokensPerSecond,
          info.timeToFirstTokenInSecond)
      }.value
      benchmarkReport = BenchmarkReport(
        modelID: spec.id,
        backend: useGPU ? "GPU" : "CPU",
        prefillTokensPerSecond: result.prefill,
        decodeTokensPerSecond: result.decode,
        timeToFirstToken: result.ttft,
        date: Date()
      )
    } catch {
      generationError =
        "Benchmark failed: \((error as? ChatError)?.displayMessage ?? error.localizedDescription)"
    }
  }

  // MARK: - Threads

  func newThread(in context: ModelContext) -> ChatThread {
    let thread = ChatThread(modelID: store.activeModelID)
    context.insert(thread)
    try? context.save()
    // The native conversation is re-pointed when the chat is opened
    // (``activate(_:)``), not here.
    return thread
  }

  func deleteThread(_ thread: ChatThread, in context: ModelContext) {
    if selectedThreadID == thread.id { selectedThreadID = nil }
    if conversationThreadID == thread.id { conversationThreadID = nil }
    context.delete(thread)
    try? context.save()
  }
}
