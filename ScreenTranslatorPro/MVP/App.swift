import SwiftUI
import PhotosUI
import UIKit

@main
struct ScreenTranslatorProApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var translatedImage: UIImage?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var previewImage: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(originalImage == nil ? "选择截图测试" : "更换截图", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if let image = originalImage {
                        imageCard("原图", image)

                        Button {
                            Task { await translate(image) }
                        } label: {
                            if isWorking {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Label("翻译并原位回填", systemImage: "character.bubble")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)

                        if let translatedImage { imageCard("译图", translatedImage) }
                    } else {
                        ContentUnavailableView(
                            "Screen Translator Pro",
                            systemImage: "viewfinder",
                            description: Text("配置一次翻译服务后，可直接用快捷指令：截屏 → 翻译截图 → 快速查看，无需先打开 App。")
                        )
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("屏幕翻译")
            .toolbar {
                NavigationLink(destination: SettingsView()) { Image(systemName: "gearshape") }
            }
            .task(id: pickerItem) {
                guard let pickerItem else { return }
                do {
                    if let data = try await pickerItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        originalImage = image
                        translatedImage = nil
                        errorMessage = nil
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .onAppear(perform: presentPendingPreviewIfNeeded)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    presentPendingPreviewIfNeeded()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .translatedPreviewReady)) { _ in
                presentPendingPreviewIfNeeded()
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { previewImage != nil },
                    set: { if !$0 { dismissPreview() } }
                )
            ) {
                if let previewImage {
                    TranslatedPreviewView(
                        image: previewImage,
                        onClose: dismissPreview
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func imageCard(_ title: String, _ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @MainActor
    private func translate(_ image: UIImage) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            translatedImage = try await ScreenTranslationEngine().process(image: image).image
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    private func presentPendingPreviewIfNeeded() {
        guard previewImage == nil,
              let image = PreviewStore.loadPendingImage()
        else { return }

        previewImage = image
        PreviewStore.markPresented()
    }

    private func dismissPreview() {
        previewImage = nil
        PreviewStore.clear()
    }
}

private struct TranslatedPreviewView: View {
    let image: UIImage
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea(edges: .horizontal)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Text("关闭")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
        .statusBarHidden(false)
    }
}

struct SettingsView: View {
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

    private var providerBinding: Binding<ProviderKind> {
        Binding(
            get: { ProviderKind(rawValue: providerRaw) ?? .localOCR },
            set: { providerRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("翻译服务") {
                Picker("服务商", selection: providerBinding) {
                    ForEach(ProviderKind.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }

                TextField("源语言：auto / en / jp", text: $sourceLanguage)
                    .textInputAutocapitalization(.never)
                TextField("目标语言：zh / en / jp", text: $targetLanguage)
                    .textInputAutocapitalization(.never)
            }

            switch providerBinding.wrappedValue {
            case .localOCR:
                Section("本地 OCR 测试") {
                    Text("不联网，只验证 OCR、坐标与原位回填。")
                }

            case .baiduText:
                Section("百度通用文本翻译") {
                    TextField("APP ID", text: $baiduAppID)
                        .textInputAutocapitalization(.never)
                    SecureField("密钥", text: $baiduSecret)
                    Text("使用百度翻译开放平台通用文本翻译。")
                        .font(.footnote)
                }

            case .baiduImageOpen:
                Section("百度图片翻译") {
                    TextField("APP ID", text: $baiduAppID)
                        .textInputAutocapitalization(.never)
                    SecureField("Key", text: $baiduSecret)
                    Text("与百度翻译开放平台里的 APP ID + 密钥一致。使用图片翻译接口直接返回整张实景回填图，不经过本地 OCR 矩形覆盖。")
                        .font(.footnote)
                }

            case .deepL:
                Section("DeepL") {
                    SecureField("Auth Key", text: $deepLKey)
                        .textInputAutocapitalization(.never)
                }

            case .openAICompatible:
                Section("OpenAI-Compatible") {
                    SecureField("API Key", text: $openAIKey)
                        .textInputAutocapitalization(.never)
                    TextField("Chat Completions Endpoint", text: $openAIEndpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Model", text: $openAIModel)
                        .textInputAutocapitalization(.never)
                }
            }

            Section("快捷指令") {
                Text("新建捷径：① 截屏 ② Screen Translator Pro「翻译截图」。翻译完成后 App 会自动弹出自定义预览，关闭按钮在底部，不再需要“快速查看”。")
                    .font(.footnote)
            }

            Section {
                Button("保存 API 配置", action: save)
                if let saveMessage {
                    Text(saveMessage).font(.footnote)
                }
            }
        }
        .navigationTitle("设置")
        .onAppear(perform: load)
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
        UserDefaults.standard.set(baiduAppID, forKey: AppConfiguration.baiduAppIDKey)
        UserDefaults.standard.set(openAIEndpoint, forKey: AppConfiguration.openAIEndpointKey)
        UserDefaults.standard.set(openAIModel, forKey: AppConfiguration.openAIModelKey)

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
