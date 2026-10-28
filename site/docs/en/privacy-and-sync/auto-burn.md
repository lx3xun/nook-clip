# Auto-Burn & Clipboard Erase

Verification SMS messages usually arrive wrapped in boilerplate like `"[Acme Bank] Your verification code is 482910. Valid for 5 minutes."` — forcing you to delete the surrounding text after pasting. Meanwhile, passwords and API keys stay in the system clipboard in plaintext long after you paste them, ready to be accidentally pasted into a chat window with `⌘ V`.

**NookClip solves both automatically: it extracts pure verification codes into your clipboard on copy, and auto-clears OTPs and sensitive credentials from the system clipboard right after you paste them (or after a countdown if left unused).**

---

## 1. How It Works

| Feature | Trigger Condition | What NookClip Does | Your Control |
| :--- | :--- | :--- | :--- |
| **OTP Auto-Extract** | Single-line copied text containing both an OTP keyword (`verification code`, `OTP`, `passcode`, `验证码`, etc.) and a `4–8` char code | Replaces the system clipboard with the pure code (e.g. `482910`), shows an `OTP 482910` badge, and displays a quick banner | Press `⌘ V` to paste the pure code directly; click **Restore Full Text** on the banner if you need the original message |
| **Auto-Burn After Paste** | An OTP entry or sensitive credential entry is pasted once | Waits `0.3s` for the target app to finish reading the clipboard, then wipes the system clipboard (and optionally deletes the history entry) | Fully automatic |
| **Timeout Auto-Erase** | An OTP or sensitive credential is copied but not pasted | Shows a live countdown banner in the preview pane (e.g. `Erasing from system clipboard in 28s`) and clears the clipboard at 0s | Click **Keep This Entry** in the banner to exempt it, or **Burn Now** to wipe immediately |

---

## 2. Key Design Details

- **Zero Extra Editing**: Pasting an OTP gives you just the code on the first `⌘ V`.
- **0.3s Post-Paste Grace Window**: Gives the target app enough time to read the pasteboard while shrinking plaintext exposure to under a second.
- **History Destruction Off by Default**: Permanently deleting from history bypasses Trash and is opt-in under Settings.
- **Zero Idle Listeners**: When both policies are set to *Never*, NookClip attaches no background key listeners.

---

## 3. Strict Safety Boundaries (No False Triggers)

1. **Plain Numbers Without Keywords Are Never Treated as OTPs**: Copying `123456`, phone numbers, order IDs, prices, dates (`2026-04-20`), times (`12:30`), versions (`v1.2.3`), or URLs without an OTP keyword **never triggers extraction or auto-erase**.
2. **Multi-Line Text, Code & Links Are Untouched**: Anything over 2 lines, over 240 characters, or classified as code/URL/file/image is kept verbatim.
3. **Never Wipes Newer Copies**: Before clearing the clipboard, NookClip verifies the system pasteboard `changeCount`. If you copied something new in the meantime, the scheduled erase cancels immediately.
4. **Starred & Pinned Entries Are Exempt from History Destruction**: Starred (`⌘ S`) or pinned (`⌘ P`) entries are never deleted from history even if *Also destroy from history* is enabled.
5. **Graceful Fallback Without Accessibility Permission**: Falls back to pure countdown erase without popping up permission dialogs.

---

## 4. Customization & Settings

Configure each option independently under **Settings → Privacy → Auto-Burn & Clipboard Erase**:

| Setting | Default | Options |
| :--- | :--- | :--- |
| **Auto-extract verification codes** | On | Toggle automatic extraction of pure codes from OTP messages |
| **Auto-erase verification codes** | **After paste or 60s** | Never / Countdown only (30s, 60s, 2m, 5m) / **After paste or 30s** / **After paste or 60s** |
| **Auto-erase sensitive credentials** | **After 30s** | Never / After 30s / 60s / 2m / 5m / After paste or 30s / After paste or 60s |
| **Also destroy from history when erased** | Off | Permanently removes the entry from NookClip history (bypassing Trash) when erased |
