import UIKit

/// Renders translated text back into the original screenshot coordinates.
/// v0.1 foundation: real painting pipeline will be implemented after OCR integration.
final class OverlayRenderer {
    func render(image: UIImage, items: [TranslationOverlayItem]) -> UIImage {
        image
    }
}

struct TranslationOverlayItem {
    let original: String
    let translated: String
    let rect: CGRect
}
