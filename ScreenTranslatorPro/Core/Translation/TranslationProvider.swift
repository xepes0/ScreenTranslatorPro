import Foundation

protocol TranslationProvider {
    var name: String { get }
    
    func translate(
        text: String,
        source: String,
        target: String
    ) async throws -> String
}
