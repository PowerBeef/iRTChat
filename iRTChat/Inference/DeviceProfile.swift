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

  /// Default KV-cache size (`maxNumTokens`) per model and memory class.
  static func defaultMaxTokens(model: ModelID, memoryBytes: UInt64) -> Int {
    let roomy = memoryBytes >= 7_000_000_000
    switch model {
    case .e2b:
      return roomy ? 4096 : 2048
    case .e4b:
      // E4B has a larger per-token footprint; stay conservative even on Pro.
      return roomy ? 2048 : 1024
    }
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
