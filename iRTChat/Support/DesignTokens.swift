import SwiftUI

/// Single source of truth for element sizes, corner radii, and spacing.
///
/// Coherence rules:
/// - Every tappable control is at least 44pt (HIG minimum).
/// - Row/card header icons share one size; inline marks share a smaller one.
/// - Radii descend with surface size: card > bubble > banner > inner > thumb.
/// - Spacing snaps to 16 / 12 / 8 / 6. Nothing else.
enum DS {
  // MARK: - Targets & marks

  /// Minimum tappable control: input buttons, thumbnails, send/stop.
  static let controlTarget: CGFloat = 44
  /// Row and card header icons (thread rows, model cards, settings status).
  static let iconLG: CGFloat = 40
  /// Inline marks (message avatar).
  static let iconSM: CGFloat = 32
  /// Empty-state hero mark.
  static let heroMark: CGFloat = 64

  // MARK: - Corner radii

  static let radiusCard: CGFloat = 24
  static let radiusBubble: CGFloat = 22
  static let radiusBanner: CGFloat = 18
  static let radiusInner: CGFloat = 16
  static let radiusThumb: CGFloat = 12

  // MARK: - Spacing

  static let spaceLG: CGFloat = 16
  static let spaceMD: CGFloat = 12
  static let spaceSM: CGFloat = 8
  static let spaceXS: CGFloat = 6

  // MARK: - Insets

  static let padMD: CGFloat = 12
  static let padSM: CGFloat = 8
}
