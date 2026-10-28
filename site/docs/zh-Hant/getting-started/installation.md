# 下載、安裝與首次設定

本指南將帶你完成 NookClip 的安裝與首次權限設定，整個過程只需約 1 分鐘。

---

## 1. 系統需求與下載

- **系統版本**：macOS 14.0 (Sonoma) 或更高版本
- **硬體架構**：原生支援 Apple Silicon (M1 / M2 / M3 / M4) 與 Intel 處理器（Universal 通用安裝包）

### 方式一：透過 Homebrew 安裝（推薦）

打開「終端機（Terminal）」，執行以下兩行指令即可完成安裝：

```bash
brew tap lx3xun/nookclip https://github.com/lx3xun/nook-clip
brew install --cask nookclip
```

> 💡 **日後更新**：執行 `brew upgrade --cask nookclip` 即可一鍵升級到最新版本。

### 方式二：手動下載 DMG 安裝包

1. 前往 [GitHub Releases](https://github.com/lx3xun/nook-clip/releases/latest) 下載最新版本的 `NookClip-<版本號>.dmg`。
2. 雙擊打開 DMG 檔案，將 **NookClip.app** 拖入右側的 **Applications（應用程式）** 檔案夾中。

---

## 2. 首次開啟（處理 macOS 未簽名提示）

由於 NookClip 是免費開源軟體，未向 Apple 支付每年 $99 美元的企業開發者證書年費，首次直接雙擊打開時，macOS 可能會彈出「無法驗證開發者」或「軟體已損毀」的安全攔截提示。

請任選以下一種方式放行（**僅首次需要**）：

- **方法 A（右鍵開啟）**：在「應用程式」檔案夾中，按住鍵盤 `Control` 鍵並點擊 `NookClip.app`，選擇選單中的 **「打開」**，在彈出視窗中再次點擊「打開」。
- **方法 B（終端機一鍵放行）**：打開終端機，貼上並執行以下指令：
  ```bash
  xattr -cr /Applications/NookClip.app
  ```

---

## 3. 授予「輔助使用」權限（實現自動貼上）

NookClip 的核心體驗是「選中歷史記錄按 Return 後，自動幫你貼入當前視窗」。在 macOS 中，代替使用者向目標視窗發送貼上指令需要系統的 **輔助使用（Accessibility）** 權限。

1. 首次啟動 NookClip 時，軟體會彈出權限引導提示，點擊 **「前往系統設定」**。
2. 系統會自動打開 **「系統設定 → 隱私權與安全性 → 輔助使用」**。
3. 在列表中找到 **NookClip**，打開右側的開關（需輸入 Mac 解鎖密碼或 Touch ID 確認）。

> ⚠️ **如果沒開啟此權限會怎樣？**
> 即使不開啟，NookClip 依然可以正常記錄剪貼簿歷史；只是在面板中按 Return 後，它只能將內容寫回系統剪貼簿，需要你回到目標視窗後再手動按一次 `⌘ V`。因此強烈建議開啟。

---

## 4. 完成首次設定

權限開啟後，你會在螢幕右上角的**選單列（Menu Bar）**看到 NookClip 的圖示：

- 按全局預設快捷鍵 **`⌘ ⇧ V`**（Command + Shift + V）即可叫出主面板。
- 如果預設快捷鍵與你的其他常用軟體衝突，可以點擊選單列圖示選擇「設定」，在「貼上」分頁中錄製你習慣的按鍵。

👉 **下一篇**：[基礎使用 →](./basic-usage.md)
