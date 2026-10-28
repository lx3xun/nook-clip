# NookClip Agent 开发与功能交付规范

本文件为 AI Agent 在 `nook-clip` 仓库中的强制执行规范。
**核心原则**：当用户要求「开发新功能」或「改动用户可见行为/交互/快捷键」时，Agent **不能只写代码就结束任务**，必须按本规范在同一任务流中自动完成**多语言、文案打磨、使用文档、三语 README、介绍页（落地页）、CHANGELOG 与测试**的全套闭环交付，无需等待用户二次提醒。

---

## 1. 新功能强制闭环清单（Definition of Done）

只要任务涉及**新功能**或**用户可见变更**，在交付（Yield）前必须逐项完成：

| 序号 | 交付项 | 触发条件 | 必改目标文件 |
| :--- | :--- | :--- | :--- |
| **1** | **代码与工程契约** | 新增/修改核心逻辑、配置、图标、快捷键或 UI | `crates/nookclip-core`、`crates/nookclip-ffi`、`UserDefaultsKey.swift`、`NookClipIcon.swift`、`PanelKeyActions.swift` |
| **2** | **客户端三语国际化** | 新增/修改任何 UI 文本、按钮、提示、设置项 | `platform/macOS/Sources/NookClip/Resources/{zh-Hans,zh-Hant,en}.lproj/Localizable.strings`（3 份必须同步） |
| **3** | **三语使用文档** | 新增独立功能、改变操作流或新增设置开关 | `site/docs/{,zh-Hant/,en/}<分类>/<feature>.md` + 对应 `README.md` 与 `_sidebar.md` + `reference/shortcuts.md`（3 语必须同步） |
| **4** | **三语 README** | 新增功能点、改变功能行为或增改快捷键 | `README.md`、`README.zh-TW.md`、`README.en.md`（3 份必须同步） |
| **5** | **产品介绍页（落地页）** | 新增核心卖点、功能卡片、快捷键或主界面变化 | `site/index.html` + `site/i18n.js`（简/繁/英三语字典） |
| **6** | **中英双语更新日志** | 任何功能新增、体验打磨、安全修复、性能优化 | `CHANGELOG.md` 的 `## [Unreleased]` 段落（严格遵循中英双语格式） |
| **7** | **自动化测试与验证** | 任何代码或页面改动 | `cargo test` + `swift test --package-path platform/macOS` |

> **禁止半成品交付**：严禁只改代码不改文档、只改简中不改繁中/英文、或漏改 `CHANGELOG.md`。

---

## 2. Agent 文案编写规范（UI 界面 · 文档 · 介绍页通用）

Agent 生成的所有用户可见文案（界面提示、设置项、文档、README、介绍页）必须遵守**「说人话、直接给结论、零技术黑话」**：

### 2.1 禁用黑话与直白替代表达
- **禁止**在面向用户的文案中暴露底层实现名词（如：`正则管道`、`内存态映射生命周期`、`事件拦截钩子`、`异步去抖动`、`序列化层`）。
- **必须**从用户视角写「什么时候触发 → 帮你做什么 → 怎么操作」：
  - ❌ 错误：`启用基于正则与校验和算法的内存态敏感数据语义替换管道`
  - ✅ 正确：`按 ⌃⏎ 粘贴时，自动把密钥、邮箱、卡号换成 <API_KEY_1> 等可读占位符`

### 2.2 界面文案尺寸与结构约束
- **设置项主标题**：2～6 个字，动宾或名词短语（例：`粘贴音效`、`终端安全粘贴`）。
- **设置项副标题（说明）**：一句话说明开启后的实际效果与边界，**不超过 30 个汉字**。
- **状态栏 / 预览区轻提示**：控制在单行以内，包含「检测结果 + 快捷键动作」（例：`检测到 2 处敏感信息（邮箱、API Key） · 按 ⌃⏎ 脱敏粘贴`）。
- **弹窗 / 拦截确认框**：标题直接说风险，正文列出命中原因，按钮动词明确（如 `安全粘贴` / `原样粘贴` / `取消`，严禁用含糊的 `确定` / `是` / `否`）。

### 2.3 三语固定术语对照表（严禁混用或机翻）

