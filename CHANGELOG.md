# 更新日志 (Changelog)

所有关于 **NookClip** 项目的重要功能迭代与修复记录于此。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/)。

### 📝 写入规范 (Writing Guidelines)

为了保证 GitHub / Gitee Releases 及应用内发版说明自动呈现中英双语，维护此文件时请遵循以下规范：
1. **标题分类**：分类标题保持中英对照，例如 `### 🚀 性能优化 (Performance)`、`### ✨ 功能特性 (Added)`、`### 🔒 安全与修复 (Fixes)`。
2. **条目书写**：每个功能或修复项，第一行为中文说明，紧随其下一行使用缩进并加斜体提供英文对照（`  *English description here.*`）。
3. **格式示例**：
   ```markdown
   ### 🚀 性能优化 (Performance)

   - **大幅降低常驻内存**：后台常驻内存从 ~106MB 优化至 ~19MB。
     *Significantly reduced idle memory from ~106MB to ~19MB.*
   ```

---


## [Unreleased]

### 🚀 性能优化 (Performance)
- **锚点时间分组改为 SQL 内聚合**：时间导航锚点不再把全库 `last_used_at` 搬进内存再逐条换算时区，改为按本地日/周/月边界在 SQLite 内直接分桶（`time_group_anchor_counts`）；分组结果与旧算法逐项一致（含 UTC+8 / UTC-5 校验用例）。
  *Timeline anchor counts now aggregate inside SQLite against precomputed local day/week/month boundaries instead of transferring the full timestamp set into memory and converting each entry; grouping output verified identical to the previous algorithm across multiple time zones.*

- **淘汰与驱逐批量化**：保留期清理与磁盘配额驱逐从每条约 5 条 SQL（2500 次/500 条）降为每 100 条一次集合操作；FTS 维护改用已取出的 rowid 数字，去掉 `(SELECT rowid …)` 全表子查询。
  *Retention pruning and disk-limit eviction now run chunked set-based SQL instead of ~5 statements per item; FTS maintenance uses the already-fetched rowid, eliminating full-table subqueries.*

- **批量粘贴与文本摄取去重**：批量粘贴一次 `WHERE id IN (...)` 取回全部条目摘要，替代逐 ID 查询；文本摄取复用首次敏感检测结论，非敏感分支不再重复跑同一套敏感正则。
  *Batch paste now fetches all item summaries in a single `WHERE id IN (…)` query instead of one query per id; text ingest reuses the first sensitivity detection result so the non-sensitive branch no longer re-runs the same pattern set.*

- **消除热路径堆分配**：搜索高亮把逐字符 `to_lowercase()` 堆分配改为整段一次小写 + 段区间反查；语言识别对静态大小写不敏感标记改预算小写查找表；时间线分组的「上周」基准提到循环外一次推导。
  *Removed hot-path heap allocations: search highlight lowercases the whole text once and maps hits back to character ranges instead of allocating a String per character; language detection uses a precomputed lowercase lookup for static case-insensitive markers; the "last week" reference in timeline grouping is now derived once outside the loop.*

- **交互响应优化**：应用搜索索引首次构建移出主线程（输入即有结果到达前不再阻塞）；预览区完整实体改为按条目异步加载一次并缓存，单帧不再重复跨 FFI 查库；滚动期行坐标写入引用容器，吸顶组经节流合并为一次性状态更新（根视图不再以帧率重求值）；列表行相对时间构造期算一次。
  *Interaction responsiveness: the app-search index is now built off the main thread; the preview pane loads the full entity once per item asynchronously and caches it instead of querying across FFI multiple times per frame; row frames are stored in a reference container during scrolling with throttled sticky-group updates, so the root view no longer re-evaluates at frame rate; list rows precompute their relative timestamp once.*

- **启动与后台 IO 移出主线程**：孤儿载荷清理、Keychain 口令读取、文件存在性与系统图标加载全部改为后台执行；语法高亮行缓存满容时整体淘汰并接入面板闲置回收，搜索高亮缓存同步清理。
  *Startup and background IO moved off the main thread: orphan payload sweeping, Keychain passphrase reads, file existence checks and system icon loading all run in background tasks; the syntax-highlight line cache evicts when full and is cleared on panel idle reclaim, alongside the search-highlight cache.*

