# Mac 单词/句子“定时置顶弹窗”最快实现（Hammerspoon）

这套方案不需要写完整 App：用 Hammerspoon 常驻后台，每隔一段时间弹出一个覆盖屏幕的置顶卡片（可盖住全屏窗口），几秒后自动消失。

## 1) 安装与授权

1. 安装 Hammerspoon：`brew install --cask hammerspoon`（或去官网下载安装）
2. 第一次打开会提示权限：在 **系统设置 → 隐私与安全性 → 辅助功能** 里勾选 **Hammerspoon**

## 2) 放置配置

把本目录下 `hammerspoon/` 里的文件放到你的 `~/.hammerspoon/`：

```bash
mkdir -p ~/.hammerspoon/data
cp -R mac-vocab-overlay/hammerspoon/* ~/.hammerspoon/
```

如果你已经有自己的 `~/.hammerspoon/init.lua`，不要覆盖它，只需要把 `vocab_overlay.lua` 和 `data/items.json` 复制进去，然后在你自己的 `init.lua` 里加一行：

```lua
require("vocab_overlay").start()
```

## 3) 数据源（可混用）

脚本会按权重混合选择：词库（默认更高）/句子/`items.json`。

### A. 词库（推荐：计算机 + 高中3500 + 四级 + 六级）

把单词一行一个放到这些文件里（支持 `word<TAB>中文释义` 或 `word || 中文释义`）：

- `~/.hammerspoon/data/wordlists/cs.txt`
- `~/.hammerspoon/data/wordlists/gaokao3500.txt`
- `~/.hammerspoon/data/wordlists/cet4.txt`
- `~/.hammerspoon/data/wordlists/cet6.txt`

权重在 `~/.hammerspoon/vocab_overlay.lua` 的 `config.sources.wordlists.categories` 里调。

### B. 句子

编辑：`~/.hammerspoon/data/sentences.txt`（一行一句；可选加翻译：`英文<TAB>中文`）

### C. 结构化条目（items.json）

编辑：`~/.hammerspoon/data/items.json`（数组，每一项有 `front`/`back`；`back` 可空）

格式示例（数组，每一项有 `front`/`back`；`back` 可空）：

```json
[
  { "type": "word", "front": "serendipity", "back": "机缘巧合；意外发现美好事物" },
  { "type": "sentence", "front": "Consistency beats intensity.", "back": "持续胜过爆发。" }
]
```

## 3.5) 可选：接入大模型（自动补全释义/例句）

你可以在 `~/.hammerspoon/vocab_overlay.lua` 里开启：

```lua
llm = {
  enabled = true,
  mode = "enrich", -- enrich: 给选中的词/句补全 back；generate: 让模型直接生成新条目
  endpoint = "http://127.0.0.1:3000/vocab",
  apiKey = "",
}
```

推荐你的接口返回：

```json
{ "item": { "type": "word", "front": "algorithm", "back": "算法；…\\n例句：…" } }
```

脚本发出的请求（示意）：

```json
{ "mode": "enrich", "item": { "type": "word", "front": "algorithm", "meta": { "category": "cs" } }, "preferences": { "language": "zh" } }
```

如果请求超时/失败，会自动回退到本地数据。

## 4) 使用与快捷键

在 Hammerspoon 菜单里点 **Reload Config**（或 `⌘R`）后生效。

- `Ctrl+Alt+Cmd+V`：立刻弹出下一条
- `Ctrl+Alt+Cmd+T`：开/关定时弹出
- `Ctrl+Alt+Cmd+I`：重新加载本地数据（词库/句子/items.json）
- 弹窗显示时：
  - `Space`：显示/隐藏答案（back）
  - `Esc`：关闭弹窗
  - 鼠标点击卡片：显示/隐藏答案；点击黑色背景：关闭

## 5) 常用参数（在代码里改）

在 `~/.hammerspoon/vocab_overlay.lua` 顶部的 `config` 里改：

- `intervalSeconds`：间隔（秒），比如 `20*60`
- `displaySeconds`：每次停留时间（秒）
- `showBackByDefault`：是否默认显示 back
- `autoStart`：是否启动就开始定时弹出
- `sources.wordsWeight / sentencesWeight / itemsWeight`：三类来源的权重
- `llm.enabled / llm.mode / llm.endpoint / llm.timeoutSeconds`：大模型接入开关与超时
