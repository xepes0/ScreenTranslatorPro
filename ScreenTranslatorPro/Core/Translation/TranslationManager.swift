import Foundation

final class TranslationManager {
    private var providers: [TranslationProvider] = []
    
    func register(_ provider: TranslationProvider) {
        providers.append(provider)
    }
    
    func translate(
        text: String,
        source: String,
        target: String
    ) async throws -> String {
        guard let provider = providers.first else {
            return text
        }
        return try await provider.translate(
            text: text,
            source: source,
            target: target
        )
    }
}
