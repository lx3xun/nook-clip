# App Exclusion Rules & Password Manager Protection

Some applications should never have their copied contents recorded in clipboard history — especially password managers or confidential internal tools.

NookClip combines **Automatic Password Manager Exclusion** with a **Custom App Blacklist**.

---

## 1. Automatic Password Manager Exclusion

Out of the box, NookClip honors macOS clipboard privacy markers (`org.nspasteboard.ConcealedType` and `TransientType`) and automatically ignores copies from popular password managers:

- **1Password**
- **Bitwarden**
- **KeePassXC / MacPass**
- **Enpass / Dashlane**
- **macOS Passwords & Keychain Access**

Copied passwords still paste normally with `⌘ V`, but NookClip never records them.

---

## 2. Adding Custom Excluded Apps

To exclude any Mac app from being recorded:

1. Click the NookClip menu bar icon → **Settings** (or press `⌘ ,`).
2. Switch to the **Privacy** tab.
3. Click the **`[+]`** button under Excluded Applications.
4. Select the app from `/Applications` (e.g. `1Password.app`) and click **Add**.
5. Copies from that app are immediately ignored going forward.
