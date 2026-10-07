import Foundation

/// Fully resolved engine settings. Pure value produced by ``InferencePlanner``
/// and mapped onto LiteRT-LM types at the engine boundary.
struct ResolvedInference: Sendable, Equatable {
  var useGPU: Bool
  var maxNumTokens: Int
  var enableVision: Bool
  var enableAudio: Bool
  /// Thinking token budget, or nil when thinking is disabled.
  var thinkingBudget: Int?
  var topK: Int
  var topP: Float
  var temperature: Float
  var visualTokenBudget: Int32?
  var enableSpeculativeDecoding: Bool
  var maxOutputTokens: Int?
  var filterThoughtFromCache: Bool

  var backendLabel: String { useGPU ? "GPU" : "CPU" }
}

/// Model-file capabilities from `ModelInfo` introspection (no engine needed).
struct ModelCapabilities: Sendable, Equatable {
  var speculativeDecoding: Bool
  var thinking: Bool
  var functionCalling: Bool
  var vision: Bool
  var audio: Bool
  /// -1 when the model has no vision budget info.
  var maxVisionTokenBudget: Int
  var maxContextTokens: Int
  var dynamicContext: Bool

  /// Assume full support (used when introspection is unavailable, e.g. mocks).
  static let full = ModelCapabilities(
    speculativeDecoding: true, thinking: true, functionCalling: true,
    vision: true, audio: true, maxVisionTokenBudget: -1,
    maxContextTokens: 0, dynamicContext: true
  )
}

enum InferencePlanner {
  static let minTokens = 256
  static let maxTokens = 8192

  /// Resolve user options + model + device into concrete engine settings.
  static func resolve(
    options: InferenceOptions,
    model: ModelID,
    memoryBytes: UInt64
  ) -> ResolvedInference {
    let maxNumTokens: Int
    if let override = options.maxNumTokensOverride {
      maxNumTokens = min(max(minTokens, override), maxTokens)
    } else {
      maxNumTokens = DeviceProfile.defaultMaxTokens(model: model, memoryBytes: memoryBytes)
    }

    return ResolvedInference(
      useGPU: options.backendPreference == .gpu,
      maxNumTokens: maxNumTokens,
      enableVision: options.enableVision,
      enableAudio: options.enableAudio,
      thinkingBudget: options.enableThinking ? max(128, options.thinkingBudget) : nil,
      topK: options.samplerPreset.topK,
      topP: options.samplerPreset.topP,
      temperature: options.samplerPreset.temperature,
      visualTokenBudget: options.enableVision ? options.visualDetail.tokenBudget : nil,
      enableSpeculativeDecoding: options.enableSpeculativeDecoding,
      maxOutputTokens: options.maxOutputTokens,
      filterThoughtFromCache: options.compactReasoningCache
    )
  }

  /// Intersect resolved settings with model-file capabilities. Turns off MTP,
  /// thinking, and modalities the file lacks, and clamps the visual budget
  /// and KV cache to the model's stated limits.
  static func applyCapabilities(
    _ caps: ModelCapabilities, to resolved: ResolvedInference
  ) -> ResolvedInference {
    var out = resolved
    if !caps.speculativeDecoding { out.enableSpeculativeDecoding = false }
    if !caps.thinking { out.thinkingBudget = nil }
    out.enableVision = out.enableVision && caps.vision
    out.enableAudio = out.enableAudio && caps.audio
    if !out.enableVision {
      out.visualTokenBudget = nil
    } else if caps.maxVisionTokenBudget > 0, let budget = out.visualTokenBudget {
      out.visualTokenBudget = min(budget, Int32(caps.maxVisionTokenBudget))
    }
    if caps.maxContextTokens > 0 {
      out.maxNumTokens = min(out.maxNumTokens, caps.maxContextTokens)
    }
    return out
  }

  /// CPU fallback used when GPU initialization fails: same settings on CPU.
  static func cpuFallback(from resolved: ResolvedInference) -> ResolvedInference {
    var copy = resolved
    copy.useGPU = false
    return copy
  }

  /// Ordered engine-init attempts: preferred backend first, then the other;
  /// multimodal before text-only on each. Duplicates removed (e.g. when the
  /// options already disable multimodal, or CPU is preferred).
  static func attempts(for plan: ResolvedInference) -> [ResolvedInference] {
    let backends: [Bool] = plan.useGPU ? [true, false] : [false]
    var attempts: [ResolvedInference] = []
    for gpu in backends {
      for multimodal in [true, false] {
        var attempt = plan
        attempt.useGPU = gpu
        if !multimodal {
          attempt.enableVision = false
          attempt.enableAudio = false
          attempt.visualTokenBudget = nil
        }
        if !attempts.contains(attempt) {
          attempts.append(attempt)
        }
      }
    }
    return attempts
  }
}
