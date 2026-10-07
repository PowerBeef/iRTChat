import UIKit

/// Subtle haptics for key moments. Fire-and-forget; safe from any thread.
enum Haptics {
  static func send() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  static func complete() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  static func error() {
    UINotificationFeedbackGenerator().notificationOccurred(.error)
  }
}
