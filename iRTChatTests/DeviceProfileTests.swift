import XCTest

@testable import iRTChat

final class DeviceProfileTests: XCTestCase {
  func testE4BGateFallsBackToPhysicalRAMWhenLimitUnknown() {
    func gate(_ bytes: UInt64) -> Bool {
      DeviceProfile.supportsE4B(physicalMemoryBytes: bytes, appMemoryLimitBytes: nil)
    }
    XCTAssertTrue(gate(8_000_000_000))
    XCTAssertTrue(gate(7_000_000_000))
    XCTAssertFalse(gate(6_999_999_999))
    XCTAssertFalse(gate(4_000_000_000))
  }

  /// Device finding: a 12 GB iPhone 17 Pro allowed the app only ~3.5 GB
  /// without the increased-memory-limit entitlement, ~6.4 GB with it.
  func testE4BGateUsesAppMemoryLimitWhenKnown() {
    let twelveGB: UInt64 = 12_000_000_000
    XCTAssertFalse(
      DeviceProfile.supportsE4B(physicalMemoryBytes: twelveGB, appMemoryLimitBytes: 3_540_000_000))
    XCTAssertTrue(
      DeviceProfile.supportsE4B(physicalMemoryBytes: twelveGB, appMemoryLimitBytes: 6_420_000_000))
    XCTAssertTrue(
      DeviceProfile.supportsE4B(
        physicalMemoryBytes: 6_000_000_000, appMemoryLimitBytes: 4_600_000_000))
  }

  func testDefaultMaxTokens() {
    // Calibrated: 8K for everyday chat on all supported (8 GB+) devices.
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e2b, memoryBytes: 8_000_000_000), 8192)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 8_000_000_000), 8192)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e2b, memoryBytes: 6_000_000_000), 4096)
  }

  func testLongContextCeilingFollowsAppMemoryLimit() {
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e2b, appMemoryLimitBytes: 8_600_000_000), 32_768)
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: 8_600_000_000), 32_768)
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: 5_000_000_000), 16_384)
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e2b, appMemoryLimitBytes: 4_000_000_000), 16_384)
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e2b, appMemoryLimitBytes: nil), 16_384)
  }

  func testCurrentDeviceReadsMemory() {
    XCTAssertGreaterThan(DeviceProfile.current.physicalMemoryBytes, 0)
    XCTAssertGreaterThan(DeviceProfile.current.memoryGB, 0)
  }
}
