import Foundation

/// Small structured jobs run on the chat model between replies (titles now;
/// memory and other helpers later). Pure prompt building and parsing, so it
/// is unit-tested; the engine runs them via
/// ``ChatEngineProtocol/helperJSON(prompt:schemaJSON:maxOutputTokens:)``.
///
/// LiteRT-LM keeps one live conversation per engine: a helper run wipes the
/// main conversation, which the app then rebuilds from history.
enum HelperTasks {
  // MARK: Title

  static let titleSchema =
    #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#
  static let titleMaxOutputTokens = 32
  static let maxTitleLength = 48

  static func titlePrompt(user: String, reply: String) -> String {
    """
    Conversation:
    User: \(ContextBudget.prefix(user, maxBytes: 600))
    Assistant: \(ContextBudget.prefix(reply, maxBytes: 600))

    Write a short, specific title (2 to 6 words) for this conversation, in the same language as the conversation. No quotes, no trailing punctuation.
    """
  }

  /// The cleaned title from the model's JSON, or nil if unusable.
  static func parseTitle(_ json: Data) -> String? {
    guard
      let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
      let raw = object["title"] as? String
    else { return nil }
    return cleanTitle(raw)
  }

  static func cleanTitle(_ raw: String) -> String? {
    var title = raw.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let wrappers = CharacterSet(charactersIn: "\"'“”‘’«»*#`")
    title = title.trimmingCharacters(in: wrappers.union(.whitespaces))
    while let last = title.last, ".:;!,".contains(last) { title.removeLast() }
    if title.lowercased().hasPrefix("title ") { title = String(title.dropFirst(6)) }
    guard !title.isEmpty else { return nil }
    if title.count > maxTitleLength {
      let cut = title.prefix(maxTitleLength)
      title = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
    }
    return title
  }
}
