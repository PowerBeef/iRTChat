import Observation
import XCTest

@testable import iRTChat

private final class Flag: @unchecked Sendable {
  var value = false
}

/// Regression tests for the download-finishing path: the temp file must be
/// moved synchronously and size-verified (async hops let the system delete it).
final class ModelStoreTests: XCTestCase {
  private var scratch: URL!
  private var savedActiveModelID: String?

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    savedActiveModelID = UserDefaults.standard.string(forKey: "activeModelID")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
    if let savedActiveModelID {
      UserDefaults.standard.set(savedActiveModelID, forKey: "activeModelID")
    } else {
      UserDefaults.standard.removeObject(forKey: "activeModelID")
    }
  }

  func testPlaceDownloadedFileMovesAndVerifies() throws {
    let source = scratch.appendingPathComponent("CFNetworkDownload_tmp.tmp")
    try Data(repeating: 0xAB, count: 1024).write(to: source)
    let models = scratch.appendingPathComponent("Models", isDirectory: true)

    let placed = try ModelStore.placeDownloadedFile(
      from: source, fileName: "model.litertlm", expectedSize: 1024, in: models)

    XCTAssertEqual(placed.lastPathComponent, "model.litertlm")
    XCTAssertTrue(FileManager.default.fileExists(atPath: placed.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  func testPlaceDownloadedFileRejectsWrongSizeAndCleansUp() throws {
    let source = scratch.appendingPathComponent("partial.tmp")
    try Data(repeating: 0x00, count: 100).write(to: source)
    let models = scratch.appendingPathComponent("Models", isDirectory: true)

    XCTAssertThrowsError(
      try ModelStore.placeDownloadedFile(
        from: source, fileName: "model.litertlm", expectedSize: 1024, in: models)
    ) { error in
      XCTAssertEqual(
        error as? ModelStoreError, .sizeMismatch(expected: 1024, actual: 100))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: models.appendingPathComponent("model.litertlm").path))
  }

  func testPlaceDownloadedFileMissingSourceThrows() throws {
    let models = scratch.appendingPathComponent("Models", isDirectory: true)
    XCTAssertThrowsError(
      try ModelStore.placeDownloadedFile(
        from: scratch.appendingPathComponent("gone.tmp"),
        fileName: "model.litertlm", expectedSize: 10, in: models))
  }

  func testPlaceDownloadedFileReplacesExisting() throws {
    let models = scratch.appendingPathComponent("Models", isDirectory: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try Data(repeating: 0x00, count: 5).write(
      to: models.appendingPathComponent("model.litertlm"))
    let source = scratch.appendingPathComponent("new.tmp")
    try Data(repeating: 0xFF, count: 8).write(to: source)

    let placed = try ModelStore.placeDownloadedFile(
      from: source, fileName: "model.litertlm", expectedSize: 8, in: models)
    let data = try Data(contentsOf: placed)
    XCTAssertEqual(data, Data(repeating: 0xFF, count: 8))
  }

  // MARK: - Download hygiene (audit #9)

  func testModelsDirectoryIsExcludedFromBackup() throws {
    let dir = try ModelStore.modelsDirectory()
    let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  func testStorageCheckRequiresFileSizePlusMargin() {
    let spec = ModelCatalog.e2b
    XCTAssertTrue(ModelStore.hasRoom(for: spec, availableBytes: nil))
    XCTAssertTrue(
      ModelStore.hasRoom(for: spec, availableBytes: spec.sizeBytes + ModelStore.storageMargin))
    XCTAssertFalse(ModelStore.hasRoom(for: spec, availableBytes: spec.sizeBytes))
  }

  func testErrorPagesAreRejected() throws {
    let url = ModelCatalog.e2b.downloadURL
    let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    let missing = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)
    XCTAssertNoThrow(try ModelStore.validateResponse(ok))
    XCTAssertThrowsError(try ModelStore.validateResponse(missing)) { error in
      XCTAssertEqual(error as? ModelStoreError, .httpStatus(404))
    }
  }

  /// Starting a second download used to leave the first stuck on
  /// "Downloading…" with dead Pause/Cancel buttons.
  @MainActor
  func testStartingAnotherDownloadPausesTheFirst() {
    let store = ModelStore()
    guard !store.isDownloaded(ModelCatalog.e2b), !store.isDownloaded(ModelCatalog.e4b) else {
      return
    }
    store.startDownload(ModelCatalog.e2b)
    store.startDownload(ModelCatalog.e4b)
    defer {
      store.cancelDownload(ModelCatalog.e4b)
      store.cancelDownload(ModelCatalog.e2b)
    }
    guard case .paused = store.states[.e2b] else {
      return XCTFail("First download should be paused, is \(String(describing: store.states[.e2b]))")
    }
    guard case .downloading = store.states[.e4b] else {
      return XCTFail("Second download should be active, is \(String(describing: store.states[.e4b]))")
    }
  }

  // MARK: - Active model selection

  @MainActor
  func testActiveModelIDPersistsAcrossInstances() {
    let store = ModelStore()
    let other: ModelID = store.activeModelID == .e2b ? .e4b : .e2b
    store.activeModelID = other
    XCTAssertEqual(ModelStore().activeModelID, other)
  }

  @MainActor
  func testActiveModelIDChangeNotifiesObservers() {
    // "Use this model" must move the Active badge and refresh pickers:
    // a UserDefaults-backed computed property emits no observation.
    let store = ModelStore()
    let other: ModelID = store.activeModelID == .e2b ? .e4b : .e2b
    let flag = Flag()
    withObservationTracking {
      _ = store.activeModelID
    } onChange: {
      flag.value = true
    }
    store.activeModelID = other
    XCTAssertTrue(flag.value)
  }
}
