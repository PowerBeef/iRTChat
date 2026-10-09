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
    // OOM guard: E4B + memory pressure = stop generation before jetsam kills us.
    memoryWarningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Log.lifecycle.warning("memory warning (\(MemoryProbe.summary, privacy: .public))")
      Task { @MainActor in
        if self.isGenerating, await self.engine.currentModelID == .e4b {
          await self.engine.cancel()
          self.generationError =
            "Stopped to protect memory. E4B is tight on this device — try E2B."
        }
      }
    }
  }

  var isMock: Bool { engine is MockChatEngine }

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
    if spec.requiresRoomyDevice, !DeviceProfile.current.supportsE4B {
      engineState = .failed(
        message: "\(spec.displayName) needs an 8 GB-class iPhone. Using E2B is advised.")
      return false
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

  func switchModel(to id: ModelID) async {
    await serialized {
      guard !self.isGenerating, !self.isBenchmarking else {
        self.generationError = "Wait for the current reply to finish before switching models."
        return
      }
      if self.store.activeModelID == id, await self.isActiveModelLoaded() { return }
      await self.unloadEngine()
      self.store.activeModelID = id
      _ = await self.loadIfNeeded()
    }
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
  /// when the thread uses the active model and replays the thread's text
  /// history, so context never bleeds between chats (or is lost on relaunch).
  @discardableResult
  func activate(_ thread: ChatThread) async -> Bool {
    selectedThreadID = thread.id
    let threadID = thread.id
    let modelID = thread.modelID
    let history = thread.textHistory
    return await serialized {
      await self.prepareConversation(threadID: threadID, modelID: modelID, history: history)
    }
  }

  private func prepareConversation(
    threadID: UUID, modelID: ModelID, history: [(role: ChatRole, text: String)]
  ) async -> Bool {
    guard modelID == store.activeModelID else { return false }
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
    guard !isGenerating, !isBenchmarking else { return false }
    guard let context = modelContext else { return false }
    generationError = nil

    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty || imageData != nil || audioFileURL != nil else { return false }

    guard thread.modelID == store.activeModelID else {
      generationError =
        "This chat uses \(ModelCatalog.spec(for: thread.modelID).displayName). Tap Switch to continue it."
      return false
    }
    guard await activate(thread) else { return false }

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
    let history = thread.textHistory
    let threadID = thread.id
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

    // Persist the user turn.
    let userTurn = ChatTurn(
      role: .user, text: prompt, imageData: imageData, hasAudio: audioFileURL != nil)
    thread.turns.append(userTurn)
    if thread.title == "New chat" {
      thread.title = Self.title(prompt: prompt, hasImage: imageData != nil)
    }
    // Placeholder model turn, mutated live as chunks stream in.
    let reply = ChatTurn(role: .model)
    thread.turns.append(reply)
    try? context.save()

    isGenerating = true
    generatingThreadID = thread.id
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
    return true
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
      lastFlush = .now
    }
    do {
      for try await event in stream {
        switch event {
        case .chunk(let chunk):
          accumulator.append(chunk)
          if ContinuousClock.now - lastFlush >= .milliseconds(100) { flush() }
        case .finished(let stats):
          reply.stats = stats
        }
      }
      flush()
      try? context.save()
      Haptics.complete()
    } catch let error as ChatError {
      flush()
      if case .generationCancelled = error {
        if reply.text.isEmpty { context.delete(reply) }
        try? context.save()
        // LiteRT-LM leaves a cancelled conversation unusable: rebuild it from
        // the thread's history (incl. the partial reply) before the next send.
        conversationThreadID = nil
      } else {
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
