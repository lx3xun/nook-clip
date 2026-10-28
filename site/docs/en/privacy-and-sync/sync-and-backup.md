# iCloud Sync & Backup Export

NookClip operates with **zero third-party servers**. Your data stays under your control, with optional sync across your Macs via your personal Apple iCloud Drive and open backup formats.

---

## 1. Personal iCloud Drive Sync

If you use multiple Macs (for example, an office MacBook and a home Mac Studio):

- **No Third-Party Cloud**: Sync runs entirely through Apple's native **iCloud Drive** container tied to your Apple ID.
- **Sensitive Isolation & Optional E2EE**: Sensitive entries (passwords, API keys, private keys) stay local by default. Advanced users can enable custom-passphrase **End-to-End Encryption (E2EE)** and optionally include encrypted sensitive entries.
- **Opt-In**: Disabled by default; enable anytime under **Settings → Sync**.

---

## 2. Export & Backup (JSON / Markdown)

You can export your clipboard history at any time under **Settings → Storage / Data**:

1. **JSON Format (Full Lossless Backup)**: Preserves content, timestamps, source app, starred status, tags, and aliases for restoring on a new Mac.
2. **Markdown Format (Readable Archive)**: Clean document format ideal for archiving into Obsidian or Notion.

### Privacy Options on Export
When exporting, you can choose to **skip sensitive entries entirely** or **mask sensitive values** so exported files never leak raw credentials.

---

## 3. Auto-Cleanup & Storage Quotas

Configure retention rules under **Settings → Storage**:

- **Maximum Item Count** (e.g. 500 / 2,000 / 10,000 items);
- **Maximum Age** (e.g. 7 / 30 / 90 days);
- **Image Cache Disk Quota**;
- **Starred Exemption**: Starred entries (`⌘ S`) are permanently protected and never removed by auto-cleanup.
