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

    func translate(text: String, source: String, target: String) async throws -> String {
        guard !appID.isEmpty else { throw ScreenTranslatorError.missingCredential("百度 APP ID") }
        guard !secret.isEmpty else { throw ScreenTranslatorError.missingCredential("百度密钥") }

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let salt = String(UInt64.random(in: 100000...999999999))
                let digest = Insecure.MD5.hash(data: Data((appID + text + salt + secret).utf8))
                let sign = digest.map { String(format: "%02x", $0) }.joined()

                var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 12
                request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = formBody([
                    "q": text,
                    "from": source.isEmpty ? "auto" : source,
                    "to": target,
                    "appid": appID,
                    "salt": salt,
                    "sign": sign
                ])

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw ScreenTranslatorError.invalidResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }

                let decoded = try JSONDecoder().decode(BaiduResponse.self, from: data)
                if let code = decoded.errorCode {
                    if (code == "54003" || code == "54005"), attempt < 2 {
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
                if attempt < 2 {
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

    private var values: [String: String] = [:]
    private let maxEntries = 500

    func value(for key: String) -> String? {
        values[key]
    }

    func store(_ value: String, for key: String) {
        if values.count >= maxEntries, let first = values.keys.first {
            values.removeValue(forKey: first)
        }
        values[key] = value
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

        if kind == .baiduFast,
           let baidu = provider as? BaiduTextTranslator {
            let joined = items.map(\.text).joined(separator: "\n")

            // 大多数屏幕文字一次请求即可完成，网络往返从 N 次降到 1 次。
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

                    if lines.count == items.count {
                        return zip(items, lines).map { item, value in
                            var copy = item
                            copy.translation = value
                            return copy
                        }
                    }
                } catch {
                    // 批量失败时自动回退到下面的并发逐条翻译。
                }
            }
        }

        if kind == .baiduText {
            var output: [OCRResult] = []
            output.reserveCapacity(items.count)

            for (index, item) in items.enumerated() {
                output.append(try await translateOne(
                    item,
                    provider: provider,
                    kind: kind,
                    source: source,
                    target: target
                ))

                if index < items.count - 1 {
                    try await Task.sleep(for: .milliseconds(1050))
                }
            }
            return output
        }

        // 快速模式允许最多 4 条并发；如果账号触发百度频控，
        // BaiduTextTranslator 会自动短暂退避并重试。
        var translated = Array<OCRResult?>(repeating: nil, count: items.count)
        let indexed = Array(items.enumerated())
        let chunkSize = kind == .baiduFast ? 4 : 4

        for chunkStart in stride(from: 0, to: indexed.count, by: chunkSize) {
            let end = min(chunkStart + chunkSize, indexed.count)
            let chunk = Array(indexed[chunkStart..<end])

            try await withThrowingTaskGroup(of: (Int, OCRResult).self) { group in
                for (index, item) in chunk {
                    group.addTask {
                        let result = try await self.translateOne(
                            item,
                            provider: provider,
                            kind: kind,
                            source: source,
                            target: target
                        )
                        return (index, result)
                    }
                }

                for try await (index, result) in group {
                    translated[index] = result
                }
            }
        }

        return translated.compactMap { $0 }
    }

    private func translateOne(
        _ item: OCRResult,
        provider: any TextTranslationProvider,
        kind: ProviderKind,
        source: String,
        target: String
    ) async throws -> OCRResult {
        let key = [kind.rawValue, source, target, item.text].joined(separator: "\u{001F}")

        if let cached = await TranslationMemory.shared.value(for: key) {
            var copy = item
            copy.translation = cached
            return copy
        }

        let value = try await provider.translate(
            text: item.text,
            source: source,
            target: target
        )
        await TranslationMemory.shared.store(value, for: key)

        var copy = item
        copy.translation = value
        return copy
    }

    private func makeProvider(_ kind: ProviderKind) throws -> any TextTranslationProvider {
        switch kind {
        case .localOCR:
            throw ScreenTranslatorError.invalidResponse("本地 OCR 不需要远程 Provider")

        case .baiduFast, .baiduText:
            return BaiduTextTranslator(
                appID: AppConfiguration.baiduAppID,
                secret: SecretStore.shared.read(.baiduSecret) ?? ""
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
