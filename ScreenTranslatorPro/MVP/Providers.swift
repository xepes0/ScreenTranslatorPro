import Foundation
import CryptoKit
import UIKit

protocol TextTranslationProvider: Sendable {
    var kind: ProviderKind { get }
    func translate(text: String, source: String, target: String) async throws -> String
}

struct BaiduTextTranslator: TextTranslationProvider {
    let kind: ProviderKind = .baiduText
    let appID: String
    let secret: String
    var requestTimeout: TimeInterval = 12
    var maxAttempts: Int = 3

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 16
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func translate(text: String, source: String, target: String) async throws -> String {
        guard !appID.isEmpty else { throw ScreenTranslatorError.missingCredential("百度 APP ID") }
        guard !secret.isEmpty else { throw ScreenTranslatorError.missingCredential("百度密钥") }

        var lastError: Error?
        let attempts = max(1, maxAttempts)
        for attempt in 0..<attempts {
            do {
                let salt = String(UInt64.random(in: 100000...999999999))
                let digest = Insecure.MD5.hash(data: Data((appID + text + salt + secret).utf8))
                let sign = digest.map { String(format: "%02x", $0) }.joined()

                var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
                request.httpMethod = "POST"
                request.timeoutInterval = requestTimeout
                request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = formBody([
                    "q": text,
                    "from": source.isEmpty ? "auto" : source,
                    "to": target,
                    "appid": appID,
                    "salt": salt,
                    "sign": sign
                ])

                let (data, response) = try await Self.session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw ScreenTranslatorError.invalidResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }

                let decoded = try JSONDecoder().decode(BaiduResponse.self, from: data)
                if let code = decoded.errorCode {
                    if (code == "54003" || code == "54005"), attempt < attempts - 1 {
                        try await Task.sleep(for: .milliseconds(450 * (attempt + 1)))
                        continue
                    }
                    throw ScreenTranslatorError.invalidResponse("百度错误 \(code)：\(decoded.errorMsg ?? "unknown")")
                }

                let output = decoded.transResult?.map(\.dst).joined(separator: "\n") ?? ""
                guard !output.isEmpty else {
                    throw ScreenTranslatorError.invalidResponse("百度返回空译文")
                }
                return output
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
                }
            }
        }

        throw lastError ?? ScreenTranslatorError.invalidResponse("百度翻译失败")
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



struct BaiduOpenPlatformImageTranslator: Sendable {
    let appID: String
    let secret: String

    func translate(image: UIImage, source: String, target: String) async throws -> UIImage {
        guard !appID.isEmpty else {
            throw ScreenTranslatorError.missingCredential("百度 APP ID")
        }
        guard !secret.isEmpty else {
            throw ScreenTranslatorError.missingCredential("百度 Key")
        }

        let imageData = try Self.preparedJPEG(from: image)
        let salt = String(UInt64.random(in: 100000...999999999))
        let cuid = "APICUID"
        let mac = "mac"
        let imageMD5 = Self.md5Hex(imageData)
        let signSource = appID + imageMD5 + salt + cuid + mac + secret
        let sign = Self.md5Hex(Data(signSource.utf8))

        var components = URLComponents(string: "https://fanyi-api.baidu.com/api/trans/sdk/picture")!
        components.queryItems = [
            URLQueryItem(name: "from", value: Self.baiduLanguage(source, allowAuto: true)),
            URLQueryItem(name: "to", value: Self.baiduLanguage(target, allowAuto: false)),
            URLQueryItem(name: "appid", value: appID),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "cuid", value: cuid),
            URLQueryItem(name: "mac", value: mac),
            URLQueryItem(name: "version", value: "3")
        ]

        guard let url = components.url else {
            throw ScreenTranslatorError.invalidResponse("百度图片翻译 URL 无效")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"image\"; filename=\"screenshot.jpg\"\r\n")
        body.appendUTF8("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw ScreenTranslatorError.invalidResponse(
                "百度图片翻译 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScreenTranslatorError.invalidResponse("百度图片翻译返回非 JSON")
        }

        let errorCode = String(describing: root["error_code"] ?? "0")
        if errorCode != "0" {
            let message = String(describing: root["error_msg"] ?? "unknown")
            throw ScreenTranslatorError.invalidResponse(
                "百度图片翻译错误 \(errorCode)：\(message)"
            )
        }

        // V1 官方响应：content / sumSrc / sumDst / pasteImg 都位于根节点。
        let content = root["content"] as? [[String: Any]] ?? []
        let sumSrc = (root["sumSrc"] as? String) ?? ""
        let sumDst = (root["sumDst"] as? String) ?? ""

