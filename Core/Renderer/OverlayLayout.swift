import Foundation

struct OverlayLayout: Identifiable, Codable {
    let id = UUID()
    let originalText: String
    let translatedText: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
