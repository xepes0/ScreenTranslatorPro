import Foundation
import Vision
import UIKit
import ImageIO
import CoreImage
import Security
import ObjectiveC.runtime
import Darwin

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
    case localOCR, baiduFast, baiduText, baiduImageOpen, deepL, openAICompatible
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .localOCR: return "本地 OCR（不翻译）"
        case .baiduFast: return "百度快速翻译（推荐）"
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
    func recognize(image: UIImage, sourceLanguage: String = "auto", fast: Bool = false) async throws -> [OCRResult] {
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
            request.recognitionLevel = fast ? .fast : .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = fast ? 0.0035 : 0.006
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

    private struct BackgroundEstimate {
        let center: UIColor
        let top: UIColor
        let bottom: UIColor
        let left: UIColor
        let right: UIColor
        let spread: CGFloat
    }

    func render(original: UIImage, items: [OCRResult]) -> UIImage {
        let drawable = items.compactMap { item -> (OCRResult, CGRect)? in
            let rect = imageRect(from: item.boundingBox, imageSize: original.size)
            guard rect.width > 3, rect.height > 3 else { return nil }
            guard shouldRender(item, rect: rect, imageSize: original.size) else { return nil }
            return (item, rect)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = original.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: original.size, format: format).image { rendererContext in
            original.draw(in: CGRect(origin: .zero, size: original.size))

            for (item, rect) in drawable {
                let eraseRect = expandedEraseRect(
                    for: rect,
                    imageSize: original.size
                )

                let estimate = backgroundEstimate(
                    in: original,
                    around: rect,
                    eraseRect: eraseRect
                )

                eraseBackground(
                    in: rendererContext.cgContext,
                    rect: eraseRect,
                    estimate: estimate
                )

                drawTranslation(
                    item.translation,
                    originalText: item.text,
                    in: rect,
                    eraseRect: eraseRect,
                    imageSize: original.size,
                    background: estimate.center
                )
            }
        }
    }

    private func shouldRender(
        _ item: OCRResult,
        rect: CGRect,
        imageSize: CGSize
    ) -> Bool {
        let translated = item.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { return false }

        if AppConfiguration.provider != .localOCR,
           normalized(source) == normalized(translated) {
            return false
        }

        // 状态栏里的时间、电量百分比等无需覆盖，避免出现灰色小块。
        let tinyThreshold = max(7, imageSize.height * 0.012)
        if rect.height < tinyThreshold,
           source.count <= 6,
           !containsLetterLikeCharacter(source) {
            return false
        }

        return true
    }

    private func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: " ", with: "")
    }

    private func containsLetterLikeCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar)
        }
    }

    private func imageRect(from visionRect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: visionRect.minX * imageSize.width,
            y: (1 - visionRect.maxY) * imageSize.height,
            width: visionRect.width * imageSize.width,
            height: visionRect.height * imageSize.height
        )
    }

    private func expandedEraseRect(
        for rect: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        // 横向稍多扩一点以彻底盖住抗锯齿边缘；纵向扩张更克制，
        // 避免覆盖卡片分割线、按钮边缘和邻近文字。
        let xPad = min(12, max(2.5, rect.height * 0.22))
        let yPad = min(6, max(1.5, rect.height * 0.10))

        return rect
            .insetBy(dx: -xPad, dy: -yPad)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }

    private func backgroundEstimate(
        in image: UIImage,
        around textRect: CGRect,
        eraseRect: CGRect
    ) -> BackgroundEstimate {
        let band = min(8, max(2, textRect.height * 0.20))
        let sideBand = min(8, max(2, textRect.height * 0.18))

        let topRect = CGRect(
            x: eraseRect.minX,
            y: eraseRect.minY - band,
            width: eraseRect.width,
            height: band
        )
        let bottomRect = CGRect(
            x: eraseRect.minX,
            y: eraseRect.maxY,
            width: eraseRect.width,
            height: band
        )
        let leftRect = CGRect(
            x: eraseRect.minX - sideBand,
            y: eraseRect.minY,
            width: sideBand,
            height: eraseRect.height
        )
        let rightRect = CGRect(
            x: eraseRect.maxX,
            y: eraseRect.minY,
            width: sideBand,
            height: eraseRect.height
        )

        let fallback = averageColor(in: image, rect: eraseRect) ?? .systemBackground
        let top = averageColor(in: image, rect: topRect) ?? fallback
        let bottom = averageColor(in: image, rect: bottomRect) ?? fallback
        let left = averageColor(in: image, rect: leftRect) ?? fallback
        let right = averageColor(in: image, rect: rightRect) ?? fallback

        let colors = [top, bottom, left, right]
        let center = UIColor.median(of: colors) ?? fallback
        let spread = colors
            .map { $0.distance(to: center) }
            .reduce(0, +) / CGFloat(colors.count)

        return BackgroundEstimate(
            center: center,
            top: top,
            bottom: bottom,
            left: left,
            right: right,
            spread: spread
        )
    }

    private func eraseBackground(
        in context: CGContext,
        rect: CGRect,
        estimate: BackgroundEstimate
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        let radius = min(5, max(1.5, rect.height * 0.08))
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        context.addPath(path.cgPath)
        context.clip()

        let verticalDistance = estimate.top.distance(to: estimate.bottom)
        let horizontalDistance = estimate.left.distance(to: estimate.right)

        if estimate.spread < 0.055 {
            context.setFillColor(estimate.center.cgColor)
            context.fill(rect)
            return
        }

        let startColor: UIColor
        let endColor: UIColor
        let startPoint: CGPoint
        let endPoint: CGPoint

        if verticalDistance >= horizontalDistance {
            startColor = estimate.top
            endColor = estimate.bottom
            startPoint = CGPoint(x: rect.midX, y: rect.minY)
            endPoint = CGPoint(x: rect.midX, y: rect.maxY)
        } else {
            startColor = estimate.left
            endColor = estimate.right
            startPoint = CGPoint(x: rect.minX, y: rect.midY)
            endPoint = CGPoint(x: rect.maxX, y: rect.midY)
        }

        let colors = [startColor.cgColor, endColor.cgColor] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: startPoint,
                end: endPoint,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            context.setFillColor(estimate.center.cgColor)
            context.fill(rect)
        }
    }

    private func drawTranslation(
        _ text: String,
        originalText: String,
        in originalRect: CGRect,
        eraseRect: CGRect,
        imageSize: CGSize,
        background: UIColor
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let foreground: UIColor = background.isDark ? .white : .black
        let isSingleLine = !trimmed.contains("\n") && originalRect.height < imageSize.height * 0.06

        let horizontalInset = max(1, min(3, originalRect.height * 0.07))
        let drawWidth = max(1, eraseRect.width - horizontalInset * 2)

        let font = fittingFont(
            trimmed,
            originalText: originalText,
            originalRect: originalRect,
            availableWidth: drawWidth,
            imageSize: imageSize,
            singleLine: isSingleLine
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = inferredAlignment(
            for: originalRect,
            imageSize: imageSize
        )
        paragraph.lineBreakMode = isSingleLine ? .byClipping : .byWordWrapping
        paragraph.minimumLineHeight = font.lineHeight * 0.92
        paragraph.maximumLineHeight = font.lineHeight * 1.05

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground,
            .paragraphStyle: paragraph
        ]

        let string = NSAttributedString(string: trimmed, attributes: attributes)

        if isSingleLine {
            let measured = string.boundingRect(
                with: CGSize(width: drawWidth, height: originalRect.height * 2.2),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )

            // 不再把 UIFont 的 lineHeight 强行塞进 OCR glyph box。
            // 以原文字框中心为基准绘制完整 lineHeight，视觉字号会更接近原文。
            let finalRect = CGRect(
                x: eraseRect.minX + horizontalInset,
                y: originalRect.midY - measured.height / 2,
                width: drawWidth,
                height: measured.height + 1
            )

            string.draw(
                with: finalRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            return
        }

        let drawRect = CGRect(
            x: eraseRect.minX + horizontalInset,
            y: eraseRect.minY,
            width: drawWidth,
            height: max(originalRect.height * 1.35, eraseRect.height)
        )

        let measured = string.boundingRect(
            with: drawRect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        let finalRect = CGRect(
            x: drawRect.minX,
            y: originalRect.midY - measured.height / 2,
            width: drawRect.width,
            height: measured.height + 1
        )

        string.draw(
            with: finalRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }

    private func inferredAlignment(
        for rect: CGRect,
        imageSize: CGSize
    ) -> NSTextAlignment {
        // 底部导航栏/标签通常是图标下方居中布局。
        if rect.midY > imageSize.height * 0.83,
           rect.width < imageSize.width * 0.28 {
            return .center
        }

        // 很窄、位于屏幕中轴附近的标题也倾向居中。
        if abs(rect.midX - imageSize.width / 2) < imageSize.width * 0.07,
           rect.width < imageSize.width * 0.48 {
            return .center
        }

        return .left
    }

    private func fittingFont(
        _ text: String,
        originalText: String,
        originalRect: CGRect,
        availableWidth: CGFloat,
        imageSize: CGSize,
        singleLine: Bool
    ) -> UIFont {
        let isLargeTitle = originalRect.height > imageSize.height * 0.028
        let weight: UIFont.Weight = isLargeTitle ? .semibold : .regular

        // beta15：先用“原文实际宽度”反推原字体大小，再用同样字号绘制译文。
        // 这样不会再单纯依赖 OCR 高度而把中文缩得过小。
        let sourceSize = estimatedSourceFontSize(
            originalText: originalText,
            originalRect: originalRect,
            weight: weight
        )

        let opticalBoost: CGFloat
        if isLargeTitle {
            opticalBoost = 1.06
        } else if originalRect.height < imageSize.height * 0.018 {
            // 小标签/副标题适当多放大一点，提升可读性。
            opticalBoost = 1.10
        } else {
            opticalBoost = 1.075
        }

        var preferred = sourceSize * opticalBoost

        // OCR 偶尔给出偏窄的源文字框；用高度给一个合理下限，
        // 但不再像旧版那样把字号硬限制在 OCR 高度附近。
        let heightFloor = originalRect.height * (isLargeTitle ? 1.22 : 1.16)
        preferred = max(preferred, heightFloor)

        // 防止异常 OCR 框把字号推得过大。
        let heightCeiling = originalRect.height * (isLargeTitle ? 1.72 : 1.58)
        preferred = min(preferred, heightCeiling)

        func width(of size: CGFloat) -> CGFloat {
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            return (text as NSString).boundingRect(
                with: CGSize(width: .greatestFiniteMagnitude, height: originalRect.height * 3),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).width
        }

        if singleLine {
            // 有空间就保留接近原文的字号；只有译文真的放不下时才缩。
            if width(of: preferred) <= availableWidth {
                return .systemFont(ofSize: preferred, weight: weight)
            }

            var low = max(7, preferred * 0.55)
            var high = preferred
            while high - low > 0.25 {
                let mid = (low + high) / 2
                if width(of: mid) <= availableWidth {
                    low = mid
                } else {
                    high = mid
                }
            }
            return .systemFont(ofSize: low, weight: weight)
        }

        // 多行文字允许更高的排版区域，同时保持接近源字号。
        var low = max(7, preferred * 0.55)
        var high = preferred

        func fitsMultiline(_ size: CGFloat) -> Bool {
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            let bounds = (text as NSString).boundingRect(
                with: CGSize(
                    width: availableWidth,
                    height: originalRect.height * 1.75
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )

            return bounds.width <= availableWidth + 0.5 &&
                bounds.height <= originalRect.height * 1.75
        }

        if fitsMultiline(preferred) {
            return .systemFont(ofSize: preferred, weight: weight)
        }

        while high - low > 0.25 {
            let mid = (low + high) / 2
            if fitsMultiline(mid) {
                low = mid
            } else {
                high = mid
            }
        }

        return .systemFont(ofSize: low, weight: weight)
    }

    private func estimatedSourceFontSize(
        originalText: String,
        originalRect: CGRect,
        weight: UIFont.Weight
    ) -> CGFloat {
        let source = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, originalRect.width > 2 else {
            return max(9, originalRect.height * 1.22)
        }

        let targetWidth = max(2, originalRect.width * 0.985)
        var low: CGFloat = 5
        var high = max(18, originalRect.height * 2.4)

        func sourceWidth(_ size: CGFloat) -> CGFloat {
            let font = UIFont.systemFont(ofSize: size, weight: weight)
            return (source as NSString).boundingRect(
                with: CGSize(width: .greatestFiniteMagnitude, height: originalRect.height * 3),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).width
        }

        // 如果上限仍比原文字窄，再扩大搜索范围。
        var guardCount = 0
        while sourceWidth(high) < targetWidth && guardCount < 4 {
            high *= 1.35
            guardCount += 1
        }

        while high - low > 0.25 {
            let mid = (low + high) / 2
            if sourceWidth(mid) <= targetWidth {
                low = mid
            } else {
                high = mid
            }
        }

        // 宽度估算与 OCR 高度互相校正，避免极短词导致估算失真。
        let heightReference = originalRect.height * 1.18
        return max(low, heightReference)
    }

    private func averageColor(in image: UIImage, rect: CGRect) -> UIColor? {
        guard let cg = image.cgImage else { return nil }

        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: image.size.width,
            height: image.size.height
        )
        let clipped = rect.intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            return nil
        }

        let sx = CGFloat(cg.width) / image.size.width
        let sy = CGFloat(cg.height) / image.size.height

        let pixelRect = CGRect(
            x: clipped.minX * sx,
            y: (image.size.height - clipped.maxY) * sy,
            width: clipped.width * sx,
            height: clipped.height * sy
        ).integral

        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }

        let input = CIImage(cgImage: cg).cropped(to: pixelRect)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }

        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)

        guard let output = filter.outputImage else { return nil }

        var rgba = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &rgba,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return UIColor(
            red: CGFloat(rgba[0]) / 255,
            green: CGFloat(rgba[1]) / 255,
            blue: CGFloat(rgba[2]) / 255,
            alpha: 1
        )
    }
}

