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
    let layoutLineCount: Int
    var translation: String

    init(
        id: UUID = UUID(),
        text: String,
        boundingBox: CGRect,
        confidence: Float,
        layoutLineCount: Int = 1,
        translation: String = ""
    ) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.layoutLineCount = max(1, layoutLineCount)
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

struct TextLayoutGrouper {
    private struct Line {
        var items: [OCRResult]

        var text: String {
            items.map(\.text).joined(separator: " ")
        }

        var boundingBox: CGRect {
            items.dropFirst().reduce(items[0].boundingBox) {
                $0.union($1.boundingBox)
            }
        }

        var confidence: Float {
            guard !items.isEmpty else { return 0 }
            return items.map(\.confidence).reduce(0, +) / Float(items.count)
        }

        var averageHeight: CGFloat {
            items.map { $0.boundingBox.height }.reduce(0, +) / CGFloat(items.count)
        }
    }

    func prepare(_ items: [OCRResult]) -> [OCRResult] {
        guard items.count > 1 else { return items }

        let lines = buildLines(from: items)
        return buildLayoutItems(from: lines)
    }

    private func buildLines(from items: [OCRResult]) -> [Line] {
        let sorted = items.sorted {
            let rowDelta = abs($0.boundingBox.midY - $1.boundingBox.midY)
            return rowDelta > 0.018
                ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }

        var lines: [Line] = []

        for item in sorted {
            if let index = bestLineIndex(for: item, in: lines) {
                lines[index].items.append(item)
                lines[index].items.sort { $0.boundingBox.minX < $1.boundingBox.minX }
            } else {
                lines.append(Line(items: [item]))
            }
        }

        return lines.sorted {
            let delta = abs($0.boundingBox.midY - $1.boundingBox.midY)
            return delta > 0.018
                ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
    }

    private func bestLineIndex(for item: OCRResult, in lines: [Line]) -> Int? {
        // 图标很容易被 Vision OCR 误认成 “151”、圆点、括号等短字符。
        // 这类无字母 token 必须保持独立，不能在 beta19 的行合并阶段
        // 拼到右侧菜单文字里，否则会出现 “151启动串行连接” 之类结果。
        guard containsLetterLikeCharacter(item.text) else {
            return nil
        }

        var best: (index: Int, score: CGFloat)?

        for (index, line) in lines.enumerated() {
            // 已经判定为数字/符号/图标伪字符的独立行也不允许吸附正文。
            guard line.items.contains(where: { containsLetterLikeCharacter($0.text) }) else {
                continue
            }
            let box = line.boundingBox
            let minHeight = max(0.0001, min(box.height, item.boundingBox.height))
            let maxHeight = max(box.height, item.boundingBox.height)
            let heightRatio = maxHeight / minHeight

            guard heightRatio <= 1.42 else { continue }

            let verticalDelta = abs(box.midY - item.boundingBox.midY)
            let rowTolerance = max(0.004, minHeight * 0.48)
            guard verticalDelta <= rowTolerance else { continue }

            let gap: CGFloat
            if item.boundingBox.minX >= box.maxX {
                gap = item.boundingBox.minX - box.maxX
            } else if box.minX >= item.boundingBox.maxX {
                gap = box.minX - item.boundingBox.maxX
            } else {
                gap = 0
            }

            let gapLimit = max(0.018, maxHeight * 1.9)
            guard gap <= gapLimit else { continue }

            let score = verticalDelta * 8 + gap
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }

        return best?.index
    }

    private func buildLayoutItems(from lines: [Line]) -> [OCRResult] {
        guard !lines.isEmpty else { return [] }

        var output: [OCRResult] = []
        var paragraph: [Line] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }

            if paragraph.count == 1 {
                output.append(makeLineItem(paragraph[0]))
            } else {
                output.append(makeParagraphItem(paragraph))
            }
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in lines {
            guard isParagraphCandidate(line) else {
                flushParagraph()
                output.append(makeLineItem(line))
                continue
            }

            if paragraph.isEmpty {
                paragraph = [line]
                continue
            }

            if shouldJoinParagraph(paragraph, next: line) {
                paragraph.append(line)
            } else {
                flushParagraph()
                paragraph = [line]
            }
        }

        flushParagraph()

        return output.sorted {
            let delta = abs($0.boundingBox.midY - $1.boundingBox.midY)
            return delta > 0.018
                ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
    }

    private func makeLineItem(_ line: Line) -> OCRResult {
        OCRResult(
            text: line.text,
            boundingBox: line.boundingBox,
            confidence: line.confidence,
            layoutLineCount: 1
        )
    }

    private func makeParagraphItem(_ lines: [Line]) -> OCRResult {
        let box = lines.dropFirst().reduce(lines[0].boundingBox) {
            $0.union($1.boundingBox)
        }
        let confidence = lines.map(\.confidence).reduce(0, +) / Float(lines.count)

        // 用空格连接而不是换行，避免百度快速模式按换行切批次时把一个段落拆开。
        let text = lines.map(\.text).joined(separator: " ")

        return OCRResult(
            text: text,
            boundingBox: box,
            confidence: confidence,
            layoutLineCount: lines.count
        )
    }

    private func shouldJoinParagraph(_ current: [Line], next: Line) -> Bool {
        guard let previous = current.last else { return false }
        guard current.count < 5 else { return false }
        guard isParagraphCandidate(previous), isParagraphCandidate(next) else {
            return false
        }

        let previousBox = previous.boundingBox
        let nextBox = next.boundingBox
        let averageHeight = (previous.averageHeight + next.averageHeight) / 2
        let minHeight = max(0.0001, min(previous.averageHeight, next.averageHeight))
        let heightRatio = max(previous.averageHeight, next.averageHeight) / minHeight

        // 标题 + 正文通常字号不同，保守地不合并。
        guard heightRatio <= 1.20 else { return false }

        let verticalGap = previousBox.minY - nextBox.maxY
        guard verticalGap >= -0.003 else { return false }
        guard verticalGap <= max(0.012, averageHeight * 1.05) else { return false }

        let leftDelta = abs(previousBox.minX - nextBox.minX)
        let leftAligned = leftDelta <= max(0.018, averageHeight * 0.85)

        let centerDelta = abs(previousBox.midX - nextBox.midX)
        let centered = centerDelta <= 0.035 &&
            abs(previousBox.width - nextBox.width) <= 0.16

        guard leftAligned || centered else { return false }

        // 只有看起来像连续说明/正文的行才合并，避免把两个按钮或列表项拼成段落。
        let previousLong = proseScore(previous.text) >= 2
        let nextLong = proseScore(next.text) >= 2
        guard previousLong && nextLong else { return false }

        return true
    }

    private func isParagraphCandidate(_ line: Line) -> Bool {
        let box = line.boundingBox
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return false }

        // 状态栏和底部 Tab 保持单独处理。
        if box.maxY > 0.955 || box.minY < 0.075 {
            return false
        }

        // 技术字符串/日志前缀不做段落合并。
        if text.contains("://") ||
           text.contains("@") ||
           text.contains("::") ||
           text.contains("->") ||
           text.contains("=>") ||
           text.hasPrefix("$ ") ||
           text.hasPrefix("# ") {
            return false
        }

        if let first = text.unicodeScalars.first,
           CharacterSet.symbols.contains(first) {
            return false
        }

        return true
    }

