import SwiftUI
import PhotosUI
import UIKit

@main
struct ScreenTranslatorProApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @AppStorage(AppConfiguration.providerKey) private var providerRaw = ProviderKind.localOCR.rawValue
    @AppStorage(AppConfiguration.sourceLanguageKey) private var sourceLanguage = "auto"
    @AppStorage(AppConfiguration.targetLanguageKey) private var targetLanguage = "zh"

    @State private var pickerItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var translatedImage: UIImage?
    @State private var isWorking = false
    @State private var showingTranslation = true
    @State private var errorMessage: String?

    private let blue = Color(red: 0.13, green: 0.48, blue: 0.98)
    private let purple = Color(red: 0.51, green: 0.30, blue: 0.98)

    private var provider: ProviderKind {
        ProviderKind(rawValue: providerRaw) ?? .localOCR
    }

    private var previewImage: UIImage? {
        if showingTranslation, let translatedImage { return translatedImage }
        return originalImage
    }

    var body: some View {
        NavigationStack {
            ZStack {
                background
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        topBar
                        heroCard
                        configurationSection
                        if originalImage != nil { workspaceSection }
                        shortcutSection
                        Text(versionText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("屏幕翻译")
            .toolbar(.hidden, for: .navigationBar)
            .task(id: pickerItem) { await loadSelectedImage() }
        }
    }

    private var background: some View {
        ZStack {
            Color(red: 0.965, green: 0.976, blue: 0.998)
            Circle().fill(blue.opacity(0.12))
                .frame(width: 300, height: 300).blur(radius: 80)
                .offset(x: 150, y: -300)
            Circle().fill(purple.opacity(0.10))
                .frame(width: 260, height: 260).blur(radius: 85)
                .offset(x: -150, y: 340)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image("AppLogo")
                .resizable().scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: blue.opacity(0.18), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("屏幕翻译").font(.system(size: 20, weight: .bold))
                Text("截图识别 · 原位翻译")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            NavigationLink(destination: SettingsView()) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(blue)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.88), in: Circle())
                    .overlay(Circle().stroke(Color.black.opacity(0.05), lineWidth: 1))
            }
            .accessibilityLabel("打开设置")
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack {
                Label("即拍即译", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.white.opacity(0.18), in: Capsule())
                Spacer()
                Image(systemName: "viewfinder")
                    .font(.system(size: 34, weight: .ultraLight))
                    .opacity(0.72).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("看得懂每一屏")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.8).lineLimit(1)
                Text("截取画面，识别文字，并在原位置呈现译文。")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text(originalImage == nil ? "选择截图体验" : "更换截图")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.13, green: 0.37, blue: 0.88))
                .padding(.horizontal, 18).frame(height: 52)
                .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.72, blue: 0.94),
                    Color(red: 0.16, green: 0.42, blue: 0.98),
                    Color(red: 0.55, green: 0.31, blue: 0.98)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .shadow(color: blue.opacity(0.22), radius: 20, y: 10)
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("当前配置", icon: "slider.horizontal.3")
            NavigationLink(destination: SettingsView()) {
                HStack(spacing: 13) {
                    Image(systemName: provider == .localOCR ? "text.viewfinder" : "globe")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(blue)
                        .frame(width: 48, height: 48)
                        .background(blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(provider.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary).lineLimit(1)
                        Text("\(languageName(sourceLanguage)) → \(languageName(targetLanguage))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var workspaceSection: some View {
        if let previewImage {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("截图工作台", icon: "square.on.square")
                VStack(spacing: 15) {
                    HStack {
                        Text(translatedImage == nil ? "待翻译截图" : "翻译结果")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        if translatedImage != nil {
                            HStack(spacing: 3) {
                                previewTab("原图", translated: false)
                                previewTab("译图", translated: true)
                            }
                            .padding(3)
                            .background(Color.black.opacity(0.045), in: Capsule())
                        }
                    }
                    Image(uiImage: previewImage)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity).frame(maxHeight: 460)
                        .background(Color.black.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Button {
                        guard let originalImage else { return }
                        Task { await translate(originalImage) }
                    } label: {
                        HStack(spacing: 8) {
                            if isWorking { ProgressView().tint(.white) }
                            else { Image(systemName: "character.bubble.fill") }
                            Text(isWorking ? "正在翻译…" : "翻译这张截图")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(
                            LinearGradient(colors: [blue, purple],
                                           startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain).disabled(isWorking)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 24))
            }
        }
    }

    private func previewTab(_ title: String, translated: Bool) -> some View {
        let selected = showingTranslation == translated
        return Button { showingTranslation = translated } label: {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? blue : Color.secondary)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(selected ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("一键屏幕翻译", icon: "bolt.fill")
            VStack(alignment: .leading, spacing: 0) {
                guideStep("1", icon: "viewfinder", title: "截屏", detail: "在快捷指令中截取当前画面")
                Divider().padding(.leading, 58)
                guideStep("2", icon: "character.bubble.fill", title: "翻译截图", detail: "选择「屏幕翻译」的动作")
                Divider().padding(.leading, 58)
                guideStep("3", icon: "eye.fill", title: "快速查看", detail: "用系统预览查看原位译图")
                Text("将这条快捷指令绑定到背部轻点等触发方式，即可在其他 App 中使用。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 5)
            }
            .padding(15)
            .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private func guideStep(_ number: String, icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(blue)
                .frame(width: 44, height: 44)
                .background(blue.opacity(0.085), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(number).font(.system(size: 12, weight: .bold)).foregroundStyle(blue)
                .frame(width: 26, height: 26).background(blue.opacity(0.08), in: Circle())
        }
        .padding(.vertical, 11)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(.primary).padding(.horizontal, 3)
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2"
        return "屏幕翻译 · v\(version) (\(build))"
    }

    private func languageName(_ code: String) -> String {
        switch code.lowercased() {
        case "auto": return "自动识别"
        case "zh": return "简体中文"
        case "cht": return "繁体中文"
        case "en": return "英语"
        case "ja", "jp": return "日语"
        case "ko": return "韩语"
        case "fr": return "法语"
        case "de": return "德语"
        case "es": return "西班牙语"
        default: return code
        }
    }

    @MainActor
    private func loadSelectedImage() async {
        guard let pickerItem else { return }
        do {
            if let data = try await pickerItem.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                originalImage = image
                translatedImage = nil
                showingTranslation = false
                errorMessage = nil
            } else {
                errorMessage = "无法读取所选图片。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func translate(_ image: UIImage) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            translatedImage = try await ScreenTranslationEngine().process(image: image).image
            showingTranslation = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