- **调整历史保留天数与磁盘限额默认值**：历史保留天数默认值调整为半年（180 天，原为 30 天）；磁盘空间上限默认值调整为 5GB（5120MB，原为无限制），防止媒体载荷长期累积占满磁盘。
  *Default storage policy adjustments: History retention default changed to 6 months (180 days, previously 30 days); disk space limit default changed to 5GB (5120MB, previously unlimited) to prevent unbounded asset accumulation.*

- **大幅降低常驻内存**：后台常驻内存从 ~106MB 优化至 ~19MB（实测峰值 181MB → 19.6MB），开启常用功能后仍稳定在 ~60MB 以内。
  *Significantly reduced idle memory from ~106MB to ~19MB (tested peak 181MB → 19.6MB), staying well within ~60MB during typical daily usage.*
- **OCR 改为独立短生命周期子进程按需执行**：识别引擎的神经网络与 Metal 权重不再驻留主进程，识别完成退出即 100% 回收 ~35MB 内存。
  *Moved OCR to an on-demand, short-lived subprocess: Neural network and Metal weights no longer linger in the main process, fully reclaiming ~35MB upon completion.*
- **应用搜索改为输入时按需构建**：纯英文应用名走 ASCII 快路，不触发 ICU 汉字转拼音表加载；面板闲置后释放缓存。
  *On-demand app search index on input: English app names take the fast ASCII path without loading ICU Pinyin tables, with cache eviction upon panel idle.*
- **偏好设置窗口关闭即释放视图树**，下次打开按需重建，回收 ~15~25MB。
  *Preference window view tree is now deallocated immediately upon closing and rebuilt on demand, saving ~15–25MB.*
- **SQLite 页缓存上限收紧至 512KB**（默认约 8MB），并在面板闲置后压缩历史内存镜像。
  *Tightened SQLite page cache cap to 512KB (down from ~8MB default) and compacted history memory buffers when the panel is idle.*
- **面板收起闲置自动回收**：释放隐藏面板视图树、缩略图、代码高亮与图标缓存。
  *Automatic idle garbage collection on panel hide: cleans up hidden view trees, thumbnails, code syntax highlights, and icon caches.*
---

## [0.1.1] - 2026-10-16

### 🔒 安全与修复 (Fixes)

- **首启面板呼出防闪退**：首次启动引导呼出面板加入 3 秒防失焦保护，使用 `ignoringOtherApps` 强制激活，避免系统授权弹窗抢焦导致面板闪退。
  *First-launch panel dismissal fix: Added a 3-second focus protection window and forced activation with `ignoringOtherApps` to prevent the panel from disappearing during system permission prompts.*
- **示例数据播种与重置**：生产数据库首次创建时彻底重置残留标记，并在「设置 -> 历史记录」中增加手动「导入示例数据」入口。
  *Sample data seeding & reset: Cleanly reset legacy flags when creating the production database, and added a manual "Import Sample Data" button in Settings.*
- **时间快速跳转菜单互斥**：吸顶组头下拉菜单受 `timelineJumpMode` 配置统一控制，避免与时间锚点微轨同时显示产生视觉重叠。
  *Timeline jump menu conflict: Pinned header dropdown is now synchronized with `timelineJumpMode`, avoiding duplicate UI with the timeline mini-rail.*
- **辅助功能横幅文案截断**：未授权辅助功能提示横幅的跳转按钮文案精简为「去设置」，解决小窗口尺寸下提示文字被省略号截断的问题。
  *Accessibility banner truncation: Shortened action button label to prevent prompt text truncation in compact window modes.*

---

## [0.1.0] - 2026-10-15

首个正式公开发布版本。基于 macOS 14+ 原生 SwiftUI + AppKit 与 Rust 核心引擎打造，内存占用低至 ~20MB，数据严格保留在本机。  
*Initial public release. Built with native macOS 14+ SwiftUI, AppKit, and a Rust core engine. Lightweight memory footprint (~20MB) with 100% on-device data privacy.*

### ✨ 功能特性 (Added)

- **全局悬浮面板**：默认 `⌘ ⇧ V` 快捷唤出，随选随粘，失焦或 `Esc` 自动收起；支持长按快速连选与多套常用键位预设。
  *Global floating panel: Default `⌘ ⇧ V` hotkey, paste-on-click, auto-dismiss on blur or `Esc`, with long-press continuous selection and customizable shortcut presets.*
- **全格式剪贴板记录**：自动记录文本、富文本、网址链接、图片、文件（含 Finder 多选）、十六进制色值与代码，自动去重并按时间分组。
  *All-format clipboard history: Automatically tracks plain text, rich text, URLs, images, Finder files, hex colors, and code with deduplication and timeline grouping.*
