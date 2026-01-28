# MacForceLearnEnglish

一个常驻菜单栏（`EN`）的 macOS 小工具：定时弹出置顶覆盖卡片，强制你背单词/句子；支持接入 OpenAI-compatible LLM 现场生成（含音标/例句），支持复习/统计/勿扰；支持划词翻译气泡。

## 功能

- 定时弹出：覆盖所有窗口（含全屏）置顶显示
- LLM 生成：单词（含 IPA 音标+释义+例句）/句子（含翻译），自动去重并保存
- 复习模式：手动刷旧词（不会自动消失）
- 勿扰模式：暂停定时弹窗
- 划词翻译：选中文本后按 `⌘⌥P` 弹出翻译气泡（单词会带 IPA；可在 Settings 切换为自动）
- 单词本：查看你查过的单词（Wordbook）
- 简约设置：在 App 内配置 LLM/间隔/类别等

## 安装（推荐 DMG）

1) 在 GitHub Releases 下载 `MacForceLearnEnglish.dmg`  
2) 打开 DMG，把 `MacForceLearnEnglish.app` 拖到 `/Applications`  
3) 去掉隔离属性（未签名/未公证的安装方式）：

```bash
sudo xattr -rd com.apple.quarantine "/Applications/MacForceLearnEnglish.app"
```

4) 打开 App → 菜单栏 `EN → Settings…` 配置 LLM（endpoint / model / apiKey）

> 划词翻译需要系统授权：**系统设置 → 隐私与安全性 → 辅助功能** 勾选 `MacForceLearnEnglish`（必要），部分机器可能还需要 **输入监控**。

## 使用

- 菜单栏 `EN`
  - `Show Now`：立刻弹一次
  - `Review`：进入复习模式（不会自动消失）
  - `Do Not Disturb`：勿扰（定时暂停）
  - `Quick Translate`：划词翻译开关
  - `Quick Translate Status`：查看权限/安装路径/是否有重复拷贝
  - `Wordbook`：查看查过的单词
  - `Settings…`：配置 LLM/间隔/类别/复习插入规则
  - `Stats`：简单统计

- 弹窗时按键
  - `Space`：显示/隐藏释义
  - `N`：下一条
  - `E`：生成新例句（会保存复用）
  - `D`：切换勿扰
  - `Esc`：关闭

## 构建（从源码，无需 Xcode）

```bash
bash native-app/scripts/dist.sh
open native-app/dist/MacForceLearnEnglish.dmg
```

## 数据与架构（简述）

- 入口：`native-app/`
- 数据保存：`~/Library/Application Support/MacForceLearnEnglish/store.json`
- LLM：支持 `/v1/chat/completions` 或 `/v1/completions`（按 endpoint path 自动判断）

## 旧方案

- Hammerspoon 版本（可选）：`hammerspoon/README.md`
