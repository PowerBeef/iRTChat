import SwiftData
import SwiftUI

struct ThreadListView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var context
  @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
  @State private var path: [ChatThread] = []

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if threads.isEmpty {
          ContentUnavailableView {
            Label("No chats yet", systemImage: "sparkles")
          } description: {
            Text("Start a new on-device chat.")
          } actions: {
            Button("New chat", action: startNewChat)
              .buttonStyle(.glassProminent)
              .accessibilityIdentifier("threads.empty.new")
          }
        } else {
          List {
            ForEach(threads) { thread in
              NavigationLink(value: thread) {
                HStack(spacing: 12) {
                  Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.callout)
                    .frame(width: DS.iconLG, height: DS.iconLG)
                    .glassEffect(.regular, in: .circle)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title).font(.headline).lineLimit(1)
                    Text(subtitle(for: thread))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
                .padding(.vertical, 2)
              }
              .accessibilityIdentifier("threads.row")
              // Its reply is still being written into this chat.
              .deleteDisabled(appState.generatingThreadID == thread.id)
            }
            .onDelete(perform: delete)
          }
        }
      }
      .navigationTitle("Chats")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button(action: startNewChat) {
            Image(systemName: "square.and.pencil")
          }
          .accessibilityLabel("New chat")
          .accessibilityIdentifier("threads.new")
        }
      }
      .navigationDestination(for: ChatThread.self) { thread in
        ChatView(thread: thread)
      }
    }
  }

  /// Create a chat and open it immediately.
  private func startNewChat() {
    path = [appState.newThread(in: context)]
  }

  private func subtitle(for thread: ChatThread) -> String {
    let model = ModelCatalog.spec(for: thread.modelID).displayName
    let count = thread.orderedTurns.count
    let messages = count == 1 ? "1 message" : "\(count) messages"
    let date = thread.createdAt.formatted(date: .abbreviated, time: .omitted)
    return "\(model) · \(messages) · \(date)"
  }

  private func delete(at offsets: IndexSet) {
    for index in offsets {
      appState.deleteThread(threads[index], in: context)
    }
  }
}
