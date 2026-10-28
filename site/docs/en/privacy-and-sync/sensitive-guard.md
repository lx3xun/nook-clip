# Sensitive Guard & Local Encryption

Because your clipboard handles passwords, SSH private keys, and cloud tokens every day, NookClip protects sensitive credentials from capture through storage and display.

---

## 1. Automatic Credential Detection

When you copy text, NookClip's local engine inspects it in under a millisecond and automatically marks matching items as **Sensitive Credentials** (with a lock badge):

- **Cloud & AI API Keys**: OpenAI (`sk-...`), Anthropic (`sk-ant-...`), GitHub (`ghp_...` / `github_pat_...`), AWS (`AKIA...`), Slack tokens, etc.
- **Private Keys**: `-----BEGIN PRIVATE KEY-----`, `BEGIN RSA PRIVATE KEY`, and PEM blocks.
- **Auth Tokens & Connection Strings**: JWTs, Bearer tokens, and PostgreSQL / MySQL / MongoDB / Redis URIs containing passwords.
- **Financial & Identity Numbers**: Checksum-verified bank card numbers and national IDs.

---

## 2. AES-256-GCM At-Rest Encryption

Many clipboard managers store copied passwords as raw plaintext inside SQLite.

In NookClip:
- Every entry marked as sensitive is encrypted with **AES-256-GCM** before touching the disk;
- The master encryption key is protected by the **macOS Keychain** and a restricted local keyfile;
- Only ciphertext is stored in `library.db`.

---

## 3. Masked Previews (Shoulder-Surfing Protection)

When sharing your screen or working in public, opening your clipboard manager shouldn't expose raw passwords:

- **Masked by Default**: Sensitive entries appear as `••••••••` in both the list and preview pane.
- **Reveal on Demand**: Click the **Eye (Show Plaintext)** button in the preview pane to temporarily reveal the value; switching entries or closing the panel immediately re-masks it.

---

## 4. Two Strict Privacy Guarantees

1. **Local-Only by Default**: Sensitive entries never leave your Mac by default and are excluded from iCloud sync (unless you explicitly enable **End-to-End Encryption (E2EE)** and opt in to syncing encrypted sensitive entries).
2. **Never Indexed in FTS5**: Plaintext of sensitive entries is **never written to the SQLite FTS5 full-text index**, leaving zero plaintext fragments on disk.

> 💡 **See Also**: Need to share code containing secrets with AI? See [Scrubbed Paste & Unscrub (`⌃ ⏎`)](../advanced/scrub-paste.md). Want OTPs and secrets auto-cleared from the system clipboard after use? See [Auto-Burn & Clipboard Erase](./auto-burn.md).
