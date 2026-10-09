import SwiftUI

/// One chat message. User turns are tinted glass (tint = authorship);
/// model turns are calm full-width text with glass accents.
struct MessageBubbleView: View {
  let turn: ChatTurn
  var isStreaming: Bool = false
  /// What a tool is doing right now (live reply only).
  var toolStatus: String? = nil

  var body: some View {
    if turn.isUser {
      userBubble
    } else {
      modelBlock
    }
  }

  // MARK: - User

  private var userBubble: some View {
    HStack(alignment: .bottom, spacing: 8) {
      Spacer(minLength: 56)
      VStack(alignment: .trailing, spacing: 6) {
        if let data = turn.imageData, let image = UIImage(data: data) {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 220)
            .clipShape(.rect(cornerRadius: DS.radiusBanner))
        }
        if turn.hasAudio {
          Label("Voice message", systemImage: "waveform")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(.accentColor), in: .rect(cornerRadius: DS.radiusBubble))
            .accessibilityIdentifier("message.voice")
        }
        if !turn.text.isEmpty {
          Text(turn.text)
            .textSelection(.enabled)
            .accessibilityIdentifier("message.user")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(.accentColor), in: .rect(cornerRadius: DS.radiusBubble))
        }
      }
    }
  }

  // MARK: - Model

  private var modelBlock: some View {
    HStack(alignment: .top, spacing: DS.spaceMD) {
      Image(systemName: "sparkles")
        .font(.footnote)
        .frame(width: DS.iconSM, height: DS.iconSM)
        .glassEffect(.regular, in: .circle)
      VStack(alignment: .leading, spacing: 8) {
        if isStreaming, let toolStatus {
          HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(toolStatus)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("message.toolStatus")
        }
        if !turn.text.isEmpty {
          HStack(alignment: .lastTextBaseline, spacing: 3) {
            renderedText(turn.text)
              .textSelection(.enabled)
              .accessibilityIdentifier("message.model")
            if isStreaming {
              RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3, height: 17)
                .phaseAnimator([1.0, 0.25]) { view, value in
                  view.opacity(value)
                } animation: { _ in
                  .easeInOut(duration: 0.6).repeatForever()
                }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else if isStreaming {
          thinkingDots
        }
        if !turn.thought.isEmpty {
          thoughtCard
        }
        if !turn.toolNames.isEmpty {
          toolChips
        }
        if let stats = turn.stats {
          Text(stats.footerLine)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier("message.stats")
        }
      }
      Spacer(minLength: 4)
    }
  }

  private var thinkingDots: some View {
    HStack(spacing: 6) {
      ForEach(0..<3) { index in
        Circle()
          .fill(Color.secondary)
          .frame(width: 7, height: 7)
          .phaseAnimator([false, true]) { dot, active in
            dot.opacity(active ? 0.25 : 1.0)
          } animation: { _ in
            .easeInOut(duration: 0.6).delay(Double(index) * 0.2).repeatForever()
          }
      }
    }
    .padding(.vertical, 6)
    .accessibilityLabel("Thinking")
  }

  private var thoughtCard: some View {
    DisclosureGroup {
      Text(turn.thought)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    } label: {
      Label("Reasoning", systemImage: "brain")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(DS.padMD)
    .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusInner))
    .accessibilityIdentifier("message.reasoning")
  }

  private var toolChips: some View {
    GlassEffectContainer(spacing: 6) {
      HStack(spacing: 6) {
        ForEach(turn.toolNames, id: \.self) { name in
          Label(name, systemImage: "wrench.and.screwdriver")
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, DS.spaceXS)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("message.tool")
        }
      }
    }
  }

  private func renderedText(_ text: String) -> some View {
    if let attributed = try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    {
      return Text(attributed).lineSpacing(3)
    }
    return Text(text).lineSpacing(3)
  }
}
