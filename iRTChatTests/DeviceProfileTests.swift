import XCTest

@testable import iRTChat

final class DeviceProfileTests: XCTestCase {
  func testE4BGate() {
    XCTAssertTrue(DeviceProfile.supportsE4B(memoryBytes: 8_000_000_000))
    XCTAssertTrue(DeviceProfile.supportsE4B(memoryBytes: 7_000_000_000))
    XCTAssertFalse(DeviceProfile.supportsE4B(memoryBytes: 6_999_999_999))
    XCTAssertFalse(DeviceProfile.supportsE4B(memoryBytes: 6_000_000_000))
    XCTAssertFalse(DeviceProfile.supportsE4B(memoryBytes: 4_000_000_000))
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
