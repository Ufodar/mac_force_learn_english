# MacForceLearnEnglish（原生 macOS App）

目标：不用 Hammerspoon，直接运行一个常驻菜单栏的原生 App，定时弹出置顶覆盖卡片（单词/句子），并可接入 OpenAI-compatible LLM 现场生成（含音标与例句），支持复习/统计/勿扰。

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

## 功能入口

- 菜单栏图标：`EN`
  - Show Now：立刻弹一次
  - Review：进入复习模式（不会自动消失）
  - Do Not Disturb：勿扰（定时弹窗暂停）
  - Quick Translate：划词翻译（默认：选中文本后按 `⌘⌥P` 翻译；单词会带 IPA）
  - Wordbook：单词本（你查过的单词）
  - Settings：配置 LLM/间隔/时长/类别/复习插入规则
  - Stats：简单统计

> 划词翻译需要系统授权：**系统设置 → 隐私与安全性 → 辅助功能**（必要）。部分机器可能还需要 **输入监控**。
