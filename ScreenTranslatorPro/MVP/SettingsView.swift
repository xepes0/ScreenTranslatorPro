import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppConfiguration.providerKey) private var providerRaw = ProviderKind.localOCR.rawValue
    @AppStorage(AppConfiguration.sourceLanguageKey) private var sourceLanguage = "auto"
    @AppStorage(AppConfiguration.targetLanguageKey) private var targetLanguage = "zh"

    @State private var baiduAppID = ""
    @State private var baiduSecret = ""
    @State private var deepLKey = ""
    @State private var openAIKey = ""
    @State private var openAIEndpoint = "https://api.openai.com/v1/chat/completions"
    @State private var openAIModel = "gpt-4.1-mini"
    @State private var saveMessage: String?
    @State private var showBaiduSecret = false
    @State private var showDeepLKey = false
    @State private var showOpenAIKey = false

    private let accentBlue = Color(red: 0.13, green: 0.48, blue: 0.98)
    private let accentPurple = Color(red: 0.51, green: 0.30, blue: 0.98)

    private var provider: Binding<ProviderKind> {
        Binding(
            get: { ProviderKind(rawValue: providerRaw) ?? .localOCR },
            set: { providerRaw = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(spacing: 20) {
                    topBar
                    hero
                    translationSection
                    providerSection
                    shortcutSection
                    saveButton

                    Text(versionText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear(perform: load)
    }

    private var background: some View {
        ZStack {
            Color(red: 0.965, green: 0.976, blue: 0.998)

            Circle()
                .fill(accentBlue.opacity(0.13))
                .frame(width: 290, height: 290)
                .blur(radius: 75)
                .offset(x: 130, y: -330)

            Circle()
                .fill(accentPurple.opacity(0.12))
                .frame(width: 250, height: 250)
                .blur(radius: 85)
                .offset(x: -150, y: 360)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.82), in: Circle())
                    .overlay(Circle().stroke(Color.black.opacity(0.07), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("设置")
                .font(.system(size: 22, weight: .bold))

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 6)
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Image("AppLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .shadow(color: accentBlue.opacity(0.20), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text("屏幕翻译")
                    .font(.system(size: 25, weight: .bold))
                Text("一键翻译屏幕上的任何内容")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Screen Translator Pro")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.76))
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Text("让世界触手可及").lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accentBlue)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(accentBlue.opacity(0.09), in: Capsule())
        }
        .padding(.horizontal, 2)
    }

    private var translationSection: some View {
        VStack(spacing: 10) {
            sectionHeader(
                icon: "globe",
                title: "翻译服务",
                detail: "选择翻译引擎和语言设置"
            )

            card {
                row(
                    icon: "square.stack.3d.up.fill",
                    title: "服务商",
                    subtitle: "选择 AI 翻译服务提供商"
                ) {
                    Menu {
                        ForEach(ProviderKind.allCases) { item in
                            Button(item.displayName) { provider.wrappedValue = item }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(provider.wrappedValue.displayName)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                    }
                }

                separator

                row(
                    icon: "a.square.fill",
                    title: "源语言",
                    subtitle: "识别截图中的原始语言"
                ) {
                    compactField("auto", text: $sourceLanguage)
                }

                separator

                row(
                    icon: "character.book.closed.fill",
                    title: "目标语言",
                    subtitle: "翻译为目标语言"
                ) {
                    compactField("zh", text: $targetLanguage)
                }
            }
        }
    }

    @ViewBuilder
    private var providerSection: some View {
        let value = provider.wrappedValue

        VStack(spacing: 10) {
            sectionHeader(
                icon: providerIcon(value),
                title: value.displayName,
                detail: providerDetail(value)
            )

            card {
                switch value {
                case .localOCR:
                    infoRow(
                        icon: "iphone.gen3",
                        title: "本地 OCR 测试",
                        text: "不联网，只验证 Vision OCR、坐标识别与原位回填。"
                    )

                case .baiduFast:
                    baiduRows("本机 Vision OCR + 百度文本翻译 + 原位回填，速度优先。")

                case .baiduText:
                    baiduRows("使用百度翻译开放平台通用文本翻译。")

                case .baiduImageOpen:
                    baiduRows("百度图片翻译整图模式，版式更自然但通常更慢。")

                case .deepL:
                    row(
                        icon: "key.fill",
                        title: "Auth Key",
                        subtitle: "DeepL API 凭据"
                    ) {
                        secretField(
                            text: $deepLKey,
                            visible: $showDeepLKey,
                            placeholder: "DeepL Auth Key"
                        )
                    }

                case .openAICompatible:
                    row(
                        icon: "key.fill",
                        title: "API Key",
                        subtitle: "用于访问 OpenAI 兼容服务"
                    ) {
                        secretField(
                            text: $openAIKey,
                            visible: $showOpenAIKey,
                            placeholder: "API Key"
                        )
                    }

                    separator

                    row(
                        icon: "link",
                        title: "Endpoint",
                        subtitle: "完整 Chat Completions 请求地址"
                    ) {
                        wideField(
                            "https://…/v1/chat/completions",
                            text: $openAIEndpoint,
                            keyboard: .URL
                        )
                    }

                    separator

                    row(
                        icon: "cube.fill",
                        title: "Model",
                        subtitle: "使用的模型 ID"
                    ) {
                        wideField("model-id", text: $openAIModel)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func baiduRows(_ description: String) -> some View {
        row(
            icon: "person.text.rectangle.fill",
            title: "APP ID",
            subtitle: "百度翻译开放平台"
        ) {
            wideField("APP ID", text: $baiduAppID)
        }

        separator

        row(
            icon: "key.fill",
            title: "Key",
            subtitle: "翻译开放平台密钥"
        ) {
            secretField(
                text: $baiduSecret,
                visible: $showBaiduSecret,
                placeholder: "Key"
            )
        }

        separator

        infoRow(
            icon: "info.circle.fill",
            title: "模式说明",
            text: description
        )
    }

    private var shortcutSection: some View {
        VStack(spacing: 10) {
            sectionHeader(
                icon: "bolt.fill",
                title: "快捷指令",
                detail: "快速翻译截图内容"
            )

            card {
                HStack(alignment: .top, spacing: 6) {
                    shortcutStep(
                        number: "1",
                        icon: "viewfinder",
                        title: "截屏",
                        subtitle: "使用系统截屏"
                    )

                    stepArrow
                    shortcutAppStep
                    stepArrow

                    shortcutStep(
                        number: "3",
                        icon: "eye.fill",
                        title: "快速查看",
                        subtitle: "查看翻译结果"
                    )
                }
                .padding(.vertical, 3)

                VStack(alignment: .leading, spacing: 5) {
                    Label("使用系统图片预览查看翻译结果。", systemImage: "photo")
                    Text("关闭按钮在左上角；关闭后会自动回到原 App。")
                        .padding(.leading, 25)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.blue.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
        }
    }

    private var stepArrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.top, 30)
    }

    private func shortcutStep(
        number: String,
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        VStack(spacing: 6) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(accentBlue)
                .frame(width: 28, height: 28)
                .background(accentBlue.opacity(0.09), in: Circle())

            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(accentBlue)
                .frame(height: 32)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var shortcutAppStep: some View {
        VStack(spacing: 6) {
            Text("2")
                .font(.caption.weight(.bold))
                .foregroundStyle(accentPurple)
                .frame(width: 28, height: 28)
                .background(accentPurple.opacity(0.09), in: Circle())

            Image("AppLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Screen Translator Pro")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text("选择「翻译截图」")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var saveButton: some View {
        VStack(spacing: 8) {
            Button(action: save) {
                HStack {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text("保存 API 配置")
                        .fontWeight(.bold)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 58)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.07, green: 0.69, blue: 0.96),
                            Color(red: 0.19, green: 0.39, blue: 1.0),
                            Color(red: 0.67, green: 0.25, blue: 0.97)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .shadow(color: accentBlue.opacity(0.22), radius: 14, y: 7)
            }
            .buttonStyle(.plain)

            if let saveMessage {
                Text(saveMessage)
                    .font(.footnote)
                    .foregroundStyle(saveMessage == "已保存" ? Color.green : Color.red)
            }
        }
    }

    private func sectionHeader(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(accentBlue)

            Text(title)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(1)

            Spacer()

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 4)
    }

    private func card<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            .white.opacity(0.90),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.95), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.045), radius: 18, y: 8)
    }

    private func row<Trailing: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 12) {
            rowIcon(icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            trailing()
                .frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.vertical, 12)
    }

    private func infoRow(
        icon: String,
        title: String,
        text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(icon)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.vertical, 12)
    }

    private func rowIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(accentBlue)
            .frame(width: 42, height: 42)
            .background(
                LinearGradient(
                    colors: [
                        accentBlue.opacity(0.12),
                        accentPurple.opacity(0.07)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }

    private var separator: some View {
        Divider().padding(.leading, 54)
    }

    private func compactField(
        _ placeholder: String,
        text: Binding<String>
    ) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .multilineTextAlignment(.trailing)
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                Color.black.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
    }

    private func wideField(
        _ placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(
                Color.black.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }

    @ViewBuilder
    private func secretField(
        text: Binding<String>,
        visible: Binding<Bool>,
        placeholder: String
    ) -> some View {
        HStack(spacing: 6) {
            Group {
                if visible.wrappedValue {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 13))

            Button {
                visible.wrappedValue.toggle()
            } label: {
                Image(systemName: visible.wrappedValue ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(
            Color.black.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func providerIcon(_ value: ProviderKind) -> String {
        switch value {
        case .localOCR: return "iphone.gen3"
        case .baiduFast: return "bolt.horizontal.circle.fill"
        case .baiduText: return "character.bubble.fill"
        case .baiduImageOpen: return "photo.on.rectangle.angled"
        case .deepL: return "network"
        case .openAICompatible: return "gearshape.fill"
        }
    }

    private func providerDetail(_ value: ProviderKind) -> String {
        switch value {
        case .localOCR: return "本机 Vision OCR"
        case .baiduFast: return "速度优先"
        case .baiduText: return "通用文本 API"
        case .baiduImageOpen: return "高质量整图模式"
        case .deepL: return "配置 DeepL API"
        case .openAICompatible: return "配置 API 连接信息"
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.2.0"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "24"
        return "Screen Translator Pro · v\(version)-beta\(build)"
    }

    private func load() {
        baiduAppID = AppConfiguration.baiduAppID
        baiduSecret = SecretStore.shared.read(.baiduSecret) ?? ""
        deepLKey = SecretStore.shared.read(.deepLKey) ?? ""
        openAIKey = SecretStore.shared.read(.openAIKey) ?? ""
        openAIEndpoint = AppConfiguration.openAIEndpoint
        openAIModel = AppConfiguration.openAIModel
    }

    private func save() {
        UserDefaults.standard.set(
            baiduAppID,
            forKey: AppConfiguration.baiduAppIDKey
        )
        UserDefaults.standard.set(
            openAIEndpoint,
            forKey: AppConfiguration.openAIEndpointKey
        )
        UserDefaults.standard.set(
            openAIModel,
            forKey: AppConfiguration.openAIModelKey
        )

        do {
            try SecretStore.shared.write(baiduSecret, for: .baiduSecret)
            try SecretStore.shared.write(deepLKey, for: .deepLKey)
            try SecretStore.shared.write(openAIKey, for: .openAIKey)
            saveMessage = "已保存"
        } catch {
            saveMessage = error.localizedDescription
        }
    }
}
