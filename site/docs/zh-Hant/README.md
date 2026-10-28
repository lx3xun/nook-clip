# NookClip 使用手冊

歡迎使用 NookClip！NookClip 是一款專為 macOS 設計的輕量、高速且高度注重隱私的剪貼簿與歷史記錄管理工具。

這裡彙整了從基礎入門到高階技巧的完整使用說明，幫助你把日常複製、貼上與資訊管理的效率發揮到極致。

---

## 快速導覽

### 1. 快速上手
- **[下載、安裝與權限設定](./getting-started/installation.md)**：包含安裝包下載、首次開啟的 Gatekeeper 權限處理、系統輔助使用設定。
- **[基礎使用](./getting-started/basic-usage.md)**：快捷鍵叫出面板、鍵盤即時搜尋、一鍵貼上與分層退出。

### 2. 核心進階技巧
- **[順序貼上佇列（⌥ ⏎）](./advanced/paste-stack.md)**：連續複製多筆內容，像出牌一樣按順序逐筆貼上，告別來回切換視窗。
- **[語義脫敏貼上與還原（⌃ ⏎）](./advanced/scrub-paste.md)**：安全分享含密碼/Key 的程式碼，一鍵將敏感資訊替換為安全佔位符，且能原位一鍵還原。
- **[螢幕置頂貼條（⌘ P）](./advanced/pinned-note.md)**：將程式碼、文字或圖片釘在螢幕最上層對照參考，支援半透明與滑鼠點擊穿透。
- **[終端機安全貼上護欄](./advanced/terminal-safe-paste.md)**：辨識到目標視窗是終端機時，自動攔截多行指令與 `sudo`、`rm -rf` 等高風險內容，終結「複製即執行」事故。
- **[兩筆記錄行內對比（⌘ D）](./advanced/inline-diff.md)**：在歷史列表中選兩筆記錄按 `⌘ D`（或點底欄 / 預覽頂欄 / 右鍵選單的「對比」），預覽區即刻顯示行級與字詞級紅綠差異，支援 `↑↓` 即時換筆與逐塊挑選合併。
- **[手機互傳](./advanced/phone-drop.md)**：選取任意記錄點「手機互傳」，手機掃碼免安裝就能檢視並複製電腦上的長文字、下載原圖或檔案，也能把手機文字和相簿圖片傳回電腦剪貼簿；僅在同一區域網路內傳輸、5 分鐘自動失效、關閉即釋放連接埠。

### 3. 搜尋與整理
- **[全文搜尋與拼音啟動應用](./search-and-manage/search-and-launch.md)**：毫秒級歷史記錄搜尋，以及直接輸入拼音首字母快速啟動 Mac 應用程式。
- **[離線圖片文字辨識（OCR）](./search-and-manage/ocr-image.md)**：提取截圖與圖片中的文字，並支援透過圖片內的文字反向搜出該圖片。
- **[類型篩選與標籤管理](./search-and-manage/types-and-tags.md)**：使用 8 大固定類型槽位、自訂標籤與自訂別名整理常用內容。
- **[批次操作與復原刪除](./search-and-manage/batch-and-undo.md)**：滑鼠拖曳框選、批次合併貼上、刪除後 10 秒內按 `⌘ Z` 原位復原。

### 4. 隱私安全與同步
- **[敏感憑證防護與本機加密](./privacy-and-sync/sensitive-guard.md)**：API Key 與密碼自動辨識、AES-256 本機加密與預設遮碼預覽。
- **[應用黑名單排除](./privacy-and-sync/app-blacklist.md)**：設定不記錄特定軟體（如密碼管理器）複製的內容。
- **[iCloud 同步與備份匯出](./privacy-and-sync/sync-and-backup.md)**：透過個人 iCloud Drive 跨裝置同步，以及匯出 JSON / Markdown 備份。
- **[貼完即焚與剪貼簿自動擦除](./privacy-and-sync/auto-burn.md)**：驗證碼簡訊自動提純為純數字碼，驗證碼與密碼貼上後自動清空系統剪貼簿。

### 5. 參考與常見問題
- **[完整快捷鍵速查表](./reference/shortcuts.md)**：全局快捷鍵與面板內全鍵盤操作一覽。
- **[常見問題排查（FAQ）](./reference/faq.md)**：無法自動貼上、快捷鍵衝突、權限重設等常見問題解答。