| 简体中文 (zh-Hans) | 繁體中文 (zh-Hant / zh-TW) | 英文 (en) | 禁用词 / 错误写法 |
| :--- | :--- | :--- | :--- |
| **剪贴板** | **剪貼簿** | **Clipboard** | ❌ 剪切板、粘貼板 |
| **粘贴 / 贴出** | **貼上** | **Paste** | ❌ 繁中写「粘貼」 |
| **设置** | **設定** | **Settings** | ❌ 繁中写「設置」、偏好设置 |
| **搜索 / 查找** | **搜尋** | **Search** | ❌ 检索（仅底层技术文档可用） |
| **快捷键** | **快捷鍵 / 捷徑** | **Shortcut** | ❌ 热键 |
| **访达** | **Finder** | **Finder** | ❌ 文件管理器 |
| **顺序粘贴栈（`⌥ ⏎`）** | **順序貼上佇列（`⌥ ⏎`）** | **Paste Stack (`⌥ ⏎`)** | ❌ 连续粘贴堆栈 |
| **语义脱敏粘贴（`⌃ ⏎`）** | **語義脫敏貼上（`⌃ ⏎`）** | **Scrubbed Paste (`⌃ ⏎`)** | ❌ 隐私掩码粘贴 |
| **屏幕置顶贴条（`⌘ P`）** | **螢幕置頂貼條（`⌘ P`）** | **Pin to Screen (`⌘ P`)** | ❌ 悬浮窗、便签 |
| **终端安全粘贴护栏** | **終端機安全貼上護欄** | **Terminal Safe-Paste** | ❌ 终端命令拦截器 |

---

## 3. 各文件更新细则

### 3.1 客户端多语言（`Localizable.strings`）
每次新增或修改 Swift UI 中的字符串，必须拒绝硬编码，使用本地化 Key 并同步写入：
1. `platform/macOS/Sources/NookClip/Resources/zh-Hans.lproj/Localizable.strings`
2. `platform/macOS/Sources/NookClip/Resources/zh-Hant.lproj/Localizable.strings`
3. `platform/macOS/Sources/NookClip/Resources/en.lproj/Localizable.strings`

- **Key 命名规范**：`<模块>.<子模块>.<语义>`，如 `settings.paste.terminal_guard`、`preview.scrub_banner`。
- **占位符一致**：三份文件中的 `%@`、`%d`、`%1$@` 数量与顺序必须完全一致。

### 3.2 三语功能使用文档（`site/docs/` · `site/docs/zh-Hant/` · `site/docs/en/`）
1. **新建或更新功能文档（简/繁/英三套目录必须同步更新）**：
   - 简体中文：`site/docs/<分类>/<feature>.md`
   - 繁體中文：`site/docs/zh-Hant/<分类>/<feature>.md`
   - 英文：`site/docs/en/<分类>/<feature>.md`
   - 分类目录：`getting-started/`、`advanced/`、`search-and-manage/`、`privacy-and-sync/`、`reference/`
2. **文档固定写作模板**（参照 `site/docs/advanced/terminal-safe-paste.md`）：
   - **标题 + 痛点引入**：用 2～3 句话描述真实使用场景里的痛点，以及该功能如何解决。
   - **1. 怎么触发 / 它怎么工作**：用表格或短列表讲清触发条件与操作方式。
   - **2. 核心交互与选项**：每个按钮或快捷键的实际效果。
   - **3. 安全边界（什么情况不介入）**：明确说明哪些场景放行、为什么不会误伤正常操作。
   - **4. 如何关闭或自定义**：指明「设置 → 某标签页」的具体开关位置。
3. **同步索引与侧边栏文件**：
   - 必改三语 `README.md` 与 `_sidebar.md`（以及 `site/docs/index.html` 中的 `BASE_DOC_PATHS` 搜索路径列表）。
   - 若涉及快捷键或 `Esc` 返回链：必改三语 `reference/shortcuts.md`。
   - 若涉及权限或常见疑问：必改三语 `reference/faq.md`。

### 3.3 三语 README 同步（根目录）
必须同时更新以下三份文件，保持章节结构与功能条目完全对齐：
- `README.md`（简体中文）
- `README.zh-TW.md`（繁体中文）
- `README.en.md`（英文）

**更新位置**：
1. **`## 功能一览` / `## Features`**：在对应子分类下新增或更新条目。写法：`- **功能名（快捷键）**：一句话讲清核心动作 + 关键细节与边界。`
2. **`## ⌨️ 快捷键指南` / `## ⌨️ Shortcuts`**：同步新增或修改快捷键行；若改动了 `Esc` 的关闭优先级，必须更新 `Esc` 分层返回说明。

### 3.4 介绍页更新（`site/`）
1. **`site/index.html` + `site/i18n.js`**：
   - 新增文案节点必须使用 `data-i18n="key"`（含 HTML 标签如 `<code>` 时使用对应的渲染约定），并在 `site/i18n.js` 的 `'zh-Hans'`、`'zh-Hant'`、`'en'` 三处同步添加翻译。
   - 若新功能包含快捷键，同步更新 `site/index.html` 中的快捷键流展示区及 `site/i18n.js` 中的 `sc_*` 词条。
2. **功能演示动图（仅当新增主打大功能或用户要求更新演示时）**：
   - 动画源码位于 `site/assets/features/src/scenes.js`（必须使用基于时间 `t` 的纯函数计算，严禁 CSS transition）。
   - 按 `site/assets/features/README.md` 规范生成 `1240×860` MP4、`820px` GIF 与 `poster-*.jpg` 封面图。

