import SwiftMath
import SwiftUI
import UIKit

/// Renders a markdown reply: headings, paragraphs, lists (nested, tasks),
/// code blocks with highlighting and copy, quotes, tables, display math.
struct MarkdownView: View {
  let document: MarkdownDocument

  init(_ text: String) {
    document = MarkdownCache.document(for: text)
  }

  var body: some View {
    BlocksView(blocks: document.blocks)
  }
}

/// Parsed documents by text, so unchanged messages aren't re-parsed on
/// every render (streaming replies change text and miss, by design).
@MainActor
enum MarkdownCache {
  private final class Box {
    let document: MarkdownDocument
    init(_ document: MarkdownDocument) { self.document = document }
  }
  private static let cache: NSCache<NSString, Box> = {
    let cache = NSCache<NSString, Box>()
    cache.countLimit = 200
    return cache
  }()

  static func document(for text: String) -> MarkdownDocument {
    let key = text as NSString
    if let hit = cache.object(forKey: key) { return hit.document }
    let document = MarkdownDocument(parsing: text)
    cache.setObject(Box(document), forKey: key)
    return document
  }
}

private struct BlocksView: View {
  let blocks: [MarkdownDocument.Block]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        BlockView(block: block)
      }
    }
  }
}

private struct BlockView: View {
  let block: MarkdownDocument.Block

  var body: some View {
    switch block {
    case .heading(let level, let text):
      Text(text)
        .font(Self.headingFont(level))
        .padding(.top, level <= 2 ? 4 : 2)
        .accessibilityAddTraits(.isHeader)
    case .paragraph(let text):
      Text(text).lineSpacing(3)
    case .list(let ordered, let start, let items):
      ListBlockView(ordered: ordered, start: start, items: items)
    case .code(let language, let code):
      CodeBlockView(language: language, code: code)
    case .quote(let blocks):
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(.tertiary)
          .frame(width: 3)
        BlocksView(blocks: blocks)
          .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .table(let header, let rows, let alignments):
      TableBlockView(header: header, rows: rows, alignments: alignments)
    case .math(let latex):
      MathBlockView(latex: latex)
    case .rule:
      Divider().padding(.vertical, 4)
    }
  }

  static func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: return .title2.bold()
    case 2: return .title3.bold()
    case 3: return .headline
    default: return .subheadline.bold()
    }
  }
}

private struct ListBlockView: View {
  let ordered: Bool
  let start: Int
  let items: [MarkdownDocument.ListItem]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(marker(index, item))
            .monospacedDigit()
            .foregroundStyle(.secondary)
          BlocksView(blocks: item.blocks)
        }
      }
    }
  }

  private func marker(_ index: Int, _ item: MarkdownDocument.ListItem) -> String {
    if let checked = item.checked { return checked ? "☑" : "☐" }
    return ordered ? "\(start + index)." : "•"
  }
}

struct CodeBlockView: View {
  let language: String?
  let code: String
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language ?? "code")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          UIPasteboard.general.string = code
          copied = true
          Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
          }
        } label: {
          Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("code.copy")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      Divider()
      ScrollView(.horizontal, showsIndicators: false) {
        Text(CodeHighlighter.highlight(code, language: language))
          .font(.callout.monospaced())
          .textSelection(.enabled)
          // Ideal size in both axes: inside a horizontal scroll view the
          // text would otherwise be clipped to a single line.
          .fixedSize()
          .padding(12)
      }
    }
    .background(.fill.quaternary, in: .rect(cornerRadius: DS.radiusInner))
    // A container keeps the Copy button's own identifier.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message.code")
  }
}

private struct TableBlockView: View {
  let header: [AttributedString]
  let rows: [[AttributedString]]
  let alignments: [MarkdownDocument.Alignment]

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
        GridRow {
          ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
            Text(cell).bold().gridColumnAlignment(alignment(column))
          }
        }
        Divider()
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
              Text(cell)
            }
          }
        }
      }
      .font(.callout)
      .padding(12)
    }
    .background(.fill.quaternary, in: .rect(cornerRadius: DS.radiusInner))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message.table")
  }

  private func alignment(_ column: Int) -> HorizontalAlignment {
    guard column < alignments.count else { return .leading }
    switch alignments[column] {
    case .leading: return .leading
    case .center: return .center
    case .trailing: return .trailing
    }
  }
}

/// Display math typeset with SwiftMath; falls back to the LaTeX source.
private struct MathBlockView: View {
  let latex: String

  var body: some View {
    if MathLabel.canRender(latex) {
      ScrollView(.horizontal, showsIndicators: false) {
        MathLabel(latex: latex)
          .padding(.vertical, 4)
      }
      .accessibilityLabel(LaTeXText.unicode(latex))
      .accessibilityIdentifier("message.math")
    } else {
      Text(latex)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
    }
  }
}

private struct MathLabel: UIViewRepresentable {
  let latex: String
  @Environment(\.colorScheme) private var colorScheme

  @MainActor
  static func canRender(_ latex: String) -> Bool {
    let label = MTMathUILabel()
    label.latex = latex
    return label.error == nil
  }

  func makeUIView(context: Context) -> MTMathUILabel {
    let label = MTMathUILabel()
    label.labelMode = .display
    label.textAlignment = .left
    label.fontSize = UIFont.preferredFont(forTextStyle: .body).pointSize * 1.15
    return label
  }

  func updateUIView(_ label: MTMathUILabel, context: Context) {
    label.latex = latex
    label.textColor = .label
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
    uiView.intrinsicContentSize
  }
}
