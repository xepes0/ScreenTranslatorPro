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

final class TranslationService: Sendable {
    func translate(_ items:[OCRResult], source:String, target:String) async throws -> [OCRResult] {
        guard !items.isEmpty else { throw ScreenTranslatorError.noTextFound }
        let kind=AppConfiguration.provider
        if kind == .localOCR {
            return items.map { var copy=$0; copy.translation=$0.text; return copy }
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
        case .deepL:
            return DeepLTranslator(authKey:SecretStore.shared.read(.deepLKey) ?? "")
        case .openAICompatible:
            return OpenAICompatibleTranslator(apiKey:SecretStore.shared.read(.openAIKey) ?? "",endpoint:AppConfiguration.openAIEndpoint,model:AppConfiguration.openAIModel)
        }
    }
}