    private func containsLetterLikeCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            CharacterSet.letters.contains($0)
        }
    }

    private func proseScore(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = trimmed.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }.count

        var score = 0
        if letters >= 14 { score += 1 }
        if trimmed.count >= 20 { score += 1 }
        if trimmed.contains(" ") { score += 1 }
        if trimmed.hasSuffix(",") ||
           trimmed.hasSuffix(".") ||
           trimmed.hasSuffix(";") ||
           trimmed.hasSuffix(":") {
            score += 1
        }
        return score
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

                let foreground = estimatedForegroundColor(
                    in: original,
                    textRect: rect,
                    background: estimate.center
                ) ?? (estimate.center.isDark ? .white : .black)

                let fontWeight = estimatedFontWeight(
                    in: original,
                    textRect: rect,
                    background: estimate.center,
                    foreground: foreground,
                    imageSize: original.size
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
                    foreground: foreground,
                    weight: fontWeight,
                    sourceLineCount: item.layoutLineCount
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
        foreground: UIColor,
        weight: UIFont.Weight,
        sourceLineCount: Int
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let isParagraph = sourceLineCount > 1
        let isSingleLine = !isParagraph &&
            !trimmed.contains("\n") &&
            originalRect.height < imageSize.height * 0.06

        let horizontalInset = max(1, min(3, originalRect.height * 0.07))
        let drawWidth = max(1, eraseRect.width - horizontalInset * 2)

        let font = fittingFont(
            trimmed,
            originalText: originalText,
            originalRect: originalRect,
            availableWidth: drawWidth,
            imageSize: imageSize,
            singleLine: isSingleLine,
            weight: weight,
            sourceLineCount: sourceLineCount
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = inferredAlignment(
            for: originalRect,
            imageSize: imageSize
        )
        paragraph.lineBreakMode = isSingleLine ? .byClipping : .byWordWrapping
        paragraph.minimumLineHeight = font.lineHeight * 0.92
        paragraph.maximumLineHeight = font.lineHeight * (isParagraph ? 1.10 : 1.05)
        paragraph.lineSpacing = isParagraph ? max(0, font.pointSize * 0.06) : 0

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
            height: isParagraph
                ? max(1, eraseRect.height)
                : max(originalRect.height * 1.35, eraseRect.height)
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
        singleLine: Bool,
        weight: UIFont.Weight,
        sourceLineCount: Int
    ) -> UIFont {
        let lineCount = max(1, sourceLineCount)
        let sourceLineHeight = lineCount > 1
            ? originalRect.height / (CGFloat(lineCount) + CGFloat(lineCount - 1) * 0.18)
            : originalRect.height

        let isLargeTitle = sourceLineHeight > imageSize.height * 0.028

        // beta15：先用“原文实际宽度”反推原字体大小，再用同样字号绘制译文。
        // 这样不会再单纯依赖 OCR 高度而把中文缩得过小。
        let sizingText: String
        let sizingRect: CGRect

        if lineCount > 1 {
            // 段落已经由多行合并，不能拿整段宽度反推字号；
            // 用单行高度作为主参考，避免字号被 union rect 放大。
            sizingText = originalText
            sizingRect = CGRect(
                x: originalRect.minX,
                y: originalRect.minY,
                width: originalRect.width,
                height: sourceLineHeight
            )
        } else {
            sizingText = originalText
            sizingRect = originalRect
        }

        let sourceSize = lineCount > 1
            ? max(8, sourceLineHeight * 1.16)
            : estimatedSourceFontSize(
                originalText: sizingText,
                originalRect: sizingRect,
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
        let heightFloor = sourceLineHeight * (isLargeTitle ? 1.22 : 1.16)
        preferred = max(preferred, heightFloor)

        // 防止异常 OCR 框把字号推得过大。
        let heightCeiling = sourceLineHeight * (isLargeTitle ? 1.72 : 1.58)
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
                    height: sourceLineCount > 1
                        ? originalRect.height * 1.02
                        : originalRect.height * 1.75
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )

            return bounds.width <= availableWidth + 0.5 &&
                bounds.height <= (sourceLineCount > 1
                    ? originalRect.height * 1.02
                    : originalRect.height * 1.75)
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

    private func estimatedFontWeight(
        in image: UIImage,
        textRect: CGRect,
        background: UIColor,
        foreground: UIColor,
        imageSize: CGSize
    ) -> UIFont.Weight {
        guard
            let cg = image.cgImage,
            let bg = background.rgbaComponents,
            let fg = foreground.rgbaComponents
        else {
            return textRect.height > imageSize.height * 0.028 ? .semibold : .regular
        }

        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: image.size.width,
            height: image.size.height
        )

        let sampleRect = textRect
            .insetBy(dx: max(0.25, textRect.height * 0.02),
                     dy: max(0.15, textRect.height * 0.015))
            .intersection(imageBounds)

        guard sampleRect.width >= 2, sampleRect.height >= 2 else {
            return textRect.height > imageSize.height * 0.028 ? .semibold : .regular
        }

        let sx = CGFloat(cg.width) / image.size.width
        let sy = CGFloat(cg.height) / image.size.height
        let pixelRect = CGRect(
            x: sampleRect.minX * sx,
            y: (image.size.height - sampleRect.maxY) * sy,
            width: sampleRect.width * sx,
            height: sampleRect.height * sy
        ).integral

        guard pixelRect.width >= 2, pixelRect.height >= 2 else {
            return textRect.height > imageSize.height * 0.028 ? .semibold : .regular
        }

        let input = CIImage(cgImage: cg).cropped(to: pixelRect)
        let translated = input.transformed(
            by: CGAffineTransform(
                translationX: -pixelRect.minX,
                y: -pixelRect.minY
            )
        )

        let sampleWidth = 42
        let aspect = max(0.12, pixelRect.height / pixelRect.width)
        let sampleHeight = max(8, min(24, Int(CGFloat(sampleWidth) * aspect)))
        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(sampleWidth) / pixelRect.width,
                y: CGFloat(sampleHeight) / pixelRect.height
            )
        )

        var bitmap = [UInt8](
            repeating: 0,
            count: sampleWidth * sampleHeight * 4
        )

        ciContext.render(
            scaled,
            toBitmap: &bitmap,
            rowBytes: sampleWidth * 4,
            bounds: CGRect(
                x: 0,
                y: 0,
                width: sampleWidth,
                height: sampleHeight
            ),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let axisR = fg.0 - bg.0
        let axisG = fg.1 - bg.1
        let axisB = fg.2 - bg.2
        let axisLengthSquared =
            axisR * axisR +
            axisG * axisG +
            axisB * axisB

        guard axisLengthSquared > 0.008 else {
            return textRect.height > imageSize.height * 0.028 ? .semibold : .regular
        }

        var inkSum: CGFloat = 0
        var strongCount: CGFloat = 0
        var validCount: CGFloat = 0

        for index in stride(from: 0, to: bitmap.count, by: 4) {
            let a = CGFloat(bitmap[index + 3]) / 255
            guard a > 0.65 else { continue }

            let r = CGFloat(bitmap[index]) / 255
            let g = CGFloat(bitmap[index + 1]) / 255
            let b = CGFloat(bitmap[index + 2]) / 255

            let pr = r - bg.0
            let pg = g - bg.1
            let pb = b - bg.2

            var projection =
                (pr * axisR + pg * axisG + pb * axisB) /
                axisLengthSquared

            projection = min(1, max(0, projection))
            validCount += 1
            inkSum += projection

            if projection >= 0.52 {
                strongCount += 1
            }
        }

        guard validCount > 0 else {
            return textRect.height > imageSize.height * 0.028 ? .semibold : .regular
        }

        let meanInk = inkSum / validCount
        let strongCoverage = strongCount / validCount
        let densityScore = meanInk * 0.62 + strongCoverage * 0.38

        let isLargeTitle = textRect.height > imageSize.height * 0.028
        let isSmallLabel = textRect.height < imageSize.height * 0.015

        if isLargeTitle {
            if densityScore >= 0.24 { return .bold }
            return .semibold
        }

        if densityScore >= 0.235 {
            return .bold
        } else if densityScore >= 0.175 {
            return .semibold
        } else if densityScore >= 0.125 {
            return .medium
        } else if isSmallLabel && densityScore >= 0.10 {
            return .medium
        } else {
            return .regular
        }
    }

    private func estimatedForegroundColor(
        in image: UIImage,
        textRect: CGRect,
        background: UIColor
    ) -> UIColor? {
        guard
            let cg = image.cgImage,
            let bg = background.rgbaComponents
        else { return nil }

        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: image.size.width,
            height: image.size.height
        )

        // 稍微收一点边，尽量只取文字笔画，避免把卡片边缘/图标采进来。
        let insetX = max(0.5, min(2.0, textRect.height * 0.05))
        let insetY = max(0.25, min(1.2, textRect.height * 0.03))
        let sampleRect = textRect
            .insetBy(dx: insetX, dy: insetY)
            .intersection(imageBounds)

        guard sampleRect.width >= 2, sampleRect.height >= 2 else { return nil }

        let sx = CGFloat(cg.width) / image.size.width
        let sy = CGFloat(cg.height) / image.size.height
        let pixelRect = CGRect(
            x: sampleRect.minX * sx,
            y: (image.size.height - sampleRect.maxY) * sy,
            width: sampleRect.width * sx,
            height: sampleRect.height * sy
        ).integral

        guard pixelRect.width >= 2, pixelRect.height >= 2 else { return nil }

        let input = CIImage(cgImage: cg).cropped(to: pixelRect)
        let translated = input.transformed(
            by: CGAffineTransform(
                translationX: -pixelRect.minX,
                y: -pixelRect.minY
            )
        )

        // 每个文字框只采样一个很小的缩略图，成本低，但足够区分
        // 主文字白色 / 次级灰色 / 深色文字 / 彩色文字。
        let sampleWidth = 28
        let aspect = max(0.15, pixelRect.height / pixelRect.width)
        let sampleHeight = max(6, min(18, Int(CGFloat(sampleWidth) * aspect)))
        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(sampleWidth) / pixelRect.width,
                y: CGFloat(sampleHeight) / pixelRect.height
            )
        )

        var bitmap = [UInt8](
            repeating: 0,
            count: sampleWidth * sampleHeight * 4
        )

        ciContext.render(
            scaled,
            toBitmap: &bitmap,
            rowBytes: sampleWidth * 4,
            bounds: CGRect(
                x: 0,
                y: 0,
                width: sampleWidth,
                height: sampleHeight
            ),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        struct Candidate {
            let r: CGFloat
            let g: CGFloat
            let b: CGFloat
            let distance: CGFloat
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(sampleWidth * sampleHeight)

        for index in stride(from: 0, to: bitmap.count, by: 4) {
            let r = CGFloat(bitmap[index]) / 255
            let g = CGFloat(bitmap[index + 1]) / 255
            let b = CGFloat(bitmap[index + 2]) / 255
            let a = CGFloat(bitmap[index + 3]) / 255

            guard a > 0.7 else { continue }

            let dr = r - bg.0
            let dg = g - bg.1
            let db = b - bg.2
            let distance = sqrt(dr * dr + dg * dg + db * db)

            // 背景和抗锯齿边缘不参与；只保留明显不同于背景的像素。
            guard distance > 0.075 else { continue }

            candidates.append(
                Candidate(r: r, g: g, b: b, distance: distance)
            )
        }

        guard candidates.count >= 3 else { return nil }

        // 取距离背景最远的一小批像素，能更接近原始字色，
        // 而不是被抗锯齿混合后的中间灰拖偏。
        candidates.sort { $0.distance > $1.distance }
        let keepCount = max(
            3,
            min(candidates.count, Int(ceil(CGFloat(candidates.count) * 0.22)))
        )
        let selected = Array(candidates.prefix(keepCount))

        let totalWeight = selected.reduce(CGFloat.zero) {
            $0 + max(0.001, $1.distance * $1.distance)
        }

        guard totalWeight > 0 else { return nil }

        let r = selected.reduce(CGFloat.zero) {
            $0 + $1.r * max(0.001, $1.distance * $1.distance)
        } / totalWeight
        let g = selected.reduce(CGFloat.zero) {
            $0 + $1.g * max(0.001, $1.distance * $1.distance)
        } / totalWeight
        let b = selected.reduce(CGFloat.zero) {
            $0 + $1.b * max(0.001, $1.distance * $1.distance)
        } / totalWeight

        let color = UIColor(red: r, green: g, blue: b, alpha: 1)

        // 如果最终采样色和背景仍过于接近，宁可回退到黑/白，
        // 避免译文因为低对比度几乎看不见。
        guard color.distance(to: background) > 0.10 else { return nil }
        return color
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
    private let grouper = TextLayoutGrouper()
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

        let layoutItems = grouper.prepare(found)
        let translated = try await service.translate(
            layoutItems,
            source: source,
            target: target
        )

        return ScreenTranslationResult(
            image: renderer.render(original: image, items: translated),
            items: translated
        )
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
