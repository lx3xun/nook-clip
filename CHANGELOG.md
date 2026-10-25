# 更新日志 (Changelog)

所有关于 **NookClip** 项目的重要功能迭代与修复记录于此。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，遵循 [语义化版本 2.0.0](https://semver.org/lang/zh-CN/)。

### 📝 写入规范 (Writing Guidelines)

为了保证 GitHub / Gitee Releases 及应用内发版说明自动呈现中英双语，维护此文件时请遵循以下规范：

1. **标题分类**：分类标题保持中英对照，例如 `### 🚀 性能优化 (Performance)`、`### ✨ 功能特性 (Added)`、`### 🔒 安全与修复 (Fixes)`。
2. **条目书写**：每个功能或修复项，第一行为中文说明，紧随其下一行使用缩进并加斜体提供英文对照（  `*English description here.*`）。
3. **格式示例**：
   ```markdown
    ### 🚀 性能优化 (Performance)
   
    - **大幅降低常驻内存**：后台常驻内存从 ~106MB 优化至 ~19MB。
      *Significantly reduced idle memory from ~106MB to ~19MB.*
   ```

---

## [Unreleased]

### 🔒 隐私与安全 (Privacy & Security)

- **全品类语义脱敏粘贴（⌃⏎）**：密钥、手机号、身份证、银行卡、IBAN、邮箱、IP、主机名与家目录路径等 19 类敏感信息，按 `⌃⏎` 粘贴时自动换成 `<API_KEY_1>`、`<EMAIL_1>` 这类语义占位符；同一段内容里的相同值共享编号，不同值依次递增。银行卡走 Luhn、身份证走 ISO 7064 MOD 11-2、IBAN 走 MOD-97 校验，`127.0.0.1`、`/Users/Shared`、ISO 时间戳等日常文本不会被误伤。
  *Semantic redaction on paste (⌃⏎): 19 built-in rule types — keys, phone numbers, national IDs, bank cards, IBANs, emails, IPs, hostnames and home-directory paths — are replaced with readable placeholders such as `<API_KEY_1>` and `<EMAIL_1>`. Identical values share a number while distinct values increment. Bank cards use Luhn, national IDs use ISO 7064 MOD 11-2 and IBANs use MOD-97, so everyday text like `127.0.0.1`, `/Users/Shared` and ISO timestamps is left untouched.*
- **一键还原真实值（⌃⇧⏎）**：把带占位符的文本交给 AI 或同事后，复制回来的内容若含活跃占位符，预览区顶部会提示「检测到 N 个脱敏占位符」，按 `⌃⇧⏎` 即还原成真实值再粘贴。
  *One-key restore (⌃⇧⏎): after handing placeholder text to an AI or a colleague, any clipboard content still containing active placeholders triggers a "N redaction placeholders detected" banner in the preview pane — press ⌃⇧⏎ to restore the real values before pasting.*
- **粘贴前提醒**：选中一条含密钥、邮箱、卡号等敏感内容的记录时，预览区顶部出现一行「检测到 N 处敏感信息（邮箱、API Key）」并给出 `⌃⏎` 脱敏粘贴入口，不必先按一次快捷键才发现自己贴出去了什么。提示不弹窗、不拦截粘贴，只在选中时出现；可在「设置 → 隐私」里关掉。
  *Hint before pasting: selecting an item that contains keys, emails, card numbers or similar sensitive data shows a single line at the top of the preview pane — "N sensitive items found (email, API key)" — with a ⌃⏎ Scrubbed-paste shortcut right there, so you no longer have to paste once to find out what you leaked. No dialog, no blocked keystrokes: the hint only appears on selection and can be switched off in Settings → Privacy.*
- **映射表只活在内存里**：占位符与真实值的对应关系仅驻留当前进程，不写数据库、不写日志；闲置默认 30 分钟自动销毁，设置页可随时一键清空。
  *Mapping table lives only in RAM: placeholder-to-value pairs never reach SQLite or logs, expire after 30 minutes of inactivity by default, and can be wiped instantly from Settings.*
- **离线识别人名与地址**：借助 macOS 自带语言模型在本机识别人名与地名，全程不联网、不上传任何内容，可在设置页关闭。
  *Offline name and address detection: uses macOS's on-device language model locally. Nothing leaves the machine, and it can be switched off in Settings.*
- **隐私与脱敏设置页**：按「凭据与密钥 / 网络与主机 / 个人隐私」三组独立开关 19 类规则，支持增删改自定义规则（关键词或正则 + 自定义占位符标签），并实时显示当前内存映射数。
  *Privacy & redaction settings: the 19 rules are grouped into credentials, network & host, and personal PII with independent switches, complemented by custom rules by keyword or regex with your own placeholder tag and a live in-memory mapping count.*

### ✨ 功能特性 (Added)

- **顺序粘贴栈（⌥⏎）**：多选若干条后按 `⌥⏎`，它们会按**你复制的先后顺序**排队（最早复制的排第一，与列表里「最新在前」的显示顺序刻意相反），屏幕底部出现一张队列浮窗，完整列出待贴条目与「已贴 x / y」进度。在目标窗口连续按原生 `⌘V` 即可逐条粘出，也可以直接点某一行右侧的「粘贴」按钮立刻贴出那一条。高亮行就代表「下一条待粘贴」：贴完自动前移到下一条还没贴的条目（跳着贴时会绕回头部继续找），点任意一行可把高亮挪过去但不会直接粘贴，按 `⏎` 贴出高亮行。已贴过的行打绿色对勾并加删除线，全部贴完显示「✓ 已完成」后自动消失，队列超过 5 条时列表内部滚动。浮窗可以按住任意空白处拖动，位置会被记住，下次打开回到原处。录制模式新增全局快捷键 `⌃⌥V`（按一次开始、再按一次结束），在任何应用里都能边复制边攒队列。浮窗不抢焦点，因此 `Esc` 也能在任何应用里结束队列，不必先点浮窗。录制模式下每次复制，都会有一张小卡片从鼠标位置沿弧线飞进它在队列里的那一行，落地即显形——「刚复制的这句话」和「列表里多出来的这一行」之间不再需要用户自己连线。队列激活期间，系统剪贴板始终装着高亮的那一条，复制新内容不会把还没贴的旧条目挤掉，所以依次复制 1、2、3 之后连按三次 `⌘V` 一定按 1、2、3 的顺序贴出。
  *Paste Stack (⌥⏎): select several items and press ⌥⏎ — they queue in the order you copied them (oldest first, deliberately opposite to the "newest first" list order), and a floating panel appears at the bottom of the screen listing every item with "x of y pasted" progress. Press native ⌘V repeatedly in the target app to paste them one by one, or click the "Paste" button on any row to paste that item right away. The highlighted row means "next up": after each paste it advances to the next item that has not been pasted yet (wrapping around when you paste out of order). Clicking a row moves the highlight without pasting; press ⏎ to paste the highlighted row. Pasted rows get a green check and strikethrough, and the panel shows "✓ Completed" before fading out; queues longer than five rows scroll inside the panel. The panel can be dragged from any empty spot and remembers where you left it. Recording mode now has a global shortcut, ⌃⌥V (press once to start, again to stop), so you can build a queue from any app as you copy. The panel never steals focus, so Esc ends the queue from any app too — no need to click it first. While recording, each copy sends a small card arcing from the pointer down into the exact row it lands in, which then fades in — "the line I just copied" and "the new row in the list" no longer need to be connected in your head. While the queue is active the system clipboard always holds the highlighted row, so copying new content never displaces items you have not pasted yet — copy 1, 2, 3 and three ⌘V presses paste exactly 1, 2, 3.*
- **屏幕置顶贴条（⌘P）**：选中任意条目按 `⌘P`（或点预览栏图钉按钮）即可钉成一张悬浮小窗，最多 12 张。悬停出现控制条，可调透明度（`⌥` + 滚轮，20%~100%）、折叠成一行标题、锁定鼠标穿透、内联编辑文本、复制或存回历史；图片贴条等比缩放并可一键复制图中文字。
  *Pin to Screen (⌘P): pin any item as a floating note — up to 12 at once. Hovering reveals a control strip for opacity (⌥ + scroll wheel, 20%–100%), collapsing to a single title line, click-through lock, inline editing, copying, or saving back to history; image notes scale proportionally and can copy their OCR text in one click.*

### 🎨 细节打磨 (Polish)

- **「下一条待粘贴」改用播放头样式，不再冒充选中**：原来高亮行铺一层强调底色加左侧竖条，那是 macOS 表达「用户选中」的语法，可这一行是 `⌘V` 自己往前跑的——用户并没有选它，套用选中样式等于每贴一条都替他改一次选择。现在只用行首一枚 `▶`（固定槽位，其余行留等宽空白保持标题整列对齐）+ 序号转强调色 + 标题升一级色并加半档字重来表达，整行不再铺色；行底色只留给「鼠标停在这行」。行内「粘贴」按钮也从常亮浅蓝块改为默认低对比文字、悬停才浮出底色，已贴过的行不再显示它——一屏五个蓝色块会把唯一该被看见的 `▶` 淹没。
  *"Next up" now speaks the player's language instead of fake selection: the highlighted row used to get an accent fill plus a leading bar, which is how macOS renders **user selection** — but this row advances on its own with ⌘V, so the user never selected it. It is now a single `▶` at the row's leading edge (fixed slot, other rows keep an equal-width blank so titles stay column-aligned) plus an accent-colored index and a one-step-bolder, primary-colored title; the row itself stays unfilled. Row backgrounds now only mean "pointer is here". The per-row Paste button went from a permanent blue chip to low-contrast text that reveals its chip on hover, and pasted rows no longer show it — five blue chips on one screen drown out the single ▶ that matters.*
- **多选工具栏重新排版**：列表列仅 310pt，四个「文字 + 键帽」按钮会互相挤压到只剩「合…」，现改为「合并粘贴」一个主按钮配三个图标按钮（顺序粘贴 / 标签 / 删除），完整名称走悬停提示。
  *Batch toolbar re-laid out: with only 310pt of column width, four text-plus-keycap buttons squeezed one another down to "Me…". It is now one primary "Merge & Paste" button plus three icon buttons (paste stack, tags, delete), with full names in tooltips.*
- **顺序粘贴胶囊的定位信息不再被挤压**：进度计数与正倒序徽标此前会被长摘要压成「1…」和「顺」，现在固定宽度，只让摘要正文尾部省略。
  *Paste Stack pill keeps its anchors: the progress counter and the FIFO/LIFO badge used to collapse into "1…" and a single glyph next to long summaries. They now hold their width, and only the summary truncates.*
- **设置页规则说明更准确**：三组的组级开关副标题由「启用脱敏」改为「全部启用」，占位符示例由 `<API_KEY_N>` 模板改为 `<API_KEY_1>` 实例。
  *Clearer settings copy: group-level switches now read "Enable all" instead of "Enable redaction", and placeholder examples show `<API_KEY_1>` rather than the `<API_KEY_N>` template.*

---

## [0.4.0] - 2026-10-24

### ✨ 功能特性 (Added)

- **Esc 快捷键支持分层逐级退出**：按 Esc 依次关闭编辑浮层、收起筛选面板、退出多选、清空搜索与筛选条件，最终收起面板，无需鼠标即可逐级复位。
*Layered dismiss on Esc: Esc now unwinds navigation one step at a time (overlays → filter panel → multi-select → search &amp; filter terms → hide panel).*
- **时间分组改为两档粒度**：7 天内按天归纳（今天 / 昨天 / 本周），7 天外按月/年归档，移除易混淆的「上周」；统一按自然日差判定，消除周界计算错位。
*Two-tier timeline grouping: items within 7 days group by day (Today / Yesterday / This Week) and older items archive by month/year, removing the ambiguous "Last Week" bucket.*

- **端到端加密启用时主动询问敏感同步**：首次开启端到端加密后，会一次性确认是否将密码与 API Key 等敏感内容加密同步至其他 Mac，默认保持严格的本地边界。
*Prompt for sensitive sync on E2EE setup: asks once whether to encrypt and sync sensitive credentials across your Macs, keeping the secure local-only default if declined.*

- **端到端加密明确为进阶选项**：客观阐明日常同步使用 iCloud 自带加密（传输与存储均已加密），端到端加密适合需要自主掌控密钥的高级场景，并提示口令遗失风险。
*E2EE positioned as an advanced option: clarifies that standard sync already benefits from iCloud encryption, presenting custom passphrase E2EE for users requiring zero-knowledge protection.*
- **历史清理改用「最大记录条数」**：清理策略从保留天数切换为最大记录条数（可选 100~~1000 条，默认 500 条），淘汰最久未使用记录并永久豁免收藏；磁盘限额收紧档位至 1GB~~10GB（默认 5GB），旧版配置平滑迁移。
*Item-count history cleanup: replaces retention days with item limits (100–1000, default 500) while exempting favorites; tightens disk limit presets with smooth legacy migration.*

### 🔒 安全与修复 (Fixes)

- **敏感条目状态胶囊与实际同步状态联动**：胶囊文案真实反映当前同步策略，未生效时显示「纯本机 · 不同步 iCloud」，开启端到端敏感同步后即时切换为「端到端加密 · 可同步」。
*Accurate sensitive sync badges: status badges in preview reflect actual sync state ("Local only" vs. "End-to-end encrypted · Synced") and update dynamically on setting changes.*
- **修复敏感同步保护状态误报**：仅勾选加密但未设置口令时不再提示已受保护，统一严格判定加密开启、口令非空且用户显式授权。
*Fixed false-positive encrypted sync status: rules now strictly verify active encryption, a non-empty passphrase, and explicit user consent.*
- **同步密钥改用本地受控文件，消除钥匙串弹窗**：同步口令迁移至严格受控的本地文件（0600 权限），彻底解决自签名构建导致系统反复弹出钥匙串授权框的问题，并支持旧凭据静默迁移。
*Eliminated Keychain authorization prompts: sync secrets now use local 0600 restricted files instead of the system Keychain, avoiding signature-invalidation permission dialogs.*

---

## [0.3.0] - 2026-10-21

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
- **层级更清楚**：预览标题加大到 22pt，深色模式两列明度差拉开。
*Clearer hierarchy: the preview title is now 22pt, and the columns separate more clearly in dark mode.*
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
- **偏好设置窗口关闭即释放视图树**，下次打开按需重建，回收 ~~15~~25MB。
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
- **示例数据播种与重置**：生产数据库首次创建时彻底重置残留标记，并在「设置 -&gt; 历史记录」中增加手动「导入示例数据」入口。
*Sample data seeding &amp; reset: Cleanly reset legacy flags when creating the production database, and added a manual "Import Sample Data" button in Settings.*
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
*Type-to-search &amp; Pinyin app launcher: Search history instantly by typing on panel open, with Pinyin abbreviation support to launch apps directly.*
- **本地全文搜索与智能过滤**：基于 SQLite FTS5，支持拼音/前缀检索、OCR 文字搜索与 `from:` / `app:` / `lang:` 等结构化过滤。
*Local FTS5 full-text search: Prefix/Pinyin matching, OCR text queries, and structured token filters (`from:`, `app:`, `lang:`).*
- **离线 OCR 与高亮预览**：基于 Apple Vision 框架离线识别截图文字，支持在图上直接高亮划词复制；代码与 JSON 语法高亮与格式化。
*Offline OCR &amp; preview: On-device text recognition via Apple Vision with in-image text highlighting; code/JSON syntax highlighting and beautifier.*
- **网址生成二维码**：识别到网址后支持在预览区一键生成二维码，方便手机扫码打开。
*URL to QR code: Generates scannable QR codes for links directly in the preview pane.*
- **端到端敏感凭证防护**：自动识别 API Key、密码、Token 并掩码遮蔽；AES-256-GCM 本地加密，密钥由钥匙串保管，绝不上云。
*Sensitive credential protection: Auto-detects and masks secrets/tokens; encrypted with AES-256-GCM via Keychain, excluded from cloud sync and FTS index.*
- **应用黑名单**：支持将 1Password、密码管理器等敏感应用加入黑名单，切到前台时自动暂停记录。
*Application blacklist: Exclude password managers and sensitive apps from recording.*
- **高效粘贴与批量操作**：`⏎` 原始粘贴、`⌥ ⏎` 纯文本粘贴、`⌘ ⏎` 连续粘贴；支持 `⇧ ↑/↓` 批量多选、合并粘贴与 10 秒撤销。
*Quick paste &amp; batch actions: `⏎` direct paste, `⌥ ⏎` plain text paste, `⌘ ⏎` continuous paste; multi-selection, merge paste, and 10s undo (`⌘ Z`).*
- **条目别名与收藏**：支持按 `⌘ R` 自定义条目别名，按 `⌘ S` 标记收藏（永久保留，豁免清理）。
*Aliases &amp; Favorites: Custom aliases (`⌘ R`) and pinned favorites (`⌘ S`) exempt from automated cleanup.*
- **端侧 iCloud 同步**：通过个人 iCloud 云盘跨 Mac 设备安全双向同步，敏感数据严格排除。
*Private iCloud sync: Bidirectional cross-Mac synchronization via personal iCloud Drive, with sensitive items strictly excluded.*
- **应用内自动更新与音效**：Sparkle 安全自动更新（EdDSA 签名校验）与可选的轻量粘贴音效。
*In-app updates &amp; audio: Automated updates via Sparkle with EdDSA signatures, plus optional haptic/audio feedback.*
- **灵活外观与多语言**：双栏/折叠布局切换、透明度调节，内置简体中文、繁体中文与英文。
*Flexible appearance &amp; localization: Dual-pane or compact modes, window opacity slider, localized in Simplified Chinese, Traditional Chinese, and English.*

### 🔒 安全与修复 (Fixes)

- **密钥安全加固**：生产数据库采用安全密钥文件与钥匙串双重保护，彻底阻断敏感明文同步及未加密回退漏洞。
*Key security hardening: Dual protection via Keychain and secure keyfile, blocking plaintext sync and unencrypted fallback loopholes.*
- **同步与索引一致性**：修复删除条目云端多设备复活、LWW 冲突更新错位及 FTS 索引同步失效问题。
*Sync &amp; index consistency: Resolved resurrecting deleted items, LWW conflict misalignments, and FTS sync drift.*
- **性能与稳定性**：iCloud 同步与磁盘限额维护完全移至后台，优化大图/大文本预览截断，避免主线程阻塞。
*Performance &amp; stability: Offloaded iCloud sync and quota maintenance to background threads; optimized large media previews.*
- **交互与快捷键修复**：面板快捷键分发统一收敛至 AppKit 层，消除搜索框持焦时的按键吞没与焦点抖动。
*Event routing: Unified panel keyboard dispatch at the AppKit layer, resolving key capture jitter during search field focus.*