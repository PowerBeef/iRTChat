import Foundation
import SwiftData

/// One chat session with a fixed model.
@Model
final class ChatThread {
  var id: UUID
  var title: String
  var createdAt: Date
  var modelIDRaw: String
  @Relationship(deleteRule: .cascade, inverse: \ChatTurn.thread)
  var turns: [ChatTurn] = []

  init(title: String = "New chat", modelID: ModelID = .e2b) {
    self.id = UUID()
    self.title = title
    self.createdAt = Date()
    self.modelIDRaw = modelID.rawValue
  }

  var modelID: ModelID {
    get { ModelID(rawValue: modelIDRaw) ?? .e2b }
    set { modelIDRaw = newValue.rawValue }
  }

  var orderedTurns: [ChatTurn] {
    turns.sorted { $0.createdAt < $1.createdAt }
  }

  /// Text history for re-seeding the native conversation after option changes.
  var textHistory: [(role: ChatRole, text: String)] {
    orderedTurns.compactMap { turn in
      guard !turn.text.isEmpty else { return nil }
      return (turn.chatRole, turn.text)
    }
  }
}

/// One user or model message, with optional reasoning, tools, stats, image.
@Model
final class ChatTurn {
  var id: UUID
  var roleRaw: String
  var text: String
  var thought: String
  var toolNames: [String]
  var statsData: Data?
  @Attribute(.externalStorage)
  var imageData: Data?
  var createdAt: Date
  var thread: ChatThread?

  init(
    role: ChatRole, text: String = "", thought: String = "",
    toolNames: [String] = [], stats: GenerationStats? = nil,
    imageData: Data? = nil
  ) {
    self.id = UUID()
    self.roleRaw = role == .user ? "user" : "model"
    self.text = text
    self.thought = thought
    self.toolNames = toolNames
    self.statsData = stats.flatMap { try? JSONEncoder().encode($0) }
    self.imageData = imageData
    self.createdAt = Date()
  }

  var chatRole: ChatRole { roleRaw == "model" ? .model : .user }
  var isUser: Bool { chatRole == .user }

  var stats: GenerationStats? {
    get {
      guard let statsData else { return nil }
      return try? JSONDecoder().decode(GenerationStats.self, from: statsData)
    }
    set { statsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
  }
}
