import Foundation
import Vision
import UIKit
import ImageIO
import CoreImage
import Security

struct OCRResult: Identifiable, Sendable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let confidence: Float
    var translation: String

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, confidence: Float, translation: String = "") {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.translation = translation
    }
}

enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case localOCR, baiduText, baiduImageOpen, deepL, openAICompatible
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .localOCR: return "本地 OCR（不翻译）"
        case .baiduText: return "百度通用文本翻译"
        case .baiduImageOpen: return "百度图片翻译（APP ID + Key）"
        case .deepL: return "DeepL"
        case .openAICompatible: return "OpenAI-Compatible"
        }
    }
}

enum ScreenTranslatorError: LocalizedError {
    case invalidImage, noTextFound
    case missingCredential(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取图片。"
        case .noTextFound: return "截图中没有识别到文字。"
        case .missingCredential(let value): return "缺少配置：\(value)"
        case .invalidResponse(let value): return "翻译服务返回异常：\(value)"
        }
    }
}

enum AppConfiguration {
    static let providerKey = "provider"
    static let sourceLanguageKey = "sourceLanguage"
    static let targetLanguageKey = "targetLanguage"
    static let baiduAppIDKey = "baiduAppID"
    static let openAIEndpointKey = "openAIEndpoint"
    static let openAIModelKey = "openAIModel"

    static var provider: ProviderKind {
        ProviderKind(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .localOCR
    }
    static var sourceLanguage: String { UserDefaults.standard.string(forKey: sourceLanguageKey) ?? "auto" }
    static var targetLanguage: String { UserDefaults.standard.string(forKey: targetLanguageKey) ?? "zh" }
    static var baiduAppID: String { UserDefaults.standard.string(forKey: baiduAppIDKey) ?? "" }
    static var openAIEndpoint: String {
        UserDefaults.standard.string(forKey: openAIEndpointKey) ?? "https://api.openai.com/v1/chat/completions"
    }
    static var openAIModel: String { UserDefaults.standard.string(forKey: openAIModelKey) ?? "gpt-4.1-mini" }
}

enum SecretKey: String {
    case baiduSecret
    case baiduCloudAPIKey
    case baiduCloudSecretKey
    case deepLKey
    case openAIKey
}

final class SecretStore: @unchecked Sendable {
    static let shared = SecretStore()
    private let service = "com.xepes.ScreenTranslatorPro"

