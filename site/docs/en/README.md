# NookClip Documentation

Welcome to **NookClip** — a lightweight, instant, privacy-first clipboard and history manager built natively for macOS.

This guide covers everything from initial setup to advanced keyboard workflows so you can get the most out of every copy and paste.

---

## Quick Navigation

### 1. Getting Started
- **[Installation & Permissions](./getting-started/installation.md)**: Download options, first-launch Gatekeeper handling, and Accessibility permission setup.
- **[Basic Usage](./getting-started/basic-usage.md)**: Summon the panel, type-to-search, four paste modes, and layered `Esc` navigation.

### 2. Advanced Workflows
- **[Paste Stack (⌥ ⏎)](./advanced/paste-stack.md)**: Copy multiple items once and deal them out sequentially with `⌘ V` — no more switching windows back and forth.
- **[Scrubbed Paste & Unscrub (⌃ ⏎)](./advanced/scrub-paste.md)**: Safely share code or logs with AI by replacing secrets with semantic placeholders like `<API_KEY_1>`, and restore real values in one keystroke (`⌃ ⇧ ⏎`).
- **[Pin to Screen (⌘ P)](./advanced/pinned-note.md)**: Float code, text, images, or color swatches on top of all windows with adjustable opacity and click-through mode.
- **[Terminal Safe-Paste](./advanced/terminal-safe-paste.md)**: Intercept multi-line commands and dangerous patterns (`sudo`, `rm -rf`, `curl | sh`) before they auto-execute in your terminal.
- **[Inline Diff (⌘ D)](./advanced/inline-diff.md)**: Compare any two history entries with line- and word-level red/green highlights, live-swap rows with `↑↓`, and cherry-pick hunks to merge.
- **[Phone Drop](./advanced/phone-drop.md)**: Select any item and tap Send to Phone; scan the QR code to view and copy long text or download original images/files from your Mac, and push text or photos from your phone back to the Mac clipboard—no app install. LAN-only, auto-expires in 5 minutes, and releases the port on close.

### 3. Search & Organize
- **[Full-Text Search & App Launcher](./search-and-manage/search-and-launch.md)**: Sub-millisecond SQLite FTS5 search and instant app launching by name or initials.
- **[Offline Image OCR](./search-and-manage/ocr-image.md)**: Extract text from screenshots on demand with Apple Vision and find images by the words inside them.
- **[Type Slots & Tags](./search-and-manage/types-and-tags.md)**: Organize clips with 8 fixed category slots, custom tags, and custom aliases.
- **[Batch Actions & Undo Delete](./search-and-manage/batch-and-undo.md)**: Drag-select multiple items, merge-paste, and undo accidental deletions within 10 seconds (`⌘ Z`).

### 4. Privacy & Sync
- **[Sensitive Guard & Local Encryption](./privacy-and-sync/sensitive-guard.md)**: Automatic API key & password detection, AES-256-GCM at-rest encryption, and masked previews.
- **[App Exclusion Rules](./privacy-and-sync/app-blacklist.md)**: Automatically ignore password managers and exclude specific apps from being recorded.
- **[iCloud Sync & Backup Export](./privacy-and-sync/sync-and-backup.md)**: Sync across your Macs via personal iCloud Drive (with optional E2EE) and export to JSON or Markdown.
- **[Auto-Burn & Clipboard Erase](./privacy-and-sync/auto-burn.md)**: Auto-extract pure verification codes from SMS messages and auto-clear OTPs and secrets from the system clipboard after paste or timeout.

### 5. Reference & FAQ
- **[Keyboard Shortcuts Reference](./reference/shortcuts.md)**: Complete table of global and in-panel keyboard shortcuts.
- **[Troubleshooting (FAQ)](./reference/faq.md)**: Solutions for auto-paste permissions, Gatekeeper prompts, shortcut conflicts, and data storage.
