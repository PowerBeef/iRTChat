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
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e2b, memoryBytes: 8_000_000_000), 4096)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e2b, memoryBytes: 6_000_000_000), 2048)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 8_000_000_000), 2048)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 6_000_000_000), 1024)
  }

  func testCurrentDeviceReadsMemory() {
    XCTAssertGreaterThan(DeviceProfile.current.physicalMemoryBytes, 0)
    XCTAssertGreaterThan(DeviceProfile.current.memoryGB, 0)
  }
}