        let hasChangedContent = content.contains { item in
            let src = ((item["src"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let dst = ((item["dst"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !dst.isEmpty && dst != src
        }

        let hasChangedSummary =
            !sumDst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            sumDst.trimmingCharacters(in: .whitespacesAndNewlines) !=
            sumSrc.trimmingCharacters(in: .whitespacesAndNewlines)

        let didTranslate = hasChangedContent || hasChangedSummary

        var pasteBase64 = root["pasteImg"] as? String
        if pasteBase64 == nil {
            pasteBase64 = content
                .compactMap { $0["pasteImg"] as? String }
                .first(where: { !$0.isEmpty })
        }

        if didTranslate,
           let pasteBase64,
           let pasteData = Self.decodeBase64Image(pasteBase64),
           let output = UIImage(data: pasteData) {
            return output
        }

        // 百度有译文但没返回可用贴合图时，直接用它的 dst + rect 本机回填。
        let fallbackItems = Self.fallbackItems(from: content, imageSize: image.size)
        if didTranslate && !fallbackItems.isEmpty {
            return OverlayRenderer().render(
                original: image,
                items: fallbackItems
            )
        }

        // 最后一层兜底：本机 Vision OCR + 同一 APP ID/Key 的百度文本翻译。
        // 这样即使图片接口没有生成贴合图，仍然能得到可见译文。
        do {
            return try await localOCRTextFallback(
                image: image,
                source: source,
                target: target
            )
        } catch {
            let keys = Array(root.keys).sorted().joined(separator: ",")
            throw ScreenTranslatorError.invalidResponse(
                "图片接口未产生有效译文；from=\(root["from"] ?? "?") to=\(root["to"] ?? "?") keys=\(keys)；文本兜底也失败：\(error.localizedDescription)"
            )
        }
    }

    private func localOCRTextFallback(
        image: UIImage,
        source: String,
        target: String
    ) async throws -> UIImage {
        let ocrItems = try await VisionOCRManager().recognize(
            image: image,
            sourceLanguage: source
        )
        guard !ocrItems.isEmpty else {
            throw ScreenTranslatorError.noTextFound
        }

        let translator = BaiduTextTranslator(appID: appID, secret: secret)
        var translated: [OCRResult] = []
        translated.reserveCapacity(ocrItems.count)

        for (index, item) in ocrItems.enumerated() {
            var copy = item
            copy.translation = try await translator.translate(
                text: item.text,
                source: source,
                target: target
            )
            translated.append(copy)

            if index < ocrItems.count - 1 {
                try await Task.sleep(for: .milliseconds(1050))
            }
        }

        return OverlayRenderer().render(
            original: image,
            items: translated
        )
    }

    private static func decodeBase64Image(_ value: String) -> Data? {
        let raw: String
        if let comma = value.firstIndex(of: ","),
           value[..<comma].contains("base64") {
            raw = String(value[value.index(after: comma)...])
        } else {
            raw = value
        }
        return Data(base64Encoded: raw, options: .ignoreUnknownCharacters)
    }

    private static func fallbackItems(
        from content: [[String: Any]],
        imageSize: CGSize
    ) -> [OCRResult] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }

        return content.compactMap { item in
            guard
                let dst = item["dst"] as? String,
                !dst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let rectString = item["rect"] as? String
            else { return nil }

            let numbers = rectString
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }

            guard numbers.count >= 4 else { return nil }

            let left = CGFloat(numbers[0])
            let top = CGFloat(numbers[1])
            let width = CGFloat(numbers[2])
            let height = CGFloat(numbers[3])

            guard width > 0, height > 0 else { return nil }

            let visionRect = CGRect(
                x: left / imageSize.width,
                y: 1 - ((top + height) / imageSize.height),
                width: width / imageSize.width,
                height: height / imageSize.height
            )

            return OCRResult(
                text: (item["src"] as? String) ?? "",
                boundingBox: visionRect,
                confidence: 1,
                translation: dst
            )
        }
    }

    private static func md5Hex(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func preparedJPEG(from image: UIImage) throws -> Data {
        var current = image
        let maxDimension: CGFloat = 4096
        let longest = max(current.size.width, current.size.height)

        if longest > maxDimension {
            let scale = maxDimension / longest
            let targetSize = CGSize(
                width: current.size.width * scale,
                height: current.size.height * scale
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            current = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                current.draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }

        for quality in stride(from: 0.92, through: 0.45, by: -0.08) {
            if let data = current.jpegData(compressionQuality: quality),
               data.count < 3_900_000 {
                return data
            }
        }

        throw ScreenTranslatorError.invalidResponse(
            "图片压缩后仍超过百度 4MB 限制"
        )
    }

    private static func baiduLanguage(
        _ code: String,
        allowAuto: Bool
    ) -> String {
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

private actor TranslationMemory {
    static let shared = TranslationMemory()

    private struct Snapshot: Codable {
        var values: [String: String]
        var order: [String]
    }

    private var values: [String: String]
    private var order: [String]
    private let maxEntries = 1_200
    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        let directory = base.appendingPathComponent(
            "ScreenTranslatorPro",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("translation-memory-v1.json")
    }

    init() {
        if
            let data = try? Data(contentsOf: Self.fileURL),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        {
            values = snapshot.values
            order = snapshot.order.filter { snapshot.values[$0] != nil }
        } else {
            values = [:]
            order = []
        }
    }

    func value(for key: String) -> String? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func store(_ value: String, for key: String) {
        values[key] = value
        touch(key)

        while order.count > maxEntries {
            let oldest = order.removeFirst()
            values.removeValue(forKey: oldest)
        }

        scheduleSave()
    }

    func clear() {
        saveTask?.cancel()
        saveTask = nil
        values.removeAll()
        order.removeAll()
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    private func flush() {
        let snapshot = Snapshot(values: values, order: order)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}

enum TranslationDataStore {
    static func clearCache() async {
        await TranslationMemory.shared.clear()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenTranslatorPro", isDirectory: true)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("latest-translated.png"))
    }
}

private enum TranslationGuard {
    struct ProtectedText: Sendable {
        let source: String
        let masked: String
        let replacements: [String: String]

        var hasProtectedContent: Bool {
            !replacements.isEmpty
        }

        func restore(_ translated: String) -> String {
            var output = translated

            for (placeholder, original) in replacements {
                if let range = output.range(
                    of: placeholder,
                    options: [.caseInsensitive]
                ) {
                    output.replaceSubrange(range, with: original)
                    continue
                }

                // 少数翻译服务可能在占位符周围插入空格。
                // 再做一次忽略空白的宽松恢复。
                let compactPlaceholder = placeholder.replacingOccurrences(
                    of: " ",
                    with: ""
                )

                var compactIndexMap: [String.Index] = []
                var compact = ""
                var index = output.startIndex

                while index < output.endIndex {
                    if !output[index].isWhitespace {
                        compactIndexMap.append(index)
                        compact.append(output[index])
                    }
                    index = output.index(after: index)
                }

                if let compactRange = compact.range(
                    of: compactPlaceholder,
                    options: [.caseInsensitive]
                ) {
                    let lowerOffset = compact.distance(
                        from: compact.startIndex,
                        to: compactRange.lowerBound
                    )
                    let upperOffset = compact.distance(
                        from: compact.startIndex,
                        to: compactRange.upperBound
                    )

                    if lowerOffset < compactIndexMap.count,
                       upperOffset > 0,
                       upperOffset - 1 < compactIndexMap.count {
                        let lower = compactIndexMap[lowerOffset]
                        let last = compactIndexMap[upperOffset - 1]
                        let upper = output.index(after: last)
                        output.replaceSubrange(lower..<upper, with: original)
                    }
                }
            }

            return output
        }
    }

    private static let technicalAcronyms: Set<String> = [
        "AI", "API", "ASCII", "CJK", "CPU", "DNS", "GPU", "HTTP", "HTTPS",
        "ID", "IP", "JSON", "NFC", "OCR", "RAM", "RGB", "SIM", "SFTP", "SSH",
        "TCP", "TLS", "UDP", "UI", "URL", "USB", "UUID", "VPN", "WiFi", "XML"
    ]

    private static let inlineTechnicalRegexes: [NSRegularExpression] = {
        let patterns = [
            // URL（含 path / query / fragment）
            "https?://[^\\s<>\\\"'’”]+",
            "www\\.[A-Za-z0-9.-]+(?:/[^\\s<>\\\"'’”]*)?",
            // Email
            "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
            // IPv4 + optional port
            "(?<![A-Za-z0-9])(?:\\d{1,3}\\.){3}\\d{1,3}(?::\\d{1,5})?(?![A-Za-z0-9])",
            // IPv6-ish token
            "(?<![A-Za-z0-9])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,}(?![A-Za-z0-9])",
            // Domain / host + optional path
            "(?<![A-Za-z0-9_-])(?:[A-Za-z0-9-]+\\.)+[A-Za-z]{2,}(?:/[A-Za-z0-9._~:/?#@!$&()*+,;=%-]*)?",
            // Unix / home path
            "(?<![A-Za-z0-9])(?:~?/)(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+",
            // Windows path
            "(?<![A-Za-z0-9])[A-Za-z]:[\\\\/](?:[^\\s<>:|?*]+[\\\\/]?)+",
            // Version / hex
            "(?<![A-Za-z0-9])[vV]?\\d+(?:\\.\\d+){1,4}(?:[-+][A-Za-z0-9._-]+)?(?![A-Za-z0-9])",
            "(?<![A-Za-z0-9])0x[0-9A-Fa-f]+(?![A-Za-z0-9])",
            // CLI flags: -p / --port
            "(?<![A-Za-z0-9])--?[A-Za-z][A-Za-z0-9-]*(?![A-Za-z0-9])",
            // Technical tokens containing digits: xterm-256color / arm64-v8a
            "(?<![A-Za-z0-9])(?=[A-Za-z0-9._-]*\\d)[A-Za-z][A-Za-z0-9._-]{2,}(?![A-Za-z0-9])"
        ]

        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0)
        }
    }()

    private static let acronymRegex: NSRegularExpression = {
        let body = technicalAcronyms
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")

        return try! NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])(?:" + body + ")(?![A-Za-z0-9])",
            options: [.caseInsensitive]
        )
    }()

    private static func isWindowsPath(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 3 else { return false }

        return CharacterSet.letters.contains(scalars[0]) &&
            scalars[1].value == 58 &&
            (scalars[2].value == 92 || scalars[2].value == 47)
    }

    static func shouldPreserve(_ item: OCRResult) -> Bool {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        // iPhone 状态栏。
        if item.boundingBox.midY > 0.962 {
            return true
        }

        // 没有字母的纯数字、时间、百分比、符号。
        if text.rangeOfCharacter(from: .letters) == nil {
            return true
        }

        if text == "Aa" || text == "AA" || text == "aA" {
            return true
        }

        let compact = text.replacingOccurrences(of: " ", with: "")
        if technicalAcronyms.contains(compact) {
            return true
        }

        // 短大写缩写：SSH / CJK / CPU / ID 等。
        if compact.count >= 2,
           compact.count <= 5,
           compact.unicodeScalars.allSatisfy({
               CharacterSet.uppercaseLetters.contains($0) ||
               CharacterSet.decimalDigits.contains($0)
           }) {
            return true
        }

        // 整行就是 URL / 邮箱 / 路径 / host 时直接保留。
        if !text.contains(" "),
           (
               text.hasPrefix("http://") ||
               text.hasPrefix("https://") ||
               text.hasPrefix("www.") ||
               text.contains("@") ||
               text.hasPrefix("/") ||
               text.hasPrefix("~/") ||
               isWindowsPath(text) ||
               text.range(
                   of: "^[A-Za-z][A-Za-z0-9_-]*(\\.[A-Za-z0-9_-]+){2,}$",
                   options: .regularExpression
               ) != nil
           ) {
            return true
        }

        // IPv4 / IPv6 / MAC / 端口形式。
        if text.range(
            of: "^(?:\\d{1,3}\\.){3}\\d{1,3}(?::\\d{1,5})?$",
            options: .regularExpression
        ) != nil ||
        (text.contains(":") &&
         text.range(
            of: "^[0-9A-Fa-f:]+$",
            options: .regularExpression
         ) != nil) {
            return true
        }

        // 版本号、十六进制、技术型单 token。
        if text.range(
            of: "^[vV]?\\d+(?:\\.\\d+){1,4}(?:[-+][A-Za-z0-9._-]+)?$",
            options: .regularExpression
        ) != nil ||
        text.range(
            of: "^0x[0-9A-Fa-f]+$",
            options: .regularExpression
        ) != nil {
            return true
        }

        if !text.contains(" "),
           text.rangeOfCharacter(from: .decimalDigits) != nil,
           text.rangeOfCharacter(
               from: CharacterSet(charactersIn: "-_./:")
           ) != nil {
            return true
        }

        // Shell / code 行整体不翻译。
        if looksLikeShellCommand(text) ||
           text.contains("::") ||
           text.contains("->") ||
           text.contains("=>") {
            return true
        }

        return false
    }

    static func protectInlineTechnicalContent(_ text: String) -> ProtectedText {
        guard !text.isEmpty else {
            return ProtectedText(
                source: text,
                masked: text,
                replacements: [:]
            )
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var candidateRanges: [NSRange] = []

        for regex in inlineTechnicalRegexes {
            candidateRanges.append(
                contentsOf: regex.matches(
                    in: text,
                    range: fullRange
                ).map(\.range)
            )
        }

        candidateRanges.append(
            contentsOf: acronymRegex.matches(
                in: text,
                range: fullRange
            ).map(\.range)
        )

        // 长匹配优先，并去掉重叠范围，例如 URL 内部的域名不重复保护。
        let sorted = candidateRanges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted {
                if $0.length != $1.length {
                    return $0.length > $1.length
                }
                return $0.location < $1.location
            }

        var selected: [NSRange] = []

        for range in sorted {
            let overlaps = selected.contains {
                NSIntersectionRange($0, range).length > 0
            }
            if !overlaps {
                selected.append(range)
            }
        }

        selected.sort { $0.location < $1.location }

        guard !selected.isEmpty else {
            return ProtectedText(
                source: text,
                masked: text,
                replacements: [:]
            )
        }

        var masked = text
        var replacements: [String: String] = [:]

        // 倒序替换，保证 UTF-16 range 不受前面替换影响。
        for (index, range) in selected.enumerated().reversed() {
            guard let swiftRange = Range(range, in: masked) else {
                continue
            }

            let original = String(masked[swiftRange])
            let placeholder = "ZXQSTP" + String(index) + "QXZ"
            replacements[placeholder] = original
            masked.replaceSubrange(swiftRange, with: placeholder)
        }

        return ProtectedText(
            source: text,
            masked: masked,
            replacements: replacements
        )
    }

    private static func looksLikeShellCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$ ") || trimmed.hasPrefix("# ") {
            return true
        }

        let first = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .first?
            .lowercased() ?? ""

        let commands: Set<String> = [
            "awk", "bash", "brew", "cat", "cd", "chmod", "chown",
            "cp", "curl", "git", "grep", "head", "ls", "mv", "nc",
            "node", "npm", "ping", "python", "python3", "rm", "rsync",
            "scp", "sed", "sftp", "ssh", "sudo", "tail", "tar",
            "wget", "zsh"
        ]

        return commands.contains(first)
    }
}

final class TranslationService: Sendable {
    func translate(_ items: [OCRResult], source: String, target: String) async throws -> [OCRResult] {
        guard !items.isEmpty else { throw ScreenTranslatorError.noTextFound }

        let kind = AppConfiguration.provider
        if kind == .localOCR {
            return items.map {
                var copy = $0
                copy.translation = $0.text
                return copy
            }
        }

        if kind == .baiduImageOpen {
            throw ScreenTranslatorError.invalidResponse("百度图片翻译应走整图翻译流程")
        }

        let provider = try makeProvider(kind)

        var output = Array<OCRResult?>(repeating: nil, count: items.count)
        var pending: [(
            offset: Int,
            element: OCRResult,
            protected: TranslationGuard.ProtectedText,
            key: String
        )] = []
        pending.reserveCapacity(items.count)

        // 先做保护和持久缓存命中。重复页面通常只剩 OCR + 渲染，
        // 不再重复等待远端 API。
        for (index, item) in items.enumerated() {
            if TranslationGuard.shouldPreserve(item) {
                var copy = item
                copy.translation = item.text
                output[index] = copy
                continue
            }

            let key = cacheKey(
                kind: kind,
                source: source,
                target: target,
                text: item.text
            )

            if let cached = await TranslationMemory.shared.value(for: key) {
                var copy = item
                copy.translation = cached
                output[index] = copy
                continue
            }

            pending.append((
                index,
                item,
                TranslationGuard.protectInlineTechnicalContent(item.text),
                key
            ))
        }

        guard !pending.isEmpty else {
            return output.compactMap { $0 }
        }

        // 百度快速模式优先一次批量请求；失败或返回行数不一致时，
        // 自动降级到下面的逐项并发，不中断整张截图。
        if kind == .baiduFast,
           let baidu = provider as? BaiduTextTranslator {
            let joined = pending.map { $0.protected.masked }.joined(separator: "\n")

            if joined.utf8.count <= 5_500 {
                do {
                    let batch = try await baidu.translate(
                        text: joined,
                        source: source,
                        target: target
                    )
                    let lines = batch.split(
                        separator: "\n",
                        omittingEmptySubsequences: false
                    ).map(String.init)

                    if lines.count == pending.count {
                        for (entry, value) in zip(pending, lines) {
                            let restored = entry.protected.restore(value)
                            var copy = entry.element
                            copy.translation = restored
                            output[entry.offset] = copy
                            await TranslationMemory.shared.store(
                                restored,
                                for: entry.key
                            )
                        }
                        return output.compactMap { $0 }
                    }
                } catch {
                    print("[STP] fast batch failed, falling back per item: \(error)")
                }
            }
        }

        if kind == .baiduText {
            for (position, entry) in pending.enumerated() {
                do {
                    output[entry.offset] = try await translateOne(
                        entry.element,
                        provider: provider,
                        kind: kind,
                        source: source,
                        target: target
                    )
                } catch {
                    if isFatal(error) { throw error }
                    output[entry.offset] = untranslated(entry.element)
                    print("[STP] item translation skipped after error: \(error)")
                }

                if position < pending.count - 1 {
                    try await Task.sleep(for: .milliseconds(1050))
                }
            }
            return output.compactMap { $0 }
        }

        // 其它快速 Provider 最多 4 项并发。
        // 单项失败只保留该项原文，其余翻译继续完成。
        let chunkSize = 4

        for chunkStart in stride(from: 0, to: pending.count, by: chunkSize) {
            let end = min(chunkStart + chunkSize, pending.count)
            let chunk = Array(pending[chunkStart..<end])

            await withTaskGroup(of: (Int, OCRResult).self) { group in
                for entry in chunk {
                    group.addTask {
                        do {
                            let result = try await self.translateOne(
                                entry.element,
                                provider: provider,
                                kind: kind,
                                source: source,
                                target: target
                            )
                            return (entry.offset, result)
                        } catch {
                            print("[STP] item translation failed, preserving source: \(error)")
                            return (entry.offset, self.untranslated(entry.element))
                        }
                    }
                }

                for await (index, result) in group {
                    output[index] = result
                }
            }
        }

        return output.compactMap { $0 }
    }

    private func translateOne(
        _ item: OCRResult,
        provider: any TextTranslationProvider,
        kind: ProviderKind,
        source: String,
        target: String
    ) async throws -> OCRResult {
        let key = cacheKey(
            kind: kind,
            source: source,
            target: target,
            text: item.text
        )

        if let cached = await TranslationMemory.shared.value(for: key) {
            var copy = item
            copy.translation = cached
            return copy
        }

        let protected = TranslationGuard.protectInlineTechnicalContent(item.text)
        let translated = try await provider.translate(
            text: protected.masked,
            source: source,
            target: target
        )
        let value = protected.restore(translated)
        await TranslationMemory.shared.store(value, for: key)

        var copy = item
        copy.translation = value
        return copy
    }

    private func cacheKey(
        kind: ProviderKind,
        source: String,
        target: String,
        text: String
    ) -> String {
        [kind.rawValue, source, target, text].joined(separator: "\u{001F}")
    }

    private func untranslated(_ item: OCRResult) -> OCRResult {
        var copy = item
        copy.translation = item.text
        return copy
    }

    private func isFatal(_ error: Error) -> Bool {
        guard let value = error as? ScreenTranslatorError else { return false }
        if case .missingCredential = value { return true }
        return false
    }

    private func makeProvider(_ kind: ProviderKind) throws -> any TextTranslationProvider {
        switch kind {
        case .localOCR:
            throw ScreenTranslatorError.invalidResponse("本地 OCR 不需要远程 Provider")

        case .baiduFast:
            return BaiduTextTranslator(
                appID: AppConfiguration.baiduAppID,
                secret: SecretStore.shared.read(.baiduSecret) ?? "",
                requestTimeout: 7,
                maxAttempts: 2
            )

        case .baiduText:
            return BaiduTextTranslator(
                appID: AppConfiguration.baiduAppID,
                secret: SecretStore.shared.read(.baiduSecret) ?? "",
                requestTimeout: 12,
                maxAttempts: 3
            )

        case .baiduImageOpen:
            throw ScreenTranslatorError.invalidResponse("百度图片翻译不是文本 Provider")

        case .deepL:
            return DeepLTranslator(
                authKey: SecretStore.shared.read(.deepLKey) ?? ""
            )

        case .openAICompatible:
            return OpenAICompatibleTranslator(
                apiKey: SecretStore.shared.read(.openAIKey) ?? "",
                endpoint: AppConfiguration.openAIEndpoint,
                model: AppConfiguration.openAIModel
            )
        }
    }
}