### 3.5 更新日志（`CHANGELOG.md`）
在 `## [Unreleased]` 下按分类（`### ✨ 功能特性 (Added)` / `### 🔒 隐私与安全 (Privacy & Security)` / `### 🎨 细节打磨 (Polish)` / `### 🚀 性能优化 (Performance)` / `### 🐛 问题修复 (Fixed)`）追加。
**严格格式要求**（`scripts/release.sh` 依赖此结构提取双语 Release Notes）：
```markdown
- **功能标题（快捷键）**：用自然、具体的中文讲清解决什么问题、怎么触发、有哪些防呆与边界细节。
  *Feature title (Shortcut): Clear, concrete English counterpart covering purpose, trigger, and edge-case guarantees.*
```

---

## 4. 工程与架构红线（Agent 严禁违反）

1. **配置 Key 集中登记（`UserDefaultsKey.swift`）**：
   - 新增任何 `@AppStorage` 或 `UserDefaults` 持久化配置项，严禁在视图或服务里写裸字符串，必须统一登记在 `platform/macOS/Sources/NookClip/UI/UserDefaultsKey.swift`。
2. **UI 图标与主题令牌契约（`NookClipIcon.swift` & `NookClipTheme.swift`）**：
   - 严禁在视图代码中直接硬编码 SF Symbol 裸字符串（`NookClipIconTests.swift` 会校验），必须先在 `NookClipIcon.swift` 登记常量并搭配 `NookClipIconSize` 尺寸阶梯。
   - 颜色、圆角、间距、字体必须引用 `NookClipTheme.swift` 与 `docs/DESIGN.md`，严禁硬编码魔术数字或私自添加非规范渐变。
3. **键盘事件路由与 `Esc` 分层返回链（`DraggablePanel` + `PanelKeyActions`）**：
   - 面板内快捷键统一通过 `DraggablePanel` → `PanelKeyActions.swift` → `MainView+Keyboard.swift` 在 AppKit 层分发，禁止在子视图零散挂载 `.keyboardShortcut` 导致抢焦点或按键冲突。
   - 新增任何浮层、弹窗或选中状态，必须接入 `Esc` 分层退出链（浮层 → 筛选面板 → 多选 → 搜索词 → 标签 → 分类 → 时间分组 → 收起面板），且不得破坏列表态「直接打字即搜索（`typeToSearch`）」。
4. **浮窗「不抢焦点」铁律（`.nonactivatingPanel`）**：
   - 任何新增辅助浮窗（如贴条、队列胶囊、提示 Toast）必须保持 `.nonactivatingPanel` 属性，严禁抢夺当前前台目标应用（终端、编辑器、浏览器）的输入焦点，否则会导致 `⌘V` 模拟粘贴失效。
5. **常驻内存与主线程性能红线（~20MB & 0ms 呼出）**：
   - 剪贴板捕获路径（`ClipboardMonitor`）、列表滚动与搜索严禁阻塞主线程；耗时任务（OCR、大文本高亮等）必须按需或后台异步执行，并确保通过 `SavePathQueryBudgetTests.swift` 与 `PerformanceBenchmarkTests.swift`。
6. **存储迁移、iCloud 同步与导出兼容**：
   - 若新功能修改了 `ClipboardItem` 字段或 SQLite 表结构（`crates/nookclip-core`），必须保证旧库平滑迁移，并同步检查 `HistoryStore+Sync.swift`（iCloud 同步）与 `HistoryStore+Exchange.swift`（JSON/Markdown 导出及敏感记录排除/遮码）。
7. **无障碍支持（Accessibility）**：
   - 新增纯图标按钮、状态徽标或自定义控件时，需补充 `.accessibilityLabel` / `.accessibilityHint`（多语言词条同样放入 `Localizable.strings`）。
8. **隐私底线**：
   - 严禁引入任何联网请求、遥测打点或第三方统计 SDK；敏感数据明文严禁写入 SQLite FTS5 全文索引、日志或 iCloud 同步目录。
9. **UniFFI 版本锁定与 macOS 兼容性**：
   - Workspace 中 `uniffi` 严格锁定 `0.28.3`（兼容 Windows `uniffi-bindgen-cs`），严禁升级。修改 Rust FFI 接口后必须执行 `zsh scripts/build-rust.sh` 重新生成桥接文件。
   - 使用 macOS 15+ 专属 API（如 `TextRenderer`、`TextAttribute`）时，必须同时包裹 `#if compiler(>=6.0)` 与 `@available(macOS 15.0, *)`，确保 Xcode 15 / macOS 14 CI 构建通过。
10. **测试隔离与必跑验证**：
   - 剪贴板相关测试必须包裹 `withPasteboardLock { }`，严禁在测试中直接读写 `NSPasteboard.general`。
   - 配置项测试必须使用 `makeIsolatedDefaults()` 注入。
   - 交付前必须实际运行并通过：`cargo test`（若改 Rust）与 `swift test --package-path platform/macOS`。
