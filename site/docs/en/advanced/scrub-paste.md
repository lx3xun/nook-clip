# Scrubbed Paste & Unscrub (`⌃ ⏎`)

When asking ChatGPT, Claude, or other AI coding assistants to debug code or analyze logs, you often need to paste `.env` files, config snippets, or stack traces.

However, those snippets frequently contain real **API keys, database passwords, phone numbers, email addresses, internal IPs, or bank card numbers**. Redacting them by hand is slow and easy to miss.

**With Scrubbed Paste (`⌃ ⏎`), NookClip automatically replaces 19 types of sensitive values with readable semantic placeholders like `<API_KEY_1>` before pasting. When the AI replies with updated code containing those placeholders, press `⌃ ⇧ ⏎` to restore your real secrets in place.**

---

## 1. How to Use Scrubbed Paste (`⌃ ⏎`)

After copying code or logs containing secrets:

1. Press `⌘ ⇧ V` to summon NookClip and select the entry.
2. Press **`⌃ ⏎`** (Control + Return).
3. NookClip detects sensitive tokens in milliseconds, replaces them with semantic placeholders (`<API_KEY_1>`, `<PASSWORD_1>`, `<EMAIL_1>`), and pastes the scrubbed text into your active window.

### Why "Semantic" Placeholders?

Suppose your original snippet is:
```env
OPENAI_API_KEY={{OPENAI_KEY_f4e1dd07}}
BACKUP_KEY={{OPENAI_KEY_f4e1dd07}}
ADMIN_EMAIL={{EMAIL_c83dc5ef}}
```

Pressing **`⌃ ⏎`** pastes:
```env
OPENAI_API_KEY=<API_KEY_1>
BACKUP_KEY=<API_KEY_1>
ADMIN_EMAIL=<EMAIL_1>
```

- **Preserves Code Structure**: The AI still understands the data types and variable relationships without seeing your actual credentials.
- **Consistent Numbering**: Identical values receive the same placeholder (`<API_KEY_1>`), while distinct values increment (`<API_KEY_2>`).

### 19 Built-In Detection Rules
- **Developer Credentials**: OpenAI / Anthropic / AWS / GitHub tokens, generic API keys, Bearer tokens, JWTs, PEM private keys, database connection URIs (Postgres / MySQL / Mongo / Redis), password assignments.
- **Personal Identifiers**: Phone numbers, national IDs, bank card numbers, IBANs, email addresses.
- **Environment Info**: IPv4 / IPv6 addresses, internal hostnames, local home directory paths (`/Users/yourname/...` → `/Users/<USER_1>/...`).

> 🛡️ **Zero False Positives**: Bank cards are verified via **Luhn**, national IDs via **ISO 7064 MOD 11-2**, and IBANs via **MOD-97**. Everyday values like `127.0.0.1`, `/Users/Shared`, and ISO timestamps are never falsely redacted.
> You can also enable **offline person name & address detection** (powered by on-device macOS NaturalLanguage, 100% offline) and add **custom redaction rules** (keywords or regex + custom placeholder tag) under **Settings → Privacy**.

---

## 2. One-Key Unscrub (`⌃ ⇧ ⏎`)

When the AI responds with refactored code still containing `<API_KEY_1>` and `<EMAIL_1>`:

1. Copy the AI's reply.
2. Open NookClip and select the copied reply (the preview banner will note: `Detected N redacted placeholders`).
3. Press **`⌃ ⇧ ⏎`** (Control + Shift + Return).
4. NookClip swaps every `<API_KEY_1>` back to its original secret and pastes the restored code into your editor.

---

## 3. Proactive Preview Banner

To prevent accidentally pasting raw credentials with `⏎`:

- Whenever the selected entry contains sensitive tokens, a subtle amber banner appears at the top of the preview pane:
  > **Detected 2 sensitive items (API Key, Email) · Press ⌃⏎ for Scrubbed Paste**
- **Non-intrusive**: It never blocks you with a modal dialog — pressing `⏎` still pastes the original text if intended.
- **Configurable**: Toggle the banner anytime in **Settings → Privacy**.

---

## 4. Memory-Only Security Architecture

- **RAM-Only Mapping Table**: Placeholder-to-secret mappings live **strictly in volatile process memory (RAM)** — they are never written to SQLite, disk files, logs, or iCloud.
- **Auto-Purge**: The in-memory mapping table automatically self-destructs after 30 minutes of inactivity or when NookClip quits.
- **Manual Clear**: View the active mapping count and clear it with one click anytime in **Settings → Privacy**.
