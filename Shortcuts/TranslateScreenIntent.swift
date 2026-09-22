import AppIntents

@available(iOS 16.0, *)
struct TranslateScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Translate Screen"
    static var description = IntentDescription("Capture and translate the current screen screenshot.")

    func perform() async throws -> some IntentResult {
        .result()
    }
}
