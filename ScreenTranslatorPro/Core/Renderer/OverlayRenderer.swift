import UIKit

final class OverlayRenderer {
    func render(original: UIImage, items: [OCRResult]) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: original.size)

        return renderer.image { context in
            original.draw(at: .zero)

            for item in items {
                let rect = CGRect(
                    x: item.boundingBox.origin.x * original.size.width,
                    y: (1 - item.boundingBox.maxY) * original.size.height,
                    width: item.boundingBox.width * original.size.width,
                    height: item.boundingBox.height * original.size.height
                )

                UIColor.clear.setFill()
                context.cgContext.fill(rect)

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: max(rect.height, 12))
                ]

                item.translation.draw(in: rect, withAttributes: attributes)
            }
        }
    }
}
