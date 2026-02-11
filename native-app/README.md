# MacForceLearnEnglish（原生 macOS App）

目标：常驻菜单栏的原生 macOS App，定时弹出置顶覆盖卡片（单词/句子），并可接入 OpenAI-compatible LLM 现场生成（含音标与例句），支持复习/统计/勿扰。

## 快速构建（无需 Xcode）

前置：安装 Command Line Tools（系统一般自带，或执行 `xcode-select --install`）

在仓库根目录执行：

```bash
bash native-app/scripts/dist.sh
```

产物：
- `native-app/dist/MacForceLearnEnglish.dmg`
- `native-app/build/MacForceLearnEnglish.app`

## 安装（未签名/未公证）

1) 双击 `MacForceLearnEnglish.dmg`，拖动 `MacForceLearnEnglish.app` 到 Applications

2) 去掉隔离属性（你认可的安装方式）：

```bash
sudo xattr -rd com.apple.quarantine "/Applications/MacForceLearnEnglish.app"
```

3) 打开 App（首次打开建议先去 Settings 填 LLM 配置）

## 关于「每次更新都要重新授权 Accessibility / Input Monitoring」

如果你从源码构建（默认是 ad-hoc 签名），macOS 会把辅助功能/输入监控权限绑定到二进制的 `cdhash`，**每次重新编译都会变**，因此看起来像是“每次更新都要重新给权限”。要让权限能稳定保留，需要给 App 做一个**稳定的代码签名**：

- 推荐：使用 Apple Developer 账号的 `Developer ID Application` 证书（可用于分发，权限也更稳定）
- 仅本机自用：可以在「钥匙串访问」里创建一个本地 `Code Signing` 证书，然后用同一个证书给每次构建产物签名

本项目支持在构建时可选签名（如果你已经有证书）：

```bash
CODESIGN_IDENTITY="YOUR SIGNING IDENTITY" bash native-app/scripts/dist.sh
```

如果你有 Apple Developer Program，并想分发给别人使用（无需手动 `xattr`，权限也更稳定），建议走 Developer ID + Notarization：

```bash
# 1) 用 Developer ID 签名（hardened runtime + timestamp 会自动启用）
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash native-app/scripts/dist.sh

# 2) 一次性存凭据（App-Specific Password）
xcrun notarytool store-credentials "MacForceLearnEnglish-notary" \
  --apple-id "you@example.com" --team-id "TEAMID" --password "xxxx-xxxx-xxxx-xxxx"

# 3) Notarize + Staple（可直接 NOTARIZE=1 一步完成）
NOTARY_PROFILE="MacForceLearnEnglish-notary" NOTARIZE=1 bash native-app/scripts/dist.sh
```

另外，为了避免出现多个 `.app` 拷贝导致你误打开到 build 目录（从而权限对不上），`dist.sh` 默认会清理 build 产物；如果你想保留 build 产物用于本地运行：

```bash
KEEP_BUILD_APP=1 bash native-app/scripts/dist.sh
```

## 功能入口

- 菜单栏图标：`EN`
  - Show Now：立刻弹一次
  - Review：进入复习模式（不会自动消失）
  - Do Not Disturb：勿扰（定时弹窗暂停）
  - Quick Translate：划词翻译/问答（选中文本后按 `⌘⌥P` 翻译；按 `⌘⌥0` 弹出输入框提问；单词会带 IPA；支持 `More` 多释义；气泡点击关闭，不会自动消失）
  - Wordbook：单词本（你查过的单词）
  - Settings：配置 LLM/间隔/时长/类别/复习插入规则
  - Stats：简单统计

> 划词翻译需要系统授权：**系统设置 → 隐私与安全性 → 辅助功能**（必要）。部分机器可能还需要 **输入监控**。
