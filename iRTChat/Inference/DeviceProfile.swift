import Foundation

/// Device capability profile. All decisions are pure functions of the physical
/// memory size so they stay unit-testable; ``current`` reads the real device.
struct DeviceProfile: Sendable, Equatable {
  let physicalMemoryBytes: UInt64

  static var current: DeviceProfile {
    DeviceProfile(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
  }

  var memoryGB: Double { Double(physicalMemoryBytes) / 1_000_000_000.0 }

  // MARK: - Policy (pure)

  /// Minimum RAM for Gemma 4 E4B. Published peak memory on iPhone GPU is
  /// ~3.3 GB, so 8 GB-class devices (reporting ~7+ GB usable) qualify.
  static func supportsE4B(memoryBytes: UInt64) -> Bool {
    memoryBytes >= 7_000_000_000
  }

  var supportsE4B: Bool { Self.supportsE4B(memoryBytes: physicalMemoryBytes) }

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
    String(format: "%.0f GB RAM · E4B %@", memoryGB, supportsE4B ? "supported" : "not advised")
  }
}
