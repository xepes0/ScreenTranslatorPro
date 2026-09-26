import AppIntents
import UniformTypeIdentifiers
import UIKit

struct TranslateScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "翻译截图"
    static var description = IntentDescription("接收当前截图，翻译后把译图输出给快捷指令。")
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "截图",
        supportedContentTypes: [.image],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var screenshot: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = screenshot.data
        guard let image = UIImage(data: data) else {
            throw ScreenTranslatorError.invalidImage
        }

        let result = try await ScreenTranslationEngine().process(image: image)
        guard let png = result.image.pngData() else {
            throw ScreenTranslatorError.invalidImage
        }

        return .result(
            value: IntentFile(
                data: png,
                filename: "ScreenTranslatorPro-Translated.png",
                type: .png
            )
        )
    }
}

struct ScreenTranslatorAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TranslateScreenshotIntent(),
            phrases: [
                "Translate screen with \(.applicationName)",
                "Translate screenshot with \(.applicationName)"
            ],
            shortTitle: "翻译截图",
            systemImageName: "character.bubble"
        )
    }
}
