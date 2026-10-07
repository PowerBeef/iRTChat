import XCTest

@testable import iRTChat

final class ModelCatalogTests: XCTestCase {
  func testDefaultIsE2B() {
    XCTAssertEqual(ModelCatalog.default.id, .e2b)
    XCTAssertEqual(ModelCatalog.spec(for: .e2b).id, .e2b)
  }

  func testDownloadURLs() {
    for spec in ModelCatalog.all {
      let url = spec.downloadURL
      XCTAssertEqual(url.scheme, "https")
      XCTAssertEqual(url.host, "huggingface.co")
      XCTAssertTrue(url.path.contains(spec.repo))
      XCTAssertTrue(url.path.hasSuffix(spec.fileName))
    }
    XCTAssertEqual(
      ModelCatalog.e2b.downloadURL.absoluteString,
      "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm"
    )
    XCTAssertEqual(
      ModelCatalog.e4b.downloadURL.absoluteString,
      "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm"
    )
  }

  func testVerifiedSizes() {
    // Byte counts verified against Hugging Face content-length headers.
    // Base (multimodal) files: the `-gpu` variants are text-only.
    XCTAssertEqual(ModelCatalog.e2b.sizeBytes, 2_588_147_712)
    XCTAssertEqual(ModelCatalog.e4b.sizeBytes, 3_659_530_240)
  }

  func testE4BRequiresRoomyDevice() {
    XCTAssertTrue(ModelCatalog.e4b.requiresRoomyDevice)
    XCTAssertFalse(ModelCatalog.e2b.requiresRoomyDevice)
  }
}
