import Foundation
import CryptoKit

protocol TextTranslationProvider: Sendable {
    var kind: ProviderKind { get }
    func translate(text: String, source: String, target: String) async throws -> String
}

struct BaiduTextTranslator: TextTranslationProvider {
    let kind: ProviderKind = .baiduText
    let appID: String
    let secret: String

    func translate(text: String, source: String, target: String) async throws -> String {
        guard !appID.isEmpty else { throw ScreenTranslatorError.missingCredential("百度 APP ID") }
        guard !secret.isEmpty else { throw ScreenTranslatorError.missingCredential("百度密钥") }
        let salt = String(UInt64.random(in: 100000...999999999))
        let digest = Insecure.MD5.hash(data: Data((appID + text + salt + secret).utf8))
        let sign = digest.map { String(format: "%02x", $0) }.joined()

        var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["q": text, "from": source.isEmpty ? "auto" : source, "to": target, "appid": appID, "salt": salt, "sign": sign])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ScreenTranslatorError.invalidResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let decoded = try JSONDecoder().decode(BaiduResponse.self, from: data)
        if let code = decoded.errorCode { throw ScreenTranslatorError.invalidResponse("百度错误 \(code)：\(decoded.errorMsg ?? "unknown")") }
        let output = decoded.transResult?.map(\.dst).joined(separator: "\n") ?? ""
        guard !output.isEmpty else { throw ScreenTranslatorError.invalidResponse("百度返回空译文") }
        return output
    }

    private func formBody(_ values: [String:String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let s = values.map { k,v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.sorted().joined(separator:"&")
        return Data(s.utf8)
    }

    private struct BaiduResponse: Decodable {
        let transResult: [Item]?
        let errorCode: String?
        let errorMsg: String?
        enum CodingKeys: String, CodingKey {
            case transResult="trans_result", errorCode="error_code", errorMsg="error_msg"
        }
        struct Item: Decodable { let src:String; let dst:String }
    }
}

struct DeepLTranslator: TextTranslationProvider {
    let kind: ProviderKind = .deepL
    let authKey: String

    func translate(text: String, source: String, target: String) async throws -> String {
        guard !authKey.isEmpty else { throw ScreenTranslatorError.missingCredential("DeepL Auth Key") }
        let endpoint = authKey.hasSuffix(":fx") ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate"
        var request = URLRequest(url: URL(string:endpoint)!)
        request.httpMethod="POST"; request.timeoutInterval=30
        request.setValue("DeepL-Auth-Key \(authKey)", forHTTPHeaderField:"Authorization")
        request.setValue("application/json", forHTTPHeaderField:"Content-Type")
        var payload:[String:Any] = ["text":[text], "target_lang":normalize(target)]
        if source.lowercased() != "auto" && !source.isEmpty { payload["source_lang"] = normalize(source) }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {
            throw ScreenTranslatorError.invalidResponse("DeepL HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let decoded=try JSONDecoder().decode(Response.self,from:data)
        guard let value=decoded.translations.first?.text,!value.isEmpty else { throw ScreenTranslatorError.invalidResponse("DeepL 返回空译文") }
        return value
    }

    private func normalize(_ code:String)->String {
        switch code.lowercased() {
        case "zh","zh-cn": return "ZH-HANS"
        case "cht","zh-tw": return "ZH-HANT"
        case "jp","ja": return "JA"
        case "en": return "EN"
        default: return code.uppercased()
        }
    }
    private struct Response:Decodable { struct Translation:Decodable{let text:String}; let translations:[Translation] }
}

struct OpenAICompatibleTranslator: TextTranslationProvider {
    let kind: ProviderKind = .openAICompatible
    let apiKey:String
    let endpoint:String
    let model:String

    func translate(text:String, source:String, target:String) async throws -> String {
        guard !apiKey.isEmpty else { throw ScreenTranslatorError.missingCredential("API Key") }
        guard let url=URL(string:endpoint) else { throw ScreenTranslatorError.invalidResponse("Endpoint URL 无效") }
        var request=URLRequest(url:url); request.httpMethod="POST"; request.timeoutInterval=45
        request.setValue("Bearer \(apiKey)",forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let from = source.lowercased()=="auto" ? "auto-detect" : source
        let prompt="Translate this UI text from \(from) to \(target). Keep it concise and preserve numbers/symbols. Return only the translation.\n\n\(text)"
        let payload:[String:Any]=["model":model,"temperature":0.1,"messages":[["role":"system","content":"You are a concise UI translation engine."],["role":"user","content":prompt]]]
        request.httpBody=try JSONSerialization.data(withJSONObject:payload)
        let (data,response)=try await URLSession.shared.data(for:request)
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {
            let body=String(data:data,encoding:.utf8) ?? ""
            throw ScreenTranslatorError.invalidResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) \(body)")
        }
        let decoded=try JSONDecoder().decode(Response.self,from:data)
        guard let value=decoded.choices.first?.message.content.trimmingCharacters(in:.whitespacesAndNewlines),!value.isEmpty else {
            throw ScreenTranslatorError.invalidResponse("模型返回空译文")
        }
        return value
    }
    private struct Response:Decodable {
        struct Choice:Decodable { struct Message:Decodable{let content:String}; let message:Message }
        let choices:[Choice]
    }
}



struct BaiduCloudImageTranslator: Sendable {
    let apiKey: String
    let secretKey: String

    func translate(image: UIImage, source: String, target: String) async throws -> UIImage {
        guard !apiKey.isEmpty else { throw ScreenTranslatorError.missingCredential("百度智能云 API Key") }
        guard !secretKey.isEmpty else { throw ScreenTranslatorError.missingCredential("百度智能云 Secret Key") }

        let token = try await BaiduCloudTokenCache.shared.accessToken(apiKey: apiKey, secretKey: secretKey)
        let imageData = try Self.preparedJPEG(from: image)

        var components = URLComponents(string: "https://aip.baidubce.com/file/2.0/mt/pictrans/v1")!
        components.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = components.url else {
            throw ScreenTranslatorError.invalidResponse("百度图片翻译 URL 无效")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            imageData: imageData,
            source: Self.baiduLanguage(source, allowAuto: true),
            target: Self.baiduLanguage(target, allowAuto: false)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ScreenTranslatorError.invalidResponse("百度图片翻译 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScreenTranslatorError.invalidResponse("百度图片翻译返回非 JSON")
        }

        let errorCode = String(describing: root["error_code"] ?? "-1")
        guard errorCode == "0" else {
            let message = String(describing: root["error_msg"] ?? "unknown")
            throw ScreenTranslatorError.invalidResponse("百度图片翻译错误 \(errorCode)：\(message)")
        }

        guard
            let payload = root["data"] as? [String: Any],
            let pasteBase64 = payload["pasteImg"] as? String,
            let pasteData = Data(base64Encoded: pasteBase64, options: .ignoreUnknownCharacters),
            let output = UIImage(data: pasteData)
        else {
            throw ScreenTranslatorError.invalidResponse("百度未返回整图 pasteImg，请确认图片翻译服务已开通")
        }

        return output
    }

    private static func preparedJPEG(from image: UIImage) throws -> Data {
        var current = image
        let maxDimension: CGFloat = 4096
        let longest = max(current.size.width, current.size.height)
        if longest > maxDimension {
            let scale = maxDimension / longest
            let target = CGSize(width: current.size.width * scale, height: current.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            current = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                current.draw(in: CGRect(origin: .zero, size: target))
            }
        }

        for quality in stride(from: 0.92, through: 0.45, by: -0.08) {
            if let data = current.jpegData(compressionQuality: quality), data.count < 3_900_000 {
                return data
            }
        }

        var scale: CGFloat = 0.85
        while scale >= 0.5 {
            let target = CGSize(width: current.size.width * scale, height: current.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                current.draw(in: CGRect(origin: .zero, size: target))
            }
            if let data = resized.jpegData(compressionQuality: 0.72), data.count < 3_900_000 {
                return data
            }
            scale -= 0.1
        }

        throw ScreenTranslatorError.invalidResponse("图片压缩后仍超过百度 4MB 限制")
    }

    private static func baiduLanguage(_ code: String, allowAuto: Bool) -> String {
        let lower = code.lowercased()
        if allowAuto && lower == "auto" { return "auto" }
        switch lower {
        case "ja": return "jp"
        case "ko": return "kor"
        case "fr": return "fra"
        case "es": return "spa"
        case "vi": return "vie"
        case "pt-br", "pt-pt": return "pt"
        case "zh-cn": return "zh"
        case "zh-tw": return "cht"
        default: return lower
        }
    }

    private static func multipartBody(
        boundary: String,
        imageData: Data,
        source: String,
        target: String
    ) -> Data {
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendUTF8("\(value)\r\n")
        }

        appendField("from", source)
        appendField("to", target)
        appendField("v", "3")
        appendField("paste", "1")

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"image\"; filename=\"screenshot.jpg\"\r\n")
        body.appendUTF8("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }
}

private actor BaiduCloudTokenCache {
    static let shared = BaiduCloudTokenCache()

    private var cachedToken: String?
    private var expiresAt: Date = .distantPast
    private var credentialFingerprint = ""

    func accessToken(apiKey: String, secretKey: String) async throws -> String {
        let fingerprint = "\(apiKey)|\(secretKey)"
        if
            fingerprint == credentialFingerprint,
            let cachedToken,
            Date() < expiresAt.addingTimeInterval(-300)
        {
            return cachedToken
        }

        var components = URLComponents(string: "https://aip.baidubce.com/oauth/2.0/token")!
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: apiKey),
            URLQueryItem(name: "client_secret", value: secretKey)
        ]

        guard let url = components.url else {
            throw ScreenTranslatorError.invalidResponse("百度鉴权 URL 无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ScreenTranslatorError.invalidResponse("百度鉴权 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let token = result.accessToken, !token.isEmpty else {
            throw ScreenTranslatorError.invalidResponse(result.errorDescription ?? result.error ?? "无法获取百度 access_token")
        }

        cachedToken = token
        credentialFingerprint = fingerprint
        expiresAt = Date().addingTimeInterval(TimeInterval(result.expiresIn ?? 2_592_000))
        return token
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let expiresIn: Int?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case error
            case errorDescription = "error_description"
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}

final class TranslationService: Sendable {
    func translate(_ items:[OCRResult], source:String, target:String) async throws -> [OCRResult] {
        guard !items.isEmpty else { throw ScreenTranslatorError.noTextFound }
        let kind=AppConfiguration.provider
        if kind == .localOCR {
            return items.map { var copy=$0; copy.translation=$0.text; return copy }
        }
        if kind == .baiduImageCloud {
            throw ScreenTranslatorError.invalidResponse("百度图片翻译应走整图翻译流程")
        }
        let provider=try makeProvider(kind)
        var output:[OCRResult]=[]
        for (index,item) in items.enumerated() {
            var copy=item
            copy.translation=try await provider.translate(text:item.text,source:source,target:target)
            output.append(copy)
            if kind == .baiduText && index < items.count-1 {
                try await Task.sleep(for:.milliseconds(1050))
            }
        }
        return output
    }

    private func makeProvider(_ kind:ProviderKind) throws -> any TextTranslationProvider {
        switch kind {
        case .localOCR: throw ScreenTranslatorError.invalidResponse("本地 OCR 不需要远程 Provider")
        case .baiduText:
            return BaiduTextTranslator(appID:AppConfiguration.baiduAppID,secret:SecretStore.shared.read(.baiduSecret) ?? "")
        case .baiduImageCloud:
            throw ScreenTranslatorError.invalidResponse("百度图片翻译不是文本 Provider")
        case .deepL:
            return DeepLTranslator(authKey:SecretStore.shared.read(.deepLKey) ?? "")
        case .openAICompatible:
            return OpenAICompatibleTranslator(apiKey:SecretStore.shared.read(.openAIKey) ?? "",endpoint:AppConfiguration.openAIEndpoint,model:AppConfiguration.openAIModel)
        }
    }
}
