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

### 🔒 安全与修复 (Fixes)

- **敏感内容不再泄漏**：敏感条目的 OCR 文本改为加密存储；短词搜索也无法再探测到敏感正文。
  *Sensitive content no longer leaks: OCR text of sensitive items is now stored encrypted, and short search queries can no longer probe sensitive bodies.*

- **同步不再丢失另一台设备的改动**：在 A 设备粘贴，不会再把 B 设备的收藏或删除覆盖掉。
  *Sync no longer loses edits from another device: pasting on device A no longer reverts a favorite or a deletion made on device B.*

- **删除与恢复行为一致**：从回收站恢复的条目重新可被搜索，重复复制已删除的内容不再产生两条相同记录。
  *Consistent delete and restore behaviour: restored items are searchable again, and re-copying deleted content no longer creates duplicates.*

- **数据库迁移不再回退版本号**：升级过的库不会被旧逻辑写回旧版本。
  *Migrations no longer regress the schema version: an upgraded database can no longer be written back to an older version.*

### 🚀 性能优化 (Performance)

- **历史变多后不再变慢**：4 万条库上单条保存 6.0ms → 1.3ms，批量写入 109s → 2.4s，不再随库增长退化；带搜索词的界面快照 116ms → 47ms。
  *No longer slows down as history grows: on a 40k-item library a single save drops from 6.0ms to 1.3ms and a batch from 109s to 2.4s, staying flat with size; a searched view snapshot drops from 116ms to 47ms.*

- **数据库文件不再无限膨胀**：清空历史后空间会真正回收，查询统计信息首次自动生成。
  *The database file no longer grows without bound: space is reclaimed after clearing history, and query-planner statistics are now generated automatically.*

- **耗时操作不再卡住界面**：清空历史、导入备份、启动清理都移到后台执行。
  *Long operations no longer freeze the UI: clearing history, importing backups and startup cleanup all run in the background.*

- **默认策略调整**：历史保留期改为半年，磁盘占用上限 5GB。
  *Default policy changes: history retention is now six months with a 5GB disk cap.*

### 🎨 界面与交互 (UI)

- **主面板新增环境光（Aurora）**：顶部薄雾与右侧冷暖光晕，跟随系统强调色；浅色模式按实测加深到刚好可见。
  *Panel ambient light (Aurora): a top mist and a cool/warm glow on the right, following the system accent colour; light-mode tiers were deepened to just-visible based on measurement.*

- **层级更清楚**：预览标题加大到 22pt，深色模式两列明度差拉开，正文限宽约 40 个汉字（此前宽窗口下一行排 80 字）。
  *Clearer hierarchy: the preview title is now 22pt, the columns separate more clearly in dark mode, and body text is capped at ~40 CJK characters per line (previously 80).*

- **灰字看得清了**：时间戳、来源行等辅助文字对比度从 2.8:1 提到 4.7:1 以上，达到 WCAG AA。
  *Muted text is now legible: timestamps and source lines go from 2.8:1 to above 4.7:1, meeting WCAG AA.*

- **若干状态显示修正**：批量模式勾选与预览锚点用底色/描边区分；图片 OCR 徽标显示真实状态（此前同屏两处说法矛盾）；类目变少时分类胶囊不再被拉宽。
  *Several state-display fixes: batch checked vs. preview anchor are now distinguished by fill and border; the image OCR badge reflects real state (it previously contradicted the card below it); category chips are no longer stretched when there are fewer categories.*

---

## [0.2.0] - 2026-10-16

### 🚀 性能优化 (Performance)

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