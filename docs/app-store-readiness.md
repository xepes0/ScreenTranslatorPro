# App Store 上架检查（2026-09-26）

## 代码侧已处理

- 主屏幕名称和用户可见品牌统一为「屏幕翻译」；Bundle ID 仍为 `com.xepes.ScreenTranslatorPro`。
- 删除未使用的 SpringBoardServices / LSApplicationWorkspace 私有 API 代码，保留系统「快速查看」流程。
- 增加 `PrivacyInfo.xcprivacy`，说明 App 内 `UserDefaults` 的用途。
- 设置页提供第三方翻译数据发送说明、逐服务授权、隐私政策链接和清除本机数据入口；未授权时 App 与快捷指令均阻止远程翻译请求。
- 构建号为 `1.0.0 (2)`，CI 核对显示名称、版本和隐私清单。

## 提交前仍需完成

1. 在 Apple Developer 账号中确认可注册或已注册 `com.xepes.ScreenTranslatorPro`，并在 App Store Connect 确认中文名称「屏幕翻译」可用。仓库无法验证账号状态或名称占用。
2. 使用 Apple Distribution 签名与 App Store 分发描述文件，从 Xcode 归档并上传至 App Store Connect。GitHub 的 `unsigned.ipa` 不能直接提交。
3. 在 App Store Connect 填写与代码一致的隐私问卷、隐私政策 URL、支持 URL、描述、年龄分级、出口合规等资料；审核截图需要真实展示运行中的 App。当前项目同时声明支持 iPhone 和 iPad，两种设备均需按要求测试和准备素材。
4. 在真机上验证首页与设置页、相册选图、所有拟宣传的翻译服务、首次授权与撤销授权、清除本机数据、快捷指令和系统快速查看。CI 编译成功不能代替真机与 App Store Connect 处理结果。
5. 确认第三方翻译服务的使用条款、数据处理方式与隐私政策表述一致；如审核需要访问付费或需配置的服务，在审核备注中提供可复现步骤或可用测试配置，不要公开 API 密钥。

## 现有发布说明

GitHub `v1.0.0` Release 中的 Build 1 是更名前的未签名版本。本次中文名称与隐私改动从 Build 2 开始，不应将 Build 1 当作待提交 App Store 的二进制。
