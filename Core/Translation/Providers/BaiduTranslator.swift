import Foundation

/// Baidu text translation provider.
/// API signing and credential storage will be added in the next milestone.
final class BaiduTranslator: TranslationProvider {
    let name = "Baidu"

    func translate(text: String, from: String, to: String) async throws -> String {
        text
    }
}
