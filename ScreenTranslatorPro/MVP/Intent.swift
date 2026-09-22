import AppIntents
import UniformTypeIdentifiers
import UIKit

struct TranslateScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "翻译截图"
    static var description = IntentDescription("接收当前截图并翻译，然后打开全屏译图预览。")

    // 先在后台完成截图翻译，结束时再把 ScreenTranslatorPro 拉到前台。
    // 这样 perform() 开始时仍有机会记录真正的来源 App。
    static var supportedModes: IntentModes = [
        .background,
        .foreground(.deferred)
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

        // deferred foreground mode 会在 perform 结束后把 App 拉到前台，
        // ContentView 会读取 PreviewStore 并显示全屏译图。
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