private extension UIColor {
    var rgbaComponents: (CGFloat, CGFloat, CGFloat, CGFloat)? {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (r, g, b, a)
    }

    var isDark: Bool {
        guard let (r, g, b, _) = rgbaComponents else { return false }
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 0.52
    }

    func distance(to other: UIColor) -> CGFloat {
        guard
            let (r1, g1, b1, _) = rgbaComponents,
            let (r2, g2, b2, _) = other.rgbaComponents
        else { return 0 }

        let dr = r1 - r2
        let dg = g1 - g2
        let db = b1 - b2
        return sqrt(dr * dr + dg * dg + db * db)
    }

    static func median(of colors: [UIColor]) -> UIColor? {
        let values = colors.compactMap(\.rgbaComponents)
        guard !values.isEmpty else { return nil }

        func median(_ values: [CGFloat]) -> CGFloat {
            let sorted = values.sorted()
            let middle = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[middle - 1] + sorted[middle]) / 2
            }
            return sorted[middle]
        }

        return UIColor(
            red: median(values.map { $0.0 }),
            green: median(values.map { $0.1 }),
            blue: median(values.map { $0.2 }),
            alpha: median(values.map { $0.3 })
        )
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

        let found = try await ocr.recognize(
            image: image,
            sourceLanguage: source,
            fast: AppConfiguration.provider == .baiduFast
        )
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


