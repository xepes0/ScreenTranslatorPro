# ScreenTranslatorPro MVP build

当前测试分支：`dev/ipa-mvp`

## 目标流程

```
截屏
  ↓
快捷指令「翻译截图」
  ↓
Apple Vision OCR
  ↓
翻译 Provider
  ↓
按 OCR 坐标原位擦除/回填
  ↓
输出 PNG
```

首次只需打开 App 配置翻译服务。之后快捷指令本身不要求先打开 App。

## 当前 Provider

- 本地 OCR 测试（无需 API）
- 百度通用文本翻译
- DeepL
- OpenAI-Compatible Chat Completions

API 密钥写入 iOS Keychain。

## 快捷指令

新建捷径：

1. **截屏**
2. **Screen Translator Pro → 翻译截图**
3. **快速查看**

然后将捷径绑定到轻点背面 / Action Button / 控制中心。

## IPA

GitHub Actions 会生成 `ScreenTranslatorPro-unsigned.ipa`。它没有开发者签名，下载后使用你自己的 P12/mobileprovision 重签即可安装。

## 百度图片翻译

百度图片翻译 V2.0 将作为独立整图 Provider 加入。先让当前 MVP 在真机验证快捷指令、OCR 坐标和回填质量，再接 V2.0 返回的实景回填图。
