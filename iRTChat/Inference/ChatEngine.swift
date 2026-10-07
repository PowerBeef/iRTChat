import Foundation
import LiteRTLM

// MARK: - Engine boundary types

enum ChatRole: Sendable {
  case user
  case model
}

enum ChatEvent: Sendable {
  case chunk(ChatChunk)
  case finished(GenerationStats)
}

protocol ChatEngineProtocol: Sendable {
  /// Load (or reload) a model with the given options. Returns resolved settings.
  func load(
    spec: ModelSpec, modelURL: URL, options: InferenceOptions, memoryBytes: UInt64,
    enableTools: Bool
  ) async throws -> ResolvedInference
  func unload() async
  var isLoaded: Bool { get async }
  var currentModelID: ModelID? { get async }
  /// Recreate the conversation, re-seeding text history (used after option changes).
  func reseed(history: [(role: ChatRole, text: String)]) async throws
  nonisolated func send(
    text: String, imageData: Data?, audioFileURL: URL?
  ) -> AsyncThrowingStream<ChatEvent, Error>
  func cancel() async
}

// MARK: - Live engine

/// The one and only wrapper between the app and LiteRT-LM. Owns a single
/// `Engine` + `Conversation` pair; everything else talks to this actor.
actor LiteRTChatEngine: ChatEngineProtocol {
  private var engine: Engine?
  private var conversation: Conversation?
  private var resolved: ResolvedInference?
  private var spec: ModelSpec?
  private var options: InferenceOptions?
  private var capabilities: ModelCapabilities?
  private var toolsEnabled = true
  private var generating = false

  var isLoaded: Bool { engine != nil && conversation != nil }
  var currentModelID: ModelID? { spec?.id }

  // MARK: Load

  func load(
    spec: ModelSpec, modelURL: URL, options: InferenceOptions, memoryBytes: UInt64,
    enableTools: Bool
  ) async throws -> ResolvedInference {
    // Stats collection for the per-reply footer (TTFT, tok/s).
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableBenchmark = true

    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw ChatError.modelFileMissing
    }

    unloadLocked()
    var plan = InferencePlanner.resolve(options: options, model: spec.id, memoryBytes: memoryBytes)

    // Introspect the model file (cheap, no engine needed) and intersect the
    // plan with real capabilities: MTP support, thinking, modalities, and
    // the model's context / visual-token limits.
    if let caps = Self.inspect(modelURL: modelURL) {
      capabilities = caps
      plan = InferencePlanner.applyCapabilities(caps, to: plan)
    } else {
      capabilities = nil
    }

    // Engine-level flags must be set before the engine is created. The
    // conversation-level MTP flag (set in makeConversation) inherits these.
    ExperimentalFlags.enableSpeculativeDecoding = plan.enableSpeculativeDecoding
    ExperimentalFlags.filterChannelContentFromKvCache =
      plan.filterThoughtFromCache ? true : nil

    // Attempt ladder: preferred backend first, then the other; multimodal
    // before text-only on each. Degrades gracefully when the model file
    // lacks vision/audio executors or a backend fails to initialize.
    let attempts = InferencePlanner.attempts(for: plan)
    var lastError: Error = ChatError.engineNotReady
    for attempt in attempts {
      do {
        let engine = try await Self.makeEngine(modelURL: modelURL, resolved: attempt)
        let conversation = try await Self.makeConversation(
          engine: engine, resolved: attempt, options: options, toolsEnabled: enableTools,
          history: []
        )
        self.engine = engine
        self.conversation = conversation
        self.resolved = attempt
        self.spec = spec
        self.options = options
        self.toolsEnabled = enableTools
        return attempt
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  func unload() async {
    unloadLocked()
  }

  private func unloadLocked() {
    conversation = nil
    engine = nil // native handle is released in Engine.deinit
    resolved = nil
    spec = nil
    options = nil
    generating = false
  }

  static func cacheDirectory() throws -> String {
    // Library/Caches persists across launches (unlike tmp), so compiled GPU
    // kernels survive restarts and warm-start TTFT stays low.
    let base = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    let dir = base.appendingPathComponent("com.irt.chat.litertlm", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
  }

  /// Read model-file capabilities without initializing an engine.
  nonisolated static func inspect(modelURL: URL) -> ModelCapabilities? {
    guard let info = ModelInfo(modelPath: modelURL.path) else { return nil }
    let modalities = info.inputModalities
    return ModelCapabilities(
      speculativeDecoding: info.llm?.hasSpeculativeDecodingSupport() ?? false,
      thinking: info.llm?.supportsThinking() ?? false,
      functionCalling: info.llm?.supportsFunctionCalling() ?? false,
      vision: modalities.vision,
      audio: modalities.audio,
      maxVisionTokenBudget: info.maxVisionTokenBudget(),
      maxContextTokens: info.maxContextTokens(),
      dynamicContext: info.isDynamicContext()
    )
  }

  private static func makeEngine(modelURL: URL, resolved: ResolvedInference) async throws -> Engine {
    let config = try EngineConfig(
      modelPath: modelURL.path,
      backend: resolved.useGPU ? .gpu : .cpu(),
      visionBackend: resolved.enableVision ? .cpu() : nil,
      audioBackend: resolved.enableAudio ? .cpu() : nil,
      maxNumTokens: resolved.maxNumTokens,
      cacheDir: try cacheDirectory()
    )
    let engine = Engine(engineConfig: config)
    // initialize() blocks for a long time; keep it off the caller's context.
    try await Task.detached(priority: .userInitiated) {
      try await engine.initialize()
    }.value
    return engine
  }

  private static func makeConversation(
    engine: Engine, resolved: ResolvedInference, options: InferenceOptions,
    toolsEnabled: Bool, history: [(role: ChatRole, text: String)]
  ) async throws -> Conversation {
    let sampler = try SamplerConfig(
      topK: resolved.topK, topP: resolved.topP, temperature: resolved.temperature)
    let tools: [any Tool] = toolsEnabled ? [CurrentDateTimeTool(), CalculatorTool()] : []
    let initial = history.suffix(20).map { turn -> LiteRTLM.Message in
      switch turn.role {
      case .user: return LiteRTLM.Message(turn.text, role: .user)
      case .model: return LiteRTLM.Message(turn.text, role: .model)
      }
    }
    let config = ConversationConfig(
      systemMessage: options.systemPrompt.isEmpty ? nil : LiteRTLM.Message(options.systemPrompt),
      initialMessages: initial,
      tools: tools,
      samplerConfig: sampler,
      thinkingConfig: resolved.thinkingBudget.map {
        ThinkingConfig(enableThinking: true, thinkingTokenBudget: $0)
      },
      visualTokenBudget: resolved.visualTokenBudget,
      enableSpeculativeDecoding: resolved.enableSpeculativeDecoding
    )
    return try await engine.createConversation(with: config)
  }

  // MARK: Reseed

  func reseed(history: [(role: ChatRole, text: String)]) async throws {
    guard let engine, let resolved, let options else { throw ChatError.engineNotReady }
    conversation = try await Self.makeConversation(
      engine: engine, resolved: resolved, options: options, toolsEnabled: toolsEnabled,
      history: history
    )
  }

  /// Whether engine-level settings changed (needs full `load`, not just reseed).
  func engineSettingsChanged(for newOptions: InferenceOptions) async -> Bool {
    guard let spec, let previous = resolved else { return true }
    let plan = InferencePlanner.resolve(
      options: newOptions, model: spec.id,
      memoryBytes: DeviceProfile.current.physicalMemoryBytes)
    return previous.useGPU != plan.useGPU || previous.maxNumTokens != plan.maxNumTokens
  }

  /// Apply conversation-level options (sampler, thinking, tools, template)
  /// by recreating the conversation. The caller must use `load` instead when
  /// ``engineSettingsChanged(for:)`` is true.
  func updateConversationOptions(
    _ newOptions: InferenceOptions, history: [(role: ChatRole, text: String)]
  ) async throws -> ResolvedInference {
    guard let spec else { throw ChatError.engineNotReady }
    var plan = InferencePlanner.resolve(
      options: newOptions, model: spec.id,
      memoryBytes: DeviceProfile.current.physicalMemoryBytes)
    if let capabilities {
      plan = InferencePlanner.applyCapabilities(capabilities, to: plan)
    }
    options = newOptions
    resolved = plan
    ExperimentalFlags.enableSpeculativeDecoding = plan.enableSpeculativeDecoding
    ExperimentalFlags.filterChannelContentFromKvCache =
      plan.filterThoughtFromCache ? true : nil
    try await reseed(history: history)
    return plan
  }

  // MARK: Send

  nonisolated func send(
    text: String, imageData: Data?, audioFileURL: URL?
  ) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await self.runSend(
          text: text, imageData: imageData, audioFileURL: audioFileURL,
          continuation: continuation)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func runSend(
    text: String, imageData: Data?, audioFileURL: URL?,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) async {
    guard let conversation, let resolved, let spec else {
      continuation.finish(throwing: ChatError.engineNotReady)
      return
    }
    guard !generating else {
      continuation.finish(throwing: ChatError.underlying(message: "Already generating."))
      return
    }
    generating = true
    defer { generating = false }

    var contents: [Content] = []
    if imageData != nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      contents.append(.text("Describe this image in detail."))
    } else if !text.isEmpty {
      contents.append(.text(text))
    } else {
      contents.append(.text("Hello!"))
    }
    if let imageData { contents.append(.imageData(imageData)) }
    if let audioFileURL { contents.append(.audioFile(audioFileURL.path)) }
    let message = LiteRTLM.Message(contents: contents)

    let started = Date()
    var firstChunkAt: Date?

    func stats(started: Date, firstChunkAt: Date?) -> GenerationStats {
      // Prefer exact runtime measurements; fall back to client-side timing.
      if let info = try? conversation.getBenchmarkInfo() {
        return GenerationStats(
          timeToFirstToken: info.timeToFirstTokenInSecond > 0
            ? info.timeToFirstTokenInSecond : firstChunkAt?.timeIntervalSince(started),
          totalTime: Date().timeIntervalSince(started),
          inputTokens: info.lastPrefillTokenCount,
          outputTokens: info.lastDecodeTokenCount,
          decodeTokensPerSecond: info.lastDecodeTokensPerSecond > 0
            ? info.lastDecodeTokensPerSecond : nil,
          backend: resolved.backendLabel,
          modelID: spec.id
        )
      }
      return GenerationStats(
        timeToFirstToken: firstChunkAt?.timeIntervalSince(started),
        totalTime: Date().timeIntervalSince(started),
        inputTokens: nil,
        outputTokens: nil,
        decodeTokensPerSecond: nil,
        backend: resolved.backendLabel,
        modelID: spec.id
      )
    }

    do {
      let stream = conversation.sendMessageStream(
        message, maxOutputTokens: resolved.maxOutputTokens)
      for try await chunk in stream {
        if Task.isCancelled {
          try? conversation.cancel()
          continuation.finish(throwing: ChatError.generationCancelled)
          return
        }
        if firstChunkAt == nil { firstChunkAt = Date() }
        continuation.yield(
          .chunk(
            ChatChunk(
              textDelta: chunk.toString,
              thoughtDelta: chunk.channels["thought"],
              toolNames: chunk.toolCalls.map(\.name)
            )))
      }
      continuation.yield(.finished(stats(started: started, firstChunkAt: firstChunkAt)))
      continuation.finish()
    } catch is CancellationError {
      try? conversation.cancel()
      continuation.finish(throwing: ChatError.generationCancelled)
    } catch {
      if let chatError = error as? ChatError {
        continuation.finish(throwing: chatError)
      } else {
        continuation.finish(
          throwing: ChatError.underlying(message: error.localizedDescription))
      }
    }
  }

  func cancel() async {
    try? conversation?.cancel()
  }
}

// MARK: - Mock engine (previews, simulator UI smoke tests)

/// Deterministic scripted engine. No model required.
actor MockChatEngine: ChatEngineProtocol {
  var script: [ChatChunk]
  var stats: GenerationStats
  private(set) var loadedModel: ModelID?
  var loadResult: ResolvedInference

  init(
    script: [ChatChunk] = [
      ChatChunk(textDelta: "Hello", thoughtDelta: "Drafting"),
      ChatChunk(textDelta: " from", thoughtDelta: " a reply"),
      ChatChunk(textDelta: " the mock engine!", thoughtDelta: nil),
    ],
    modelID: ModelID = .e2b
  ) {
    self.script = script
    self.stats = GenerationStats(
      timeToFirstToken: 0.2, totalTime: 0.6, inputTokens: 8, outputTokens: 12,
      decodeTokensPerSecond: 40, backend: "Mock", modelID: modelID)
    self.loadResult = InferencePlanner.resolve(
      options: InferenceOptions(), model: modelID, memoryBytes: 8_000_000_000)
  }

  func load(
    spec: ModelSpec, modelURL: URL, options: InferenceOptions, memoryBytes: UInt64,
    enableTools: Bool
  ) async throws -> ResolvedInference {
    loadedModel = spec.id
    loadResult = InferencePlanner.resolve(options: options, model: spec.id, memoryBytes: memoryBytes)
    return loadResult
  }

  func unload() async { loadedModel = nil }
  var isLoaded: Bool { loadedModel != nil }
  var currentModelID: ModelID? { loadedModel }

  func reseed(history: [(role: ChatRole, text: String)]) async throws {}

  nonisolated func send(
    text: String, imageData: Data?, audioFileURL: URL?
  ) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        let script = await self.script
        let stats = await self.stats
        for chunk in script {
          try? await Task.sleep(for: .milliseconds(60))
          if Task.isCancelled {
            continuation.finish(throwing: ChatError.generationCancelled)
            return
          }
          continuation.yield(.chunk(chunk))
        }
        continuation.yield(.finished(stats))
        continuation.finish()
      }
    }
  }

  func cancel() async {}
}
