# NookClip 使用文档

欢迎使用 NookClip！NookClip 是一款专为 macOS 设计的轻量、高速且高度注重隐私的剪贴板与历史记录管理工具。

这里汇总了从基础入门到高阶技巧的完整使用说明，帮助你把日常复制、粘贴和信息管理的效率发挥到极致。

---

## 快速导航

### 1. 快速上手
- [下载、安装与权限配置](./getting-started/installation.md)：包含安装包下载、首次打开的 Gatekeeper 权限处理、系统辅助功能设置。
- [基础使用](./getting-started/basic-usage.md)：快捷键呼出面板、键盘实时搜索、一键粘贴与分层退出。

### 2. 核心进阶技巧
- [顺序粘贴栈 (⌥ ⏎)](./advanced/paste-stack.md)：连续复制多条内容，像打牌一样按顺序逐条贴出，告别来回切换窗口。
- [语义脱敏粘贴与还原 (⌃ ⏎)](./advanced/scrub-paste.md)：安全分享带密码/Key的代码，一键将敏感信息替换为安全占位符，且能原位一键还原。
- [屏幕置顶贴条 (⌘ P)](./advanced/pinned-note.md)：将代码、文本或图片钉在屏幕最上层对照参考，支持半透明与鼠标点击穿透。
- [终端安全粘贴护栏](./advanced/terminal-safe-paste.md)：识别到目标窗口是终端时，自动拦截多行命令与 `sudo`、`rm -rf` 等高危内容，终结「粘进终端直接回车闯祸」。
- [两条记录行内对比 (⌘ D)](./advanced/inline-diff.md)：选中任意两条记录一键对比，右侧红绿高亮到字词级，逐块挑选保留哪一版并复制合并结果，替代专门的对比软件。

### 3. 搜索与整理
- [全文搜索与拼音启动应用](./search-and-manage/search-and-launch.md)：毫秒级全文检索，支持输入拼音字母直接启动应用程序。
- [离线图片文字识别 (OCR)](./search-and-manage/ocr-image.md)：本地离线提取截图中的文本，图片文字直接参与全文搜索。
- [类型筛选与标签管理](./search-and-manage/types-and-tags.md)：8 种固定内容分类快速切换、打标签与组合筛选。
- [批量操作与撤销删除](./search-and-manage/batch-and-undo.md)：像在桌面上一样鼠标拖选多项，批量合并粘贴，误删支持 ⌘ Z 撤销。

### 4. 隐私安全与同步
- [敏感凭证防护与本地加密](./privacy-and-sync/sensitive-guard.md)：自动识别 API 密钥与密码，AES-256 加密存储，不上云不进索引。
- [应用黑名单排除](./privacy-and-sync/app-blacklist.md)：密码管理器（如 1Password、Bitwarden）复制的内容自动忽略，防止泄漏。
- [iCloud 同步与备份导出](./privacy-and-sync/sync-and-backup.md)：仅通过你的个人 iCloud 同步，支持导出 JSON/Markdown 备份。
- [粘完即焚与剪贴板自动擦除](./privacy-and-sync/auto-burn.md)：验证码复制后自动提纯成纯数字，粘贴一次或倒计时结束就擦掉剪贴板，验证码粘完 5 秒还能从历史彻底销毁。

### 5. 参考与常见问题
- [完整快捷键速查表](./reference/shortcuts.md)：所有键盘操作一览。
- [常见问题排查 (FAQ)](./reference/faq.md)：解决辅助功能失效、粘贴无反应、快捷键被占用等日常疑惑。
