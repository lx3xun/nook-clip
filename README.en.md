# <img src="./assets/logo-kit/exports/nookclip-appicon-128.png" width="32" height="32" valign="bottom" alt="NookClip"> NookClip

**A lightweight, fast, and privacy-first clipboard manager.**

[Product Page](https://lx3xun.github.io/nook-clip/) · [简体中文](README.md) · [繁體中文](README.zh-TW.md) · [English](README.en.md)

[![Website](https://img.shields.io/badge/Website-NookClip-1677FF?logo=safari&logoColor=white)](https://lx3xun.github.io/nook-clip/)
[![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-007AFF?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Rust 1.75+](https://img.shields.io/badge/Rust-Core_Engine-000000?logo=rust&logoColor=white)](https://www.rust-lang.org)
[![License GPLv3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## 💡 What Problems Does It Solve?

Default clipboard behavior often brings familiar friction:

- **Overwritten accidentally**: Copying a new sentence or link replaces your previous snippet immediately, forcing you to switch back and find it again.
- **Cluttered history that is hard to search**: Many tools only allow paging through items chronologically, or have sluggish search that misses shortcuts and image text.
- **Privacy risks**: Clipboards regularly contain passwords, API keys, and connection strings. Many utilities send telemetry, require accounts, or upload history to third-party clouds.
- **Heavy resource usage**: Background tools often consume hundreds of megabytes of RAM and stutter when summoned.

**NookClip is built to solve these issues cleanly:**

It uses a native interface backed by a high-performance Rust core, keeping memory usage around 20 MB with instant response. Most importantly: **no accounts, no telemetry, no crash tracking — all data stays completely on your local device**.

| Light Mode | Dark Mode |
| :---: | :---: |
| ![NookClip Light Mode](site/assets/nookclip-light.png) | ![NookClip Dark Mode](site/assets/nookclip-dark.png) |

---

## Features

### Clipboard History & Fast Search
- **Global Hotkey**: Press `⌘ ⇧ V` to summon the panel anywhere; it closes automatically on focus loss or `Esc`.
- **Type-to-Search**: Start typing immediately when the panel opens—no need to click into the search field first.
- **Quick App Launch**: Type app names or initials (e.g. `wx`, `terminal`) directly in the search bar and press Enter to launch.
- **Full-Text & OCR Search**: Built on SQLite FTS5 to search through text, URLs, and recognized text in screenshots (OCR), with matches highlighted.
- **Category Filtering**: Quickly filter by text, images, files, links, code, colors, or credentials.

### Content Recognition & Preview
- **Offline Image OCR**: Recognizes text in copied images and screenshots using built-in system vision, allowing you to search image content or copy recognized text with one click.
- **Syntax Highlighting & JSON Formatting**: Automatic code highlighting; JSON content can be formatted, minified, or copied with a single click.
- **QR Code for Links**: Generates QR codes directly from recognized URLs for quick mobile scanning.
- **Color Previews**: Recognizes hex color codes (e.g. `#FF5722`), showing color dots inline and providing one-click copy for HEX and RGB values.
- **Missing File Protection**: Warns before pasting if a copied file has been moved or deleted.

### Credential & Privacy Protection
- **Credential Detection**: Automatically identifies API keys, access tokens, private keys, and connection strings with passwords.
- **Encrypted Local Storage**: Sensitive entries are encrypted with AES-256-GCM before saving to disk; keys are stored locally and in the system keychain.
- **Privacy Masking**: Displays as `••••••••` in the list with automatic re-masking after 30 seconds.
- **Isolated from Search & Sync**: Sensitive entries are never written to search indexes or uploaded during sync.
- **App Blacklist**: Automatically pauses recording when password managers or other excluded apps are active in the foreground.

### More Capabilities
- **iCloud Drive Sync**: Optional sync across your own devices using your personal iCloud Drive (no third-party servers).
- **Backup & Export**: Export to JSON or Markdown, with options to exclude or mask sensitive items.
- **Batch Actions & Undo**: Select multiple items with Shift or ⌘ to merge-paste or delete; undo deletions within 10 seconds with `⌘ Z`.

---
## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| **`⌘ ⇧ V`** | Show / hide quick panel (re-recordable in **Settings → Paste**) |
| **`↑` / `↓`** | Move selection up or down (hold to repeat; auto-paginates at the bottom) |
| **`⇧ ↑` / `⇧ ↓` / `⌘ Click`** | Extend multi-selection (`⏎` to merge & paste, `⌘ ⌫` to bulk delete) |
| **`⏎`** | Paste selection into the frontmost app / Launch selected application |
| **`⌥ ⏎`** | Paste as plain text (strips fonts, colors, and rich formatting) |
| **`⌘ ⏎`** | Paste and keep panel open (great for filling multi-field forms) |
| **`⌘ C`** | Re-copy selection to system clipboard (or copy selected text in preview) |
| **`⌘ [` / `⌘ ]`** | Cycle categories (`⌘ ]` next, `⌘ [` previous) |
| **`⌘ ↓`** | Open / close the overflow category dropdown menu |
| **`⌘ F`** | Focus search field (or simply start typing while in list mode) |
| **`⌘ T`** | Cycle through time groups (Today → Yesterday → This Week → … → Top) |
| **`⌘ S`** | Favorite / unfavorite item (favorites are exempt from retention & quota cleanup) |
| **`⌘ R`** | Set or clear a custom alias for the selected item |
| **`⌘ ⌫`** | Delete selected item(s) (undoable within 10 seconds) |
| **`⌘ Z`** | Undo last delete |
| **`Esc`** | Layered dismiss: close dropdown → exit multi-select → clear search → reset filters → hide panel |

---

## 📦 Download & Install

### Option 1: Prebuilt DMG Installer

Download the Universal DMG package directly (runs natively on both Apple Silicon `arm64` and Intel `x86_64`):

- **GitHub Direct Download**: [Download NookClip.dmg (Latest)](https://github.com/lx3xun/nook-clip/releases/latest/download/NookClip.dmg)
- **Gitee Releases (Fast in China)**: [Visit Gitee Releases](https://gitee.com/lx3xun/nook-clip/releases)
- **All Releases**: [GitHub Releases](https://github.com/lx3xun/nook-clip/releases)

After downloading, open the `.dmg` image and drag **NookClip** into your **Applications** folder.

> **⚠️ First-Launch & Permission Notes (Ad-hoc Signed Open-Source Build)**
>
> Because this open-source project does not use a paid Apple Developer account for notarization, release binaries are ad-hoc signed and may trigger a macOS Gatekeeper prompt on first launch:
>
> 1. **“Cannot be opened because the developer cannot be verified”**: In Finder, **Control-click (or right-click)** `/Applications/NookClip.app`, choose **Open**, and click **Open** again in the dialog.
> 2. **“NookClip is damaged and can’t be opened”**: Run the following command in Terminal to strip the download quarantine attribute:
>    ```bash
>    xattr -cr /Applications/NookClip.app
>    ```
> 3. **Accessibility Permission (Required for Auto-Paste)**: Enable **NookClip** under **System Settings → Privacy & Security → Accessibility**. If direct paste stops working after an app update, select NookClip in the Accessibility list, click `[-]` to remove it, and re-add `[+]` it.

### Option 2: Build from Source (Recommended for Developers — No Gatekeeper Prompt)

```bash
git clone https://github.com/lx3xun/nook-clip.git
cd nook-clip
zsh scripts/build.sh app --universal   # produces dist/NookClip.app (arm64 + x86_64)
cp -R dist/NookClip.app /Applications/
```

**Requirements**:
- macOS 14.0 (Sonoma) or later
- Xcode 15+ or Swift 5.10+ Command Line Tools
- Rust 1.75+ toolchain (install both `aarch64-apple-darwin` and `x86_64-apple-darwin` targets when building `--universal`)

---

## Privacy & Data Security

NookClip follows a strict "local-first, zero tracking" policy:

1. **No Data Collection**: No accounts, no behavior tracking, no crash telemetry.
2. **Explicit Network Use**: Network requests only happen when checking for app updates (can be turned off in Settings) or when you explicitly enable iCloud Drive sync.
3. **Local Encryption for Secrets**: Identified passwords and API keys are encrypted at rest with AES-256-GCM, with keys managed locally and in the system keychain.
4. **Sensitive Data Isolation**: Sensitive entries are never written into search indexes and are never uploaded to iCloud.
5. **Transparent Local File Storage**:
   ```text
   ~/Library/Application Support/com.lx3xun.nookclip/
   ├── library.db       # SQLite database (history records and search indexes)
   ├── Content/         # Cached images and files
   └── .master_key      # Local master encryption key
   ```

---

## 🛠 Development

### Project Layout

```text
nook-clip/
├── crates/                        # Rust core workspace (cross-platform storage, FTS5 search, sync & crypto)
│   ├── nook-core/                 # Core engine (SQLite WAL + FTS5, AES-256-GCM, Zstd sync packs, redacted export)
│   └── nook-ffi/                  # UniFFI 0.28 bindings (generates Swift / C bridge & static library)
├── platform/macOS/                # Native macOS client (Swift Package)
│   ├── Package.swift              # SwiftPM manifest (Sparkle 2)
│   ├── Sources/NookClip/
│   │   ├── App/                   # App lifecycle, floating panel (DraggablePanel), global hotkeys & key routing
│   │   ├── Clipboard/             # Pasteboard monitor, paste service, sensitive detector, app exclusions & classifier
│   │   ├── CoreBridge/            # UniFFI-generated Swift bridge
│   │   ├── Crypto/                # 0600 master key file & Keychain service
│   │   ├── Localization/          # Instant runtime localization (en / zh-Hans / zh-Hant)
│   │   ├── Resources/             # Localized strings (Localizable.strings) & app icons
│   │   ├── Search/                # Installed app search (with Pinyin index), Vision offline OCR & query parser
│   │   ├── Storage/               # Rust store wrapper, iCloud Drive sync coordinator & retention lifecycle
│   │   └── UI/                    # SwiftUI main panel, rich preview cards (Code/JSON/OCR/QR/Color) & Settings
│   ├── Tests/NookClipTests/       # Unit & integration test suite (isolated named pasteboards)
│   └── Packaging/                 # Info.plist and entitlements
├── scripts/                       # Unified build, packaging & release scripts (build.sh / build-app.sh / build-dmg.sh)
├── README.md                      # Simplified Chinese documentation
├── README.zh-TW.md                # Traditional Chinese documentation
└── README.en.md                   # English documentation
```

### Build Commands

```bash
# 1. Fast debug build for local development (skips Rust in 0s if unchanged)
zsh scripts/build.sh dev

# 2. Build incrementally and launch local NookClip.app
zsh scripts/build.sh run

# 3. Compile Rust core and regenerate UniFFI Swift bindings
zsh scripts/build.sh rust

# 4. Package production Universal .app and .dmg (with SHA256 checksum)
zsh scripts/build.sh app --universal
zsh scripts/build.sh dmg --universal

# 5. Clean build artifacts and caches
zsh scripts/build.sh clean
```

### Testing

All tests run against isolated temporary databases and private named pasteboards—**never touching your production database or system clipboard**:

```bash
# Run Rust core unit & integration tests
cargo test --workspace

# Run macOS Swift unit & integration tests
swift test --package-path platform/macOS

# Run large-scale performance benchmarks (5k / 10k / 50k items, skipped by default)
NOOK_PERF=1 swift test --package-path platform/macOS --filter PerformanceBenchmarkTests
```

### Contributing

Issues and Pull Requests are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for commit conventions, 3-language localization rules, and test isolation guidelines. To report a security vulnerability, please follow [SECURITY.md](SECURITY.md) rather than opening a public issue.

---

## 📄 License & Trademark Notice

- **Open-Source License**: The source code in this repository is licensed under the [GNU General Public License v3.0 (GPLv3)](LICENSE). Any modified or derivative distributions must also disclose their full source code under GPLv3.
- **Commercial Distribution & App Store Exclusivity**: The original copyright holder (`lx3xun`) retains the exclusive right to distribute notarized binaries and proprietary commercial editions on the Apple App Store and official commercial channels. No third party may submit this software or its derivatives to the Apple App Store or other commercial app stores without prior written permission.
- **Trademark & Branding Protection**: Pursuant to Section 7(e) of the GPLv3, the **“Nook”** and **“NookClip”** names, app icons (`AppIcon.icns` / `NookClipIcon.svg`), and associated brand assets are the exclusive property of `lx3xun` and are not granted under this open-source license. Derivative works must remove all Nook / NookClip branding and logos before distribution.

[GPLv3](LICENSE) © 2026 lx3xun
