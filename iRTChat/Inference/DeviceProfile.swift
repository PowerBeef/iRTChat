import Foundation

/// Device capability profile. All decisions are pure functions of memory
/// sizes so they stay unit-testable; ``current`` reads the real device.
struct DeviceProfile: Sendable, Equatable {
  let physicalMemoryBytes: UInt64
  /// The app's memory limit (what jetsam enforces), or nil where the OS
  /// doesn't report it (simulator).
  let appMemoryLimitBytes: UInt64?

  init(physicalMemoryBytes: UInt64, appMemoryLimitBytes: UInt64? = nil) {
    self.physicalMemoryBytes = physicalMemoryBytes
    self.appMemoryLimitBytes = appMemoryLimitBytes
  }

  static var current: DeviceProfile {
    let available = MemoryProbe.availableBytes()
    return DeviceProfile(
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      // Footprint + still-available = the limit, independent of current usage.
      appMemoryLimitBytes: available > 0 ? MemoryProbe.footprintBytes() + available : nil)
  }

  var memoryGB: Double { Double(physicalMemoryBytes) / 1_000_000_000.0 }

  // MARK: - Policy (pure)

  /// Minimum app memory limit for Gemma 4 E4B: ~1.1 GB after load, ~2.3 GB
  /// with vision/audio executors and a 2K KV cache (measured on iPhone 17
  /// Pro), plus headroom for the UI and image decoding.
  static let e4bMinimumAppLimit: UInt64 = 4_500_000_000

  /// Whether E4B is safe to run. Uses the app's real memory limit when known
  /// (a 12 GB iPhone allows only ~3.5 GB without the increased-memory-limit
  /// entitlement); otherwise falls back to physical RAM (8 GB-class devices).
  static func supportsE4B(physicalMemoryBytes: UInt64, appMemoryLimitBytes: UInt64?) -> Bool {
    if let appMemoryLimitBytes {
      return appMemoryLimitBytes >= e4bMinimumAppLimit
    }
    return physicalMemoryBytes >= 7_000_000_000
  }

  var supportsE4B: Bool {
    Self.supportsE4B(
      physicalMemoryBytes: physicalMemoryBytes, appMemoryLimitBytes: appMemoryLimitBytes)
  }

  /// Everyday chat context. Calibrated on iPhone 17 Pro: a larger KV cache
  /// slows *every* reply (E2B decode 83 → 69 → 54 → 40 tok/s at 4K → 8K →
  /// 16K → 32K), so chat stays at 8K and long inputs use ``maxContextTokens``.
  static let standardContextTokens = 8_192

  /// Default KV-cache size (`maxNumTokens`). Supported devices (iPhone 15 Pro
  /// and later) all have 8 GB+; smaller values only apply to the simulator.
  static func defaultMaxTokens(model: ModelID, memoryBytes: UInt64) -> Int {
    memoryBytes >= 7_000_000_000 ? standardContextTokens : 4_096
  }

  /// Largest context worth loading for long inputs (files, web passages).
  /// Measured peaks at 32K with a third of it filled: E2B 2.8 GB, E4B 3.6 GB.
  /// The model file may cap it further (E2B: 32,003).
  static func maxContextTokens(model: ModelID, appMemoryLimitBytes: UInt64?) -> Int {
    guard let limit = appMemoryLimitBytes else { return 16_384 }
    switch model {
    case .e2b: return limit >= 4_500_000_000 ? 32_768 : 16_384
    case .e4b: return limit >= 6_500_000_000 ? 32_768 : 16_384
    }
  }

  func maxContextTokens(model: ModelID) -> Int {
    Self.maxContextTokens(model: model, appMemoryLimitBytes: appMemoryLimitBytes)
  }

  func defaultMaxTokens(model: ModelID) -> Int {
    Self.defaultMaxTokens(model: model, memoryBytes: physicalMemoryBytes)
  }

  /// Human-readable capability summary for Settings.
  var summary: String {
    var parts = [String(format: "%.0f GB RAM", memoryGB)]
    if let appMemoryLimitBytes {
      parts.append(String(format: "app limit %.1f GB", Double(appMemoryLimitBytes) / 1e9))
    }
    parts.append(supportsE4B ? "E4B supported" : "E4B not advised")
    return parts.joined(separator: " · ")
  }
}
