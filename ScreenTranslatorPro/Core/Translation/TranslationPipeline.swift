import Foundation

final class TranslationPipeline {
    private let manager = TranslationManager()

    func translate(results: [OCRResult]) async throws -> [OCRResult] {
        var output: [OCRResult] = []

        for var item in results {
            item.translation = try await manager.translate(item.text)
            output.append(item)
        }

        return output
    }
}