    func write(_ value: String, for key: SecretKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func read(_ key: SecretKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class VisionOCRManager {
    func recognize(image: UIImage, sourceLanguage: String = "auto") async throws -> [OCRResult] {
        guard let cgImage = image.cgImage else { throw ScreenTranslatorError.invalidImage }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let values = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { observation -> OCRResult? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return OCRResult(text: text, boundingBox: observation.boundingBox, confidence: candidate.confidence)
                }.sorted {
                    let rowDelta = abs($0.boundingBox.midY - $1.boundingBox.midY)
                    return rowDelta > 0.03 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
                }
                continuation.resume(returning: values)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.008
            if let lang = Self.visionLanguage(for: sourceLanguage) { request.recognitionLanguages = [lang] }
            do {
                try VNImageRequestHandler(
                    cgImage: cgImage,
                    orientation: CGImagePropertyOrientation(image.imageOrientation),
                    options: [:]
                ).perform([request])
            } catch { continuation.resume(throwing: error) }
        }
    }

    private static func visionLanguage(for code: String) -> String? {
        switch code.lowercased() {
        case "zh", "zh-cn": return "zh-Hans"
        case "cht", "zh-tw": return "zh-Hant"
        case "en": return "en-US"
        case "jp", "ja": return "ja-JP"
        case "kor", "ko": return "ko-KR"
        case "fr", "fra": return "fr-FR"
        case "de": return "de-DE"
        case "es", "spa": return "es-ES"
        default: return nil
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

final class OverlayRenderer {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func render(original: UIImage, items: [OCRResult]) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = original.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: original.size, format: format).image { context in
            original.draw(in: CGRect(origin: .zero, size: original.size))
            for item in items where !item.translation.isEmpty {
                let rect = CGRect(
                    x: item.boundingBox.minX * original.size.width,
                    y: (1 - item.boundingBox.maxY) * original.size.height,
                    width: item.boundingBox.width * original.size.width,
                    height: item.boundingBox.height * original.size.height
                )
                guard rect.width > 4, rect.height > 4 else { continue }
                let expanded = rect.insetBy(dx: -2, dy: -1)
                let bg = averageColor(in: original, rect: expanded) ?? .systemBackground
                let fg: UIColor = bg.isDark ? .white : .black
                context.cgContext.setFillColor(bg.withAlphaComponent(0.94).cgColor)
                context.cgContext.addPath(UIBezierPath(roundedRect: expanded, cornerRadius: max(2, expanded.height * 0.08)).cgPath)
                context.cgContext.fillPath()

                let font = fittingFont(item.translation, rect)
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byWordWrapping
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg, .paragraphStyle: paragraph]
                let string = NSAttributedString(string: item.translation, attributes: attrs)
                let measured = string.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                let drawRect = CGRect(x: rect.minX, y: rect.midY - min(rect.height, measured.height)/2, width: rect.width, height: min(rect.height, measured.height))
                string.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
        }
    }

    private func fittingFont(_ text: String, _ rect: CGRect) -> UIFont {
        var low: CGFloat = 7, high: CGFloat = max(9, rect.height * 1.25)
        while high - low > 0.5 {
            let mid = (low + high) / 2
            let font = UIFont.systemFont(ofSize: mid, weight: .medium)
            let bounds = (text as NSString).boundingRect(
                with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil
            )
            if bounds.width <= rect.width && bounds.height <= rect.height { low = mid } else { high = mid }
        }
        return .systemFont(ofSize: low, weight: .medium)
    }

    private func averageColor(in image: UIImage, rect: CGRect) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let sx = CGFloat(cg.width) / image.size.width
        let sy = CGFloat(cg.height) / image.size.height
        let bounds = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let crop = CGRect(x: rect.minX*sx, y: (image.size.height-rect.maxY)*sy, width: rect.width*sx, height: rect.height*sy)
            .intersection(bounds).integral
        guard !crop.isNull, crop.width >= 1, crop.height >= 1 else { return nil }
        let input = CIImage(cgImage: cg).cropped(to: crop)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return UIColor(red: CGFloat(rgba[0])/255, green: CGFloat(rgba[1])/255, blue: CGFloat(rgba[2])/255, alpha: 1)
    }
}

private extension UIColor {
    var isDark: Bool {
        var r: CGFloat=0, g: CGFloat=0, b: CGFloat=0, a: CGFloat=0
        guard getRed(&r, green:&g, blue:&b, alpha:&a) else { return false }
        return (0.2126*r + 0.7152*g + 0.0722*b) < 0.52
    }
}

struct ScreenTranslationResult { let image: UIImage; let items: [OCRResult] }

final class ScreenTranslationEngine {
    private let ocr = VisionOCRManager()
    private let service = TranslationService()
    private let renderer = OverlayRenderer()

    func process(image: UIImage) async throws -> ScreenTranslationResult {
        let source = AppConfiguration.sourceLanguage
        let target = AppConfiguration.targetLanguage

        if AppConfiguration.provider == .baiduImageOpen {
            let provider = BaiduOpenPlatformImageTranslator(
                appID: AppConfiguration.baiduAppID,
                secret: SecretStore.shared.read(.baiduSecret) ?? ""
            )
            let output = try await provider.translate(image: image, source: source, target: target)
            return ScreenTranslationResult(image: output, items: [])
        }

        let found = try await ocr.recognize(image: image, sourceLanguage: source)
        guard !found.isEmpty else { throw ScreenTranslatorError.noTextFound }
        let translated = try await service.translate(found, source: source, target: target)
        return ScreenTranslationResult(image: renderer.render(original: image, items: translated), items: translated)
    }
}


extension Notification.Name {
    static let translatedPreviewReady = Notification.Name("ScreenTranslatorPro.translatedPreviewReady")
}

enum PreviewStore {
    private static let pendingKey = "translatedPreviewPending"

    private static var fileURL: URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenTranslatorPro", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("latest-translated.png")
    }

    static func save(_ image: UIImage) throws {
        guard let data = image.pngData() else {
            throw ScreenTranslatorError.invalidImage
        }
        try data.write(to: fileURL, options: .atomic)
        UserDefaults.standard.set(true, forKey: pendingKey)
        NotificationCenter.default.post(name: .translatedPreviewReady, object: nil)
    }

    static func loadPendingImage() -> UIImage? {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    static func markPresented() {
        UserDefaults.standard.set(false, forKey: pendingKey)
    }

    static func clear() {
        UserDefaults.standard.set(false, forKey: pendingKey)
        try? FileManager.default.removeItem(at: fileURL)
    }
}
