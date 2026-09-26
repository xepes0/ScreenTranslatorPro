# 屏幕翻译

一款 iOS 截图翻译工具：识别截图中的文字，翻译后在原位置绘制译文。

## 使用方式

1. 在 App 的设置页选择翻译服务、语言并保存 API 配置。
2. 在主页选择截图，点击「翻译这张截图」，可切换查看原图和译图。
3. 如需在其他 App 中使用，创建快捷指令：**截屏 → 屏幕翻译「翻译截图」→ 快速查看**，再绑定背部轻点等触发方式。

本地 OCR 模式仅用于文字识别；如需译文，请选择并配置翻译服务。API 密钥保存在 iOS Keychain。

使用第三方翻译服务前，设置页会说明发送的内容并要求明确同意。详见[隐私政策](PRIVACY.md)。

## 下载与构建

[Releases](https://github.com/xepes0/ScreenTranslatorPro/releases) 提供未签名 IPA，需要使用自己的证书与描述文件签名后安装。项目最低支持 iOS 18.0。

项目使用 XcodeGen。安装 XcodeGen 后运行 `xcodegen generate`，再通过 Xcode 打开生成的项目。GitHub Actions 会构建未签名 IPA。
