import AppIntents
import UniformTypeIdentifiers
import UIKit

struct TranslateScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "翻译截图"
    static var description = IntentDescription("接收当前截图并翻译，然后打开全屏译图预览。")

    // 先后台翻译；完成后由 perform() 显式请求进入前台。
    static var supportedModes: IntentModes = [
        .background,
        .foreground(.dynamic)
    ]

    @Parameter(
        title: "截图",
        supportedContentTypes: [.image],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var screenshot: IntentFile

    func perform() async throws -> some IntentResult {
        ReturnTargetStore.captureFrontmostApplication()

        let data = screenshot.data
        guard let image = UIImage(data: data) else {
            throw ScreenTranslatorError.invalidImage
        }

        let result = try await ScreenTranslationEngine().process(image: image)
        try PreviewStore.save(result.image)

        // iOS 26+ 不依赖 deferred 自动切前台，明确请求前台切换。
        if systemContext.currentMode == .background,
           systemContext.currentMode.canContinueInForeground {
            try await continueInForeground()
        }

        return .result()
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
