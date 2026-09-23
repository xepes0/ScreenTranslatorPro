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
                            description: Text("配置一次翻译服务后，可直接用快捷指令：截屏 → 翻译截图 → 快速查看。")
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
                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gearshape")
                }
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
}
