# Troubleshooting (FAQ)

Common questions and quick fixes when installing or using NookClip.

---

### Q1: Pressing `Return` (`⏎`) copies the item to the clipboard, but doesn't automatically paste it into my active window. Why?

**Cause**: macOS **Accessibility** permission has not been granted yet, or the permission cache became stale after updating NookClip.

**Fix**:
1. Open **System Settings → Privacy & Security → Accessibility**.
2. Make sure **NookClip** is listed and toggled **On**.
3. **If you just updated NookClip**: macOS sometimes invalidates the old binary signature even while showing the toggle as On. Select `NookClip`, click **`[-]`** at the bottom to remove it completely, then click **`[+]`** to re-add `/Applications/NookClip.app` and toggle it On.

---

### Q2: macOS says "NookClip cannot be opened because the developer cannot be verified" or "is damaged" on first launch.

**Cause**: Standard macOS Gatekeeper quarantine on open-source apps built without a paid Apple Developer ID certificate.

**Fix**:
Run the following command in **Terminal** to clear the quarantine attribute:
```bash
xattr -cr /Applications/NookClip.app
```

---

### Q3: Pressing `⌘ ⇧ V` doesn't open the panel.

**Cause**: Another app (such as another clipboard tool, IDE, or screenshot utility) may have registered `⌘ ⇧ V`.

**Fix**:
1. Click the NookClip icon in the top-right menu bar → **Settings**.
2. In the **Paste** tab, record a new global shortcut (such as `⌥ Space` or `⌃ ⌥ V`).

---

### Q4: Why aren't passwords copied from 1Password or macOS Passwords showing up in NookClip?

**Cause**: By design, NookClip honors macOS concealed/transient clipboard markers and automatically ignores copies from password managers (1Password, Bitwarden, KeePassXC, macOS Passwords) to protect your master credentials. See [App Exclusion Rules](../privacy-and-sync/app-blacklist.md).

---

### Q5: Where is the `<API_KEY_1>` mapping table from Scrubbed Paste (`⌃ ⏎`) stored? Is it safe?

**Answer**: **100% in volatile RAM only.**
Mappings are never written to disk, SQLite, or iCloud. They are automatically wiped after 30 minutes of inactivity or when NookClip quits, and you can clear them manually anytime in **Settings → Privacy**.

---

### Q6: I enabled Click-Through Lock on a Pinned Note (`⌘ P`) and now I can't click or close it!

**Fix**:
Press the global shortcut **`⌘ ⌥ P`** (Command + Option + P) to exit Click-Through Lock Mode and restore normal mouse interaction.

---

### Q7: Where is my clipboard history stored on disk?

- **Local Path**: `~/Library/Application Support/com.lx3xun.nookclip/`
- Updating or replacing `NookClip.app` in `/Applications` preserves your local database.
- You can also export backups anytime under **Settings → Storage / Data**. See [iCloud Sync & Backup Export](../privacy-and-sync/sync-and-backup.md).