- **打字即搜与拼音启动应用**：呼出面板直接键盘输入检索历史，支持中文拼音首字母缩写搜应用（如 `wx` 启动微信）。
  *Type-to-search & Pinyin app launcher: Search history instantly by typing on panel open, with Pinyin abbreviation support to launch apps directly.*
- **本地全文搜索与智能过滤**：基于 SQLite FTS5，支持拼音/前缀检索、OCR 文字搜索与 `from:` / `app:` / `lang:` 等结构化过滤。
  *Local FTS5 full-text search: Prefix/Pinyin matching, OCR text queries, and structured token filters (`from:`, `app:`, `lang:`).*
- **离线 OCR 与高亮预览**：基于 Apple Vision 框架离线识别截图文字，支持在图上直接高亮划词复制；代码与 JSON 语法高亮与格式化。
  *Offline OCR & preview: On-device text recognition via Apple Vision with in-image text highlighting; code/JSON syntax highlighting and beautifier.*
- **网址生成二维码**：识别到网址后支持在预览区一键生成二维码，方便手机扫码打开。
  *URL to QR code: Generates scannable QR codes for links directly in the preview pane.*
- **端到端敏感凭证防护**：自动识别 API Key、密码、Token 并掩码遮蔽；AES-256-GCM 本地加密，密钥由钥匙串保管，绝不上云。
  *Sensitive credential protection: Auto-detects and masks secrets/tokens; encrypted with AES-256-GCM via Keychain, excluded from cloud sync and FTS index.*
- **应用黑名单**：支持将 1Password、密码管理器等敏感应用加入黑名单，切到前台时自动暂停记录。
  *Application blacklist: Exclude password managers and sensitive apps from recording.*
- **高效粘贴与批量操作**：`⏎` 原始粘贴、`⌥ ⏎` 纯文本粘贴、`⌘ ⏎` 连续粘贴；支持 `⇧ ↑/↓` 批量多选、合并粘贴与 10 秒撤销。
  *Quick paste & batch actions: `⏎` direct paste, `⌥ ⏎` plain text paste, `⌘ ⏎` continuous paste; multi-selection, merge paste, and 10s undo (`⌘ Z`).*
- **条目别名与收藏**：支持按 `⌘ R` 自定义条目别名，按 `⌘ S` 标记收藏（永久保留，豁免清理）。
  *Aliases & Favorites: Custom aliases (`⌘ R`) and pinned favorites (`⌘ S`) exempt from automated cleanup.*
- **端侧 iCloud 同步**：通过个人 iCloud 云盘跨 Mac 设备安全双向同步，敏感数据严格排除。
  *Private iCloud sync: Bidirectional cross-Mac synchronization via personal iCloud Drive, with sensitive items strictly excluded.*
- **应用内自动更新与音效**：Sparkle 安全自动更新（EdDSA 签名校验）与可选的轻量粘贴音效。
  *In-app updates & audio: Automated updates via Sparkle with EdDSA signatures, plus optional haptic/audio feedback.*
- **灵活外观与多语言**：双栏/折叠布局切换、透明度调节，内置简体中文、繁体中文与英文。
  *Flexible appearance & localization: Dual-pane or compact modes, window opacity slider, localized in Simplified Chinese, Traditional Chinese, and English.*

### 🔒 安全与修复 (Fixes)

- **密钥安全加固**：生产数据库采用安全密钥文件与钥匙串双重保护，彻底阻断敏感明文同步及未加密回退漏洞。
  *Key security hardening: Dual protection via Keychain and secure keyfile, blocking plaintext sync and unencrypted fallback loopholes.*
- **同步与索引一致性**：修复删除条目云端多设备复活、LWW 冲突更新错位及 FTS 索引同步失效问题。
  *Sync & index consistency: Resolved resurrecting deleted items, LWW conflict misalignments, and FTS sync drift.*
- **性能与稳定性**：iCloud 同步与磁盘限额维护完全移至后台，优化大图/大文本预览截断，避免主线程阻塞。
  *Performance & stability: Offloaded iCloud sync and quota maintenance to background threads; optimized large media previews.*
- **交互与快捷键修复**：面板快捷键分发统一收敛至 AppKit 层，消除搜索框持焦时的按键吞没与焦点抖动。
  *Event routing: Unified panel keyboard dispatch at the AppKit layer, resolving key capture jitter during search field focus.*