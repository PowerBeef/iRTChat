import Foundation

/// Downloadable Gemma 4 model in `.litertlm` format.
struct ModelSpec: Identifiable, Sendable, Equatable {
  let id: ModelID
  let displayName: String
  let tagline: String
  let repo: String
  let fileName: String
  /// Expected download size in bytes (verified against Hugging Face).
  let sizeBytes: Int64
  /// True when the model should only run on roomy (8 GB-class) devices.
  let requiresRoomyDevice: Bool

  var downloadURL: URL {
    // swiftlint:disable:next force_unwrapping
    URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)")!
  }

  var sizeDisplay: String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: sizeBytes)
  }
}

enum ModelCatalog {
  static let e2b = ModelSpec(
    id: .e2b,
    displayName: "Gemma 4 E2B",
    tagline: "Fast multimodal default. Text, vision, audio + thinking.",
    repo: "litert-community/gemma-4-E2B-it-litert-lm",
    fileName: "gemma-4-E2B-it.litertlm",
    sizeBytes: 2_588_147_712,
    requiresRoomyDevice: false
  )

  static let e4b = ModelSpec(
    id: .e4b,
    displayName: "Gemma 4 E4B",
    tagline: "Higher quality. Needs an 8 GB-class iPhone.",
    repo: "litert-community/gemma-4-E4B-it-litert-lm",
    fileName: "gemma-4-E4B-it.litertlm",
    sizeBytes: 3_659_530_240,
    requiresRoomyDevice: true
  )

  static let all: [ModelSpec] = [e2b, e4b]

  static let `default`: ModelSpec = e2b

  static func spec(for id: ModelID) -> ModelSpec {
    all.first(where: { $0.id == id }) ?? e2b
  }
}
