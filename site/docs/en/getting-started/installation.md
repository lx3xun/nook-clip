# Installation & Initial Setup

This guide walks you through installing NookClip and granting the required macOS permission in under a minute.

---

## 1. System Requirements & Download

- **macOS Version**: macOS 14.0 (Sonoma) or later
- **Architecture**: Universal binary supporting both Apple Silicon (M1 / M2 / M3 / M4) and Intel Macs

### Option 1: Install via Homebrew (Recommended)

Open **Terminal** and run:

```bash
brew tap lx3xun/nookclip https://github.com/lx3xun/nook-clip
brew install --cask nookclip
```

> 💡 **Updating later**: Run `brew upgrade --cask nookclip` to update to the latest release.

### Option 2: Manual DMG Download

1. Download the latest `NookClip-<version>.dmg` from [GitHub Releases](https://github.com/lx3xun/nook-clip/releases/latest).
2. Double-click the DMG file and drag **NookClip.app** into your **Applications** folder.

---

## 2. First Launch (macOS Gatekeeper Prompt)

Because NookClip is free, open-source software distributed without a paid Apple Developer ID certificate, macOS Gatekeeper may show an "unidentified developer" or "damaged app" warning on the very first launch.

Use either method below (**only needed once**):

- **Method A (Control-click → Open)**: In Finder, open `/Applications`, hold `Control` and click `NookClip.app`, choose **Open**, then click **Open** again in the dialog.
- **Method B (Terminal command)**: Run the following command in Terminal:
  ```bash
  xattr -cr /Applications/NookClip.app
  ```

---

## 3. Grant Accessibility Permission (For Auto-Paste)

When you select an item in NookClip and press `Return`, NookClip automatically pastes it into your active window. On macOS, simulating the paste keystroke requires **Accessibility** permission.

1. On first launch, click **Open System Settings** in NookClip's permission prompt.
2. macOS will open **System Settings → Privacy & Security → Accessibility**.
3. Find **NookClip** in the list and toggle it **On** (confirm with Touch ID or your Mac password).

> ⚠️ **What if I skip this permission?**
> NookClip will still capture your clipboard history normally, but pressing `Return` will only copy the selected item back to the system clipboard — you would need to press `⌘ V` manually in your target app. Enabling Accessibility is strongly recommended.

---

## 4. Ready to Go

Once enabled, you will see the NookClip icon in your top-right **Menu Bar**:

- Press the default global shortcut **`⌘ ⇧ V`** (Command + Shift + V) from any app to summon the panel.
- To customize the global shortcut, click the menu bar icon → **Settings** → **Paste** tab.

👉 **Next**: [Basic Usage →](./basic-usage.md)