enum ReturnTargetStore {
    private static let bundleIDKey = "ScreenTranslatorPro.returnTargetBundleID"

    static func captureFrontmostApplication() {
        guard
            let bundleID = PrivateApplicationBridge.frontmostBundleIdentifier(),
            !bundleID.isEmpty,
            bundleID != Bundle.main.bundleIdentifier,
            bundleID != "com.apple.springboard"
        else { return }

        UserDefaults.standard.set(bundleID, forKey: bundleIDKey)
    }

    @discardableResult
    static func openCapturedApplication() -> Bool {
        guard
            let bundleID = UserDefaults.standard.string(forKey: bundleIDKey),
            !bundleID.isEmpty,
            bundleID != Bundle.main.bundleIdentifier
        else { return false }

        return PrivateApplicationBridge.openApplication(bundleIdentifier: bundleID)
    }

    static var capturedBundleIdentifier: String? {
        UserDefaults.standard.string(forKey: bundleIDKey)
    }
}

private enum PrivateApplicationBridge {
    typealias FrontmostFunction = @convention(c) () -> Unmanaged<CFString>?

    static func frontmostBundleIdentifier() -> String? {
        let frameworkPath = "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier") else {
            return nil
        }

        let function = unsafeBitCast(symbol, to: FrontmostFunction.self)
        guard let value = function()?.takeRetainedValue() else { return nil }
        return value as String
    }

    static func openApplication(bundleIdentifier: String) -> Bool {
        guard
            let workspaceClass: AnyClass = NSClassFromString("LSApplicationWorkspace"),
            let defaultMethod = class_getClassMethod(
                workspaceClass,
                NSSelectorFromString("defaultWorkspace")
            )
        else { return false }

        typealias DefaultWorkspaceFunction = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        let defaultImplementation = method_getImplementation(defaultMethod)
        let defaultWorkspace = unsafeBitCast(
            defaultImplementation,
            to: DefaultWorkspaceFunction.self
        )
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        let workspace = defaultWorkspace(
            workspaceClass,
            defaultSelector
        ).takeUnretainedValue()

        let selectors = [
            NSSelectorFromString("openApplicationWithBundleID:"),
            NSSelectorFromString("openApplicationWithBundleIdentifier:")
        ]

        for selector in selectors {
            guard
                let method = class_getInstanceMethod(workspaceClass, selector)
            else { continue }

            typealias OpenFunction = @convention(c) (AnyObject, Selector, NSString) -> Bool
            let implementation = method_getImplementation(method)
            let open = unsafeBitCast(implementation, to: OpenFunction.self)

            if open(workspace, selector, bundleIdentifier as NSString) {
                return true
            }
        }

        return false
    }
}
