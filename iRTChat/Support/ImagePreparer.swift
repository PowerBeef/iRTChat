import UIKit

/// Downscale + re-encode user photos before vision input to bound memory.
enum ImagePreparer {
  static func prepare(_ data: Data, maxDimension: CGFloat = 1568) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    let longest = max(image.size.width, image.size.height)
    guard longest > 0 else { return nil }
    let scale = min(1, maxDimension / longest)
    let targetSize = CGSize(
      width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    let resized = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
    return resized.jpegData(compressionQuality: 0.85)
  }
}
