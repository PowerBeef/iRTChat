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

  /// Load the active model if needed. Returns true when ready to generate.
  @discardableResult
  func ensureEngineLoaded() async -> Bool {
    if case .ready = engineState, await engine.isLoaded,
      await engine.currentModelID == store.activeModelID
    {
      return true
    }
    let spec = store.activeSpec
    guard store.isDownloaded(spec), let url = store.localURL(for: spec) else {
      engineState = .failed(message: "\(spec.displayName) is not downloaded.")
      return false
    }
    if spec.requiresRoomyDevice, !DeviceProfile.current.supportsE4B {
      engineState = .failed(
        message: "\(spec.displayName) needs an 8 GB-class iPhone. Using E2B is advised.")
      // Still allow the attempt? No: fail fast with a clear message.
      return false
    }
    engineState = .loading(progress: "Loading \(spec.displayName)…")
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

  func switchModel(to id: ModelID) async {
    await engine.unload()
    resolved = nil
    store.activeModelID = id
    engineState = .idle
    await ensureEngineLoaded()
  }

  /// Apply option changes: cheap reseed when only conversation-level settings
  /// changed, full reload for backend / KV-cache changes.
  func applyOptions(_ newOptions: InferenceOptions, history: [(role: ChatRole, text: String)]) async {
    options = newOptions
    guard await engine.isLoaded else {
      await ensureEngineLoaded()
      return
    }
    if let live = engine as? LiteRTChatEngine {
      if await live.engineSettingsChanged(for: newOptions) {
        await ensureEngineLoadedForceReload()
      } else {
        do {
          resolved = try await live.updateConversationOptions(newOptions, history: history)
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

  private func ensureEngineLoadedForceReload() async {
    await engine.unload()
    engineState = .idle
    await ensureEngineLoaded()
  }

  /// Apply the current options to the selected thread (Settings entry point).
  func applyCurrentOptions() async {
    await applyOptions(options, history: selectedThreadHistory())
  }

  private func selectedThreadHistory() -> [(role: ChatRole, text: String)] {
    guard let context = modelContext, let id = selectedThreadID else { return [] }
    let threads = (try? context.fetch(FetchDescriptor<ChatThread>())) ?? []
    return threads.first(where: { $0.id == id })?.textHistory ?? []
  }

  // MARK: - Generation

  func send(text: String, imageData: Data?, audioFileURL: URL?, in thread: ChatThread) async {
    guard !isGenerating else { return }
    guard let context = modelContext else { return }
    generationError = nil

    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty || imageData != nil || audioFileURL != nil else { return }

    guard await ensureEngineLoaded() else { return }

    // The engine may have degraded to text-only (model without executors).
    if imageData != nil, resolved?.enableVision != true {
      generationError = "This session is text-only, so images are disabled."
      return
    }
    if audioFileURL != nil, resolved?.enableAudio != true {
      generationError = "This session is text-only, so voice messages are disabled."
      return
    }

    // Persist the user turn.
    let userTurn = ChatTurn(role: .user, text: prompt, imageData: imageData)
    thread.turns.append(userTurn)
    if thread.title == "New chat" {
      thread.title = String(prompt.prefix(42))
    }
    // Placeholder model turn, mutated live as chunks stream in.
    let reply = ChatTurn(role: .model)
    thread.turns.append(reply)
    try? context.save()

    isGenerating = true
    engineState = .generating
    defer {
      isGenerating = false
      engineState = .ready
    }

    let stream = engine.send(text: prompt, imageData: imageData, audioFileURL: audioFileURL)
    do {
      for try await event in stream {
        switch event {
        case .chunk(let chunk):
          reply.text += chunk.textDelta
          if let thought = chunk.thoughtDelta { reply.thought += thought }
          for name in chunk.toolNames where !reply.toolNames.contains(name) {
            reply.toolNames.append(name)
          }
        case .finished(let stats):
          reply.stats = stats
        }
      }
      try? context.save()
      Haptics.complete()
    } catch let error as ChatError {
      if case .generationCancelled = error {
        if reply.text.isEmpty { context.delete(reply) }
        try? context.save()
      } else {
        reply.text = reply.text.isEmpty ? "Error: \(error.displayMessage)" : reply.text
        try? context.save()
        Haptics.error()
      }
    } catch {
      reply.text = reply.text.isEmpty ? "Error: \(error.localizedDescription)" : reply.text
      try? context.save()
      Haptics.error()
    }
  }

  func stop() {
    Task { await engine.cancel() }
  }

  // MARK: - Benchmark

  /// Run a text benchmark (1024 prefill / 256 decode) on the active model.
  /// Unloads the chat engine first so the benchmark has full memory; the
  /// engine reloads lazily on the next chat.
  func runBenchmark() async {
    guard !isBenchmarking, !isGenerating else { return }
    let spec = store.activeSpec
    guard store.isDownloaded(spec), let url = store.localURL(for: spec) else {
      generationError = "\(spec.displayName) is not downloaded."
      return
    }
    isBenchmarking = true
    engineState = .loading(progress: "Benchmarking \(spec.displayName)…")
    defer {
      isBenchmarking = false
      engineState = .idle
    }
    await engine.unload()
    resolved = nil
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

  func newThread(in context: ModelContext) -> ChatThread {
    let thread = ChatThread(modelID: store.activeModelID)
    context.insert(thread)
    try? context.save()
    selectedThreadID = thread.id
    // Fresh native conversation (no history bleed between threads).
    Task { try? await engine.reseed(history: []) }
    return thread
  }

  func deleteThread(_ thread: ChatThread, in context: ModelContext) {
    if selectedThreadID == thread.id { selectedThreadID = nil }
    context.delete(thread)
    try? context.save()
  }
}
