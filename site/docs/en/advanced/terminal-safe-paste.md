# Terminal Safe-Paste

Pasting commands copied from web tutorials, AI chats, or runbooks into a terminal carries two classic risks:

1. **Multi-line text includes newline characters (`\n`)** — the terminal treats each newline as pressing `Return` and executes every line before you can edit parameters;
2. **High-risk commands or hidden payloads** — such as `rm -rf`, `sudo`, `curl ... | sh`, `git push --force`, `DROP TABLE`, or hidden zero-width / Trojan Source characters.

**Terminal Safe-Paste intercepts risky pastes targeting a terminal app, highlights the exact risk reasons, and lets you convert multi-line scripts into a single `&&`-joined line that sits safely at your prompt without auto-running.**

---

## 1. When Does It Trigger?

The guard only intervenes when **both** conditions below are met — pasting code into editors, browsers, or chat apps is never interrupted:

| Condition | Rule |
| :--- | :--- |
| **1. Frontmost app is a Terminal** | Built-in support for **Terminal.app, iTerm2, Warp, Alacritty, kitty, Ghostty, WezTerm, Hyper, and Tabby**; also supports custom terminal apps and optional protection inside **VS Code / Cursor / Zed / JetBrains** integrated terminals |
| **2. Content matches a risk rule** | Contains **multi-line commands (`≥ 2` effective lines)**, a **trailing newline**, or any of **10 high-risk command / hidden-character categories** |

### 10 Built-In High-Risk Categories

- **Multi-line & trailing newlines**: `≥ 2` non-comment lines or trailing `\n` / `\r` (which immediately execute upon paste)
- **Privilege escalation & destructive delete**: `sudo` / `su` / `doas`, `rm -rf` (`rm -fr`, `--no-preserve-root`)
- **Remote script execution**: `curl ... | sh`, `wget ... | bash`
- **Disk & permission hazards**: `dd if=... of=/dev/...`, `mkfs`, `diskutil eraseDisk`, `chmod -R 777`, `chown -R`
- **Process & service termination**: `kill -9`, `killall`, `pkill`, `systemctl stop/disable`, `launchctl unload`
- **Git history overwrite**: `git reset --hard`, `git push --force` / `-f`, `git clean -fd`
- **Database destruction**: `DROP DATABASE`, `DROP TABLE`, `TRUNCATE TABLE`, `DELETE FROM` without `WHERE`
- **Firewall & SSH key tampering**: `iptables -F`, `pfctl -F`, `ufw disable`, writing to `~/.ssh/authorized_keys`
- **Hidden-character attacks**: Zero-width / bidirectional Trojan Source characters, ANSI escape sequences, Base64 decode-to-shell pipes

> 💡 **Preview Warning Banner**: Selecting any entry with these patterns in NookClip displays a red warning banner at the top of the preview pane listing the exact matched reasons before you even press paste.

---

## 2. Confirmation Dialog Options

When triggered, the guard dialog displays the matched risk tags and full command preview with three actions:

### Safe Paste (Recommended)

Joins multi-line commands with ` && ` into a **single line** and strips trailing newlines so it sits at your terminal prompt **without executing**. You can review the command, edit flags with arrow keys, or press `⌃C` to abort.

### Paste as-is

Pastes the original multi-line text and newlines untouched (useful when pasting into `vim` / `nano`, a multi-line heredoc, or a trusted script).

### Cancel (`Esc`)

Aborts the paste without sending anything to the terminal.

---

## 3. What Passes Through Without Interruption?

- **Single-line safe commands** (such as `ls -la`, `git status`, `brew update` without a trailing newline) paste immediately with zero dialogs.
- **Comments and blank lines**: `#` comment lines and blank lines are ignored when counting command lines, and backslash `\` line continuations are folded first.
- **Non-terminal apps**: Pasting into Notes, browsers, Slack, or Word never triggers the terminal guard.

---

## 4. Customization & Settings

Go to **Settings → Paste → Terminal Safe-Paste**:

1. **Terminal Safe-Paste Guard**: Master toggle (enabled by default).
2. **Also protect IDE integrated terminals**: When enabled, pasting **high-risk commands** while VS Code, Cursor, Windsurf, Zed, Xcode, or JetBrains IDEs are frontmost also triggers confirmation (normal multi-line code editing is never interrupted).
3. **Custom Terminal Apps**: Click **Add Terminal App…** to pick any terminal app from `/Applications` or add its Bundle ID.
