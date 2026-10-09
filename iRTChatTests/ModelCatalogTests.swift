import XCTest

@testable import iRTChat

final class ModelCatalogTests: XCTestCase {
  func testE4BIsTheOnlyModel() {
    XCTAssertEqual(ModelCatalog.all.map(\.id), [.e4b])
    XCTAssertEqual(ModelCatalog.default.id, .e4b)
    XCTAssertEqual(ModelCatalog.spec(for: .e4b).id, .e4b)
  }

  func testRetiredModelIdentifiersContinueOnE4B() {
    XCTAssertEqual(ModelID(storedValue: "e2b"), .e4b)
    XCTAssertEqual(ModelID(storedValue: "e4b"), .e4b)
    XCTAssertEqual(ModelID(storedValue: "something-else"), .e4b)
  }

  func testDownloadURL() {
    let url = ModelCatalog.e4b.downloadURL
    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(url.host, "huggingface.co")
    XCTAssertEqual(
      url.absoluteString,
      "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm"
    )
  }

  func testVerifiedSize() {
    // Byte count verified against the Hugging Face content-length header.
    XCTAssertEqual(ModelCatalog.e4b.sizeBytes, 3_659_530_240)
  }
}
