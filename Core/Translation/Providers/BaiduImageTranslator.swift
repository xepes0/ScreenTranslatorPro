import Foundation

/// Baidu image translation provider scaffold.
/// API credentials should be injected from Settings/Keychain.
final class BaiduImageTranslator {
    private let appID: String
    private let secretKey: String

    init(appID: String = "", secretKey: String = "") {
        self.appID = appID
        self.secretKey = secretKey
    }

    func translate(imageData: Data) async throws -> Data {
        // TODO: Implement Baidu image translation API.
        // Pipeline:
        // image -> base64 -> signed request -> translated image/result
        return imageData
    }
}
