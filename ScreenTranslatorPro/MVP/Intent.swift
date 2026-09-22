import AppIntents
import UniformTypeIdentifiers
import SwiftUI
import UIKit

struct TranslateScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "翻译截图"
    static var description = IntentDescription("接收当前截图并翻译，在当前上下文显示翻译结果。")
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "截图",
        supportedContentTypes: [.image],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var screenshot: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ShowsSnippetView {
        let data = screenshot.data
        guard let image = UIImage(data: data) else {
            throw ScreenTranslatorError.invalidImage
        }

        let result = try await ScreenTranslationEngine().process(image: image)
        guard let png = result.image.pngData() else {
            throw ScreenTranslatorError.invalidImage
        }

        let file = IntentFile(
            data: png,
            filename: "ScreenTranslatorPro-Translated.png",
            type: .png
        )

        return .result(
            value: file,
            view: TranslationResultSnippet(imageData: png)
        )
    }
}

private struct TranslationResultSnippet: View {
    let imageData: Data

    var body: some View {
        Group {
            if let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 340)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                ContentUnavailableView(
                    "无法显示译图",
                    systemImage: "photo.badge.exclamationmark"
                )
            }
        }
        .padding(.vertical, 4)
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
