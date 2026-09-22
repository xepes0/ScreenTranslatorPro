import Foundation
import CoreGraphics

struct OCRResult: Identifiable {
    let id = UUID()
    let text: String
    let boundingBox: CGRect
}
