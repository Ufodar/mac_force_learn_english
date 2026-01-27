# Mac 单词/句子“定时置顶弹窗”最快实现（Hammerspoon）

这套方案不需要写完整 App：用 Hammerspoon 常驻后台，每隔一段时间弹出一个覆盖屏幕的置顶卡片（可盖住全屏窗口），几秒后自动消失。

## 1) 安装与授权

1. 安装 Hammerspoon：`brew install --cask hammerspoon`（或去官网下载安装）
2. 第一次打开会提示权限：在 **系统设置 → 隐私与安全性 → 辅助功能** 里勾选 **Hammerspoon**

## 2) 一键安装（推荐）

克隆并安装：

```bash
git clone https://github.com/Ufodar/mac_force_learn_english.git
cd mac_force_learn_english
bash install.sh
```

然后在 Hammerspoon 菜单里点 **Reload Config**（或 `⌘R`）生效。

> 说明：`install.sh` 会把 `vocab_overlay.lua` 安装到 `~/.hammerspoon/`，并在你的 `~/.hammerspoon/init.lua` 里（如缺失）追加一行启动代码；不会覆盖你已有的 `items.json/sentences.txt/wordlists`（若已存在则跳过拷贝）。

## 3) 数据源（可混用）

脚本会按权重混合选择：词库（默认更高）/句子/`items.json`。

### A. 词库（推荐：计算机 + 高中3500 + 四级 + 六级）

把单词一行一个放到这些文件里（支持 `word<TAB>中文释义` 或 `word || 中文释义`）：

- `~/.hammerspoon/data/wordlists/cs.txt`
- `~/.hammerspoon/data/wordlists/gaokao3500.txt`
- `~/.hammerspoon/data/wordlists/cet4.txt`
- `~/.hammerspoon/data/wordlists/cet6.txt`

权重在 `~/.hammerspoon/vocab_overlay.lua` 的 `config.sources.wordlists.categories` 里调。

如果你暂时没有这些词表，可以直接开启 **大模型生成模式**（见下方 3.5），不需要任何本地词库文件。

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

推荐用菜单栏 **EN → 设置…** 来配置（无需改代码）。等价的代码配置如下（仅供参考）：

```lua
llm = {
  enabled = true,
  protocol = "openai",  -- openai: 兼容 /v1/chat/completions；simple: 自己写一个 /vocab 接口
  mode = "generate",    -- generate: 不依赖本地词库，直接让模型生成；enrich: 给选中的词/句补全 back
  endpoint = "http://127.0.0.1:1234/v1/chat/completions",
  model = "your-model-name",
  apiKey = "",          -- 可留空，走环境变量 OPENAI_API_KEY
}
```

### `protocol = "openai"`（推荐）

不需要写后端，只要你的服务兼容 `POST /v1/chat/completions`（例如本地/自建的 OpenAI-compatible 服务）。
脚本会要求模型 **直接输出 JSON**（在 `message.content` 里），格式示例：

```json
{ "item": { "type": "word", "front": "algorithm", "back": "算法；…\\nExample: ...\\n译: ...", "meta": { "category": "cs" } } }
```

生成出来的内容会自动保存到：`~/.hammerspoon/data/generated_store.json`（包含已生成的词/句、复习次数、例句历史），并且会按 `newWordsBeforeReview` 规则穿插复习旧词（默认每 3 个新词插入 1 个旧词复习，可在菜单栏设置里改）。

### `protocol = "simple"`（你想自定义接口时）

你也可以自己写一个接口，例如 `endpoint = "http://127.0.0.1:3000/vocab"`，脚本发出的请求（示意）：

```json
{ "mode": "enrich", "item": { "type": "word", "front": "algorithm", "meta": { "category": "cs" } }, "preferences": { "language": "zh" } }
```

如果请求超时/失败，会自动回退到本地数据。

## 4) 使用与快捷键

Reload 后，菜单栏会出现 **VO**（Vocab Overlay）。

- 菜单栏 **VO**：
  - **设置…**：配置 LLM / 定时 / 复习插入规则
  - **复习模式**：主动复习旧词（不会自动消失；`N` 下一条；`Esc` 退出）
  - **勿扰模式**：定时弹窗不再打断你（仍可手动弹出/复习）
  - **查看统计**：已学单词/句子、复习次数、例句数

> 默认不启用全局快捷键（避免冲突）。如需开启，在 `~/.hammerspoon/vocab_overlay.lua` 里把 `config.hotkeys.enabled = true`。

- 弹窗显示时：
  - `Space`：显示/隐藏答案（back）
  - `N`：下一条（复习模式下为“下一条旧词”）
  - `E`：生成一个**新例句**（需要 LLM；会保存并复用）
  - `D`：切换勿扰模式
  - `Esc`：关闭弹窗
  - 鼠标点击卡片：显示/隐藏答案；点击黑色背景：关闭

## 5) 常用参数（在代码里改）

在 `~/.hammerspoon/vocab_overlay.lua` 顶部的 `config` 里改：

- `intervalSeconds`：间隔（秒），比如 `20*60`
- `displaySeconds`：每次停留时间（秒）
- `showBackByDefault`：是否默认显示 back
- `autoStart`：是否启动就开始定时弹出
- `sources.wordsWeight / sentencesWeight / itemsWeight`：三类来源的权重
- `llm.enabled / llm.protocol / llm.mode / llm.endpoint / llm.model / llm.timeoutSeconds`：大模型接入与超时
- `llm.generate.newWordsBeforeReview`：每 N 个新词插入 1 个旧词复习
- `storage.storeFile`：生成/复习记录保存位置
