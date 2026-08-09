# Rimel — 基于 liberime 的轻量级 Emacs Rime 输入法[![MELPA](https://melpa.org/packages/rimel-badge.svg)](https://melpa.org/#/rimel)

Rimel 是一个轻量级的 Emacs 中文输入法，直接基于 [liberime](https://github.com/merrickluo/liberime) 动态模块，
使用 Emacs 内置的 `input-method-function` 接口和 `read-event` 循环（与 quail 相同的模式）。

## 特性

- 📦 **单文件**：仅 `rimel.el` 一个文件，约 700 行
- 🔌 **依赖少**：仅依赖 liberime（无需额外 C 模块）
- 🏗️ **原生集成**：使用 Emacs 内置 `input-method-function` + `register-input-method`
- 📋 **候选展示**：prompt 或 posframe 浮动窗口
- ✏️ **光标处编码 overlay**：输入时在光标处显示 preedit
- 📄 **翻页**：支持 `C-f/C-b`、`PgDn/PgUp` 等（完全可配置）
- ⏎ **Enter 英文上屏**：按 Enter 直接提交原始英文输入
- 🔢 **数字键/空格选候选**（由 rime 原生处理，无额外拦截）
- ⌨️ **所有按键可配置**：翻页、确认、取消、退格、选择键均可自定义 see rimel-keymap
- 🧠 **Predicates 断言**：根据上下文自动切换中/英文（代码区、字母后、evil 状态等）
- 💡 **点石成金**：`rimel-convert-string-at-point` 将光标前的拼音/编码转换为中文（移植自 pyim 金手指）
- ‼️ **标点全半角转换**：金手指同时支持光标处标点符号的半角⇄全角互换（含成对引号/书名号）

## 安装

### 前置条件

1. 安装 [librime](https://github.com/rime/librime)
2. melpa上安装 [liberime](https://github.com/merrickluo/liberime) 并确保可用。注意，如果出现 `liberime-` 相关报错（如 `Liberime: Fail to load liberime-core module, try to run command: (liberime-build)`，请查询liberime的README获取详细说明。

### 配置

```elisp 
;; 如果通过 melpa 等方式 安装的，应该不需要此部分
(add-to-list 'load-path "/path/to/rimel")
(add-to-list 'load-path "/path/to/liberime")

;; 如果自定义了用户数据，可通过此配置定制
;;(setq liberime-user-data-dir "") ;

;; 自动编译liberime 模块 详见 https://github.com/merrickluo/liberime
;;(setq liberime-auto-build t)

(require 'rimel)
(setq default-input-method "rimel")

;; 可选：指定输入方案
(setq rimel-schema "luna_pinyin_simp")

;; 可选：使用 prompt 展示候选（如果安装了 posframe,默认会使用 posframe）
(setq rimel-show-candidate 'prompt)

;; 可选：使用 posframe 展示候选
(setq rimel-show-candidate 'posframe)

;; horizontal or vertical
(setq rimel-posframe-style 'horizontal)

;; 自定义 posframe 属性 (可选)
(setq rimel-posframe-properties '(:left-fringe 10 :right-fringe 10))
```

## 按键说明

| 按键 | 功能 | 配置变量 |
|------|------|----------|
| `a-z` | 输入拼音 | — |
| `1-9` | 选择对应候选（由 rime 底层处理） | — |
| `Space` | 选择第一个候选 | `rimel-keymap` |
| `Enter` | 英文上屏 / 首选上屏 | `rimel-keymap` |
| `C-f` `PgDn` | 下一页 | `rimel-keymap` |
| `C-b` `PgUp` | 上一页 | `rimel-keymap` |
| `C-p` `C-n` | 上/下一个 | `rimel-keymap` |
| `C-k`  | send Shift+delete(从用户词典中删除) | `rimel-keymap` |
| `Backspace` | 删除最后一个字符 | `rimel-keymap` |
| `Escape`/`C-g` | 取消输入 | `rimel-keymap` |
| 其他键 | 退出输入法并执行原按键 | — |

### 按键配置示例

```elisp
;; 使用 C-v / M-v 翻页
(add-to-list 'rimel-keymap '("C-v" . "<next>"))
(add-to-list 'rimel-keymap '("M-v" . "<prior>"))

;; 双拼用户可能需要的一次删除两个字符
(add-to-list 'rimel-keymap '("C-<backspace>" . "<backspace><backspace>"))

```

## Predicates 断言（自动切换中英文）

Predicates 是一组函数，在每次按键时检查上下文，决定是否跳过中文输入直接输出英文。
配置 `rimel-disable-predicates` 列表，任一函数返回非 nil 即禁用中文。

### 内置断言

| 断言 | 说明 | 推荐度 |
|------|------|--------|
| `rimel-predicate-prog-in-code-p` | 在代码中（非注释/字符串）自动英文 | ★★★ |
| `rimel-predicate-after-alphabet-char-p` | 光标前是英文字母时自动英文 | ★★★ |
| `rimel-predicate-current-uppercase-letter-p` | 输入大写字母时自动英文 | ★★★ |
| `rimel-predicate-evil-mode-p` | evil normal/visual/motion 状态自动英文 | ★★★ |
| `rimel-predicate-after-ascii-char-p` | 光标前是 ASCII 字符时自动英文 | ★★ |
| `rimel-predicate-org-in-src-block-p` | 在 Org 源码块中自动英文 | ★★ |
| `rimel-predicate-org-latex-mode-p` | 在 Org LaTeX 片段中自动英文 | ★ |
| `rimel-predicate-tex-math-or-command-p` | 在 TeX 数学环境中自动英文 | ★ |

### 配置示例

```elisp
;; 推荐配置：代码区 + 字母后 + 大写字母
(setq rimel-disable-predicates
      '(rimel-predicate-prog-in-code-p
        rimel-predicate-after-alphabet-char-p
        rimel-predicate-current-uppercase-letter-p))

;; Evil 用户推荐
(setq rimel-disable-predicates
      '(rimel-predicate-prog-in-code-p
        rimel-predicate-after-alphabet-char-p
        rimel-predicate-current-uppercase-letter-p
        rimel-predicate-evil-mode-p))

;; Org 用户可以额外添加
(add-to-list 'rimel-disable-predicates 'rimel-predicate-org-in-src-block-p)
```

### 兼容性

断言函数签名与 emacs-rime 和 pyim 一致（无参数、返回 t/nil），
因此可以直接使用它们的断言函数：

```elisp
;; 使用 emacs-rime 的断言（需加载 rime-predicates）
(setq rimel-disable-predicates
      '(rime-predicate-prog-in-code-p
        rime-predicate-after-alphabet-char-p))

;; 使用 pyim 的探针（需加载 pyim-probe）
(setq rimel-disable-predicates
      '(pyim-probe-program-mode))
```

## 光标处编码转中文（点石成金）

`rimel-convert-string-at-point` 移植自 pyim 的 `pyim-convert-string-at-point`（金手指）：
删除光标前（或选中区域中）的编码字符串（如拼音），重新送入 rime 交互式转换为中文。
转换期间忽略 `rimel-disable-predicates`。

```elisp
(global-set-key (kbd "M-i") 'rimel-convert-string-at-point)
```

- 默认匹配的编码字符为 `a-z'`（含拼音隔音符，五笔同样适用），可用 `rimel-convert-valid-chars` 定制（regexp 字符类内容）。
- 光标前是 `'nihao` 这类字符串字面量时，开头的引号会被保留。
- 注意：pyim 金手指中的词库管理触发功能（`中文2` 加词、`中文2-` 删词、选中中文加词）未移植，因为 rime 自行管理用户词典，上屏时自动学习新词。

### 标点符号半角⇄全角转换

光标前是标点符号时，金手指命令在半角/全角之间来回切换（半角转全角、全角转半角）：

| 光标处文本 | 运行一次 | 再运行一次 |
|------------|----------|------------|
| `hello,`   | `hello，` | `hello,`   |
| `[{''\|}]`  | `【『‘’\|』】` | `[{''\|}]`  |

- 连续标点以光标为中心成对转换（上表第二行 `\|` 为光标位置），成对标点（引号、书名号等）自动交替开/闭形态。
- 光标后无标点时，只转换光标前的 1 个标点，重复运行可逐个往回转换。
- 标点映射表见 `rimel-punctuation-dict`，可自定义。
- 也可单独使用命令 `rimel-punctuation-translate-at-point`（切换光标前标点）或 `rimel-punctuation-translate`（指定方向转换）。

## 与 [emacs-rime](https://github.com/DogLooksGood/emacs-rime)、[pyim](https://github.com/tumashu/pyim) 的对比

### 架构对比

| | **Rimel** | **emacs-rime** | **pyim + pyim-liberime** |
|---|---|---|---|
| **依赖** | liberime | 自带 C 模块 (lib.c) | pyim 框架 + liberime |
| **代码量** | ~700 行 | ~1200 行 (rime.el) + C | ~6000 行 (pyim) + 326 行桥接 |
| **C 模块** | 无（复用 liberime） | 自带 lib.c | 无（复用 liberime） |
| **输入法接口** | `input-method-function` + `read-event` 循环 | `input-method-function` + minor mode | `input-method-function` + 独立框架 |
| **候选展示** | nil/prompt/posframe | minibuffer/popup/posframe/sidewindow | posframe/popup/minibuffer |
| **按键处理** | `read-event` 循环（类似 quail） | `overriding-terminal-local-map` | 独立事件系统 |

### 设计哲学

**Rimel** — *极简主义*
- 一个文件、一个依赖、无 C 代码
- 使用 `read-event` 循环，与 Emacs 内置 quail 完全相同的模式
- 不借助 pre-command-hook/post-self-insert-hook 等hook
- 合成过程自包含：函数进入时开始，返回时结束，无状态泄露
- 适合想要**最简单可用**的 rime 输入法的用户

**emacs-rime** — *功能完备*
- 自带 C 动态模块（lib.c），独立于 liberime
- 支持 5 种候选展示方式（minibuffer/message/popup/posframe/sidewindow）
- 支持 predicates 系统（自动根据上下文切换中英文）
- 支持 inline ASCII 模式
- 使用 minor mode + `overriding-terminal-local-map` 处理合成期间按键
- 适合需要**深度定制和高级功能**的用户

**pyim + pyim-liberime** — *框架化*
- pyim 是完整的输入法框架，liberime 只是其中一个后端
- 支持多种输入方案（全拼、双拼、五笔等），rime 只是其一
- 有独立的词频管理、词库、云输入等功能
- pyim-liberime 仅 326 行，本质是 `liberime-search()` 的薄包装
- 适合需要**多输入法统一管理**的用户

### 功能对比

| 功能 | Rimel | emacs-rime | pyim |
|------|:-----:|:----------:|:----:|
| 基本中文输入 | ✅ | ✅ | ✅ |
| 候选翻页 | ✅ | ✅ | ✅ |
| Enter 英文上屏 | ✅ | ✅ | ✅ |
| 多种候选展示 | prompt / posframe | 5 种 | 3 种 |
| Predicates 自动切换 | ✅ (8 个内置) | ✅ (20 个) | ✅ (probe) |
| Inline ASCII | ❌ | ✅ | ❌ |
| 多输入方案后端 | ❌ | ❌ | ✅ |
| 词频学习 | rime 内置 | rime 内置 | rime + pyim |
| 自定义按键 | ✅ 全部可配 | 部分 | 部分 |
| 零额外 C 代码 | ✅ | ❌ | ✅ |
| 安装复杂度 | 低 | 中 | 高 |

### 如何选择？

- **想要最简单、最轻量的 rime 体验（含 predicates）** → Rimel
- **需要 inline ASCII、多种候选 UI（5 种）** → emacs-rime
- **需要多输入法后端（五笔+拼音+rime）统一管理** → pyim

## License

GPL-3.0
