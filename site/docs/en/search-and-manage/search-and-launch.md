# Full-Text Search & App Launcher

NookClip uses an indexed local **SQLite FTS5** full-text engine so searching tens of thousands of clipboard entries stays under a millisecond.

---

## 1. Sub-Millisecond Full-Text Search

Summon the panel (`⌘ ⇧ V`) and start typing immediately:

- **Mixed-Language Matching**: Search across English words, Chinese phrases, code identifiers, URLs, and filenames.
- **Live Keyword Highlighting**: Matched terms are highlighted in yellow across both the list cards and the right preview pane.
- **Custom Alias Priority (`⌘ R`)**:
  For long SQL queries, boilerplate templates, or billing details you reuse often, select the entry and press **`⌘ R`** (Command + R) to assign a short alias (e.g. `invoice`). Typing the alias brings that entry straight to the top.

---

## 2. Instant App Launcher (Name & Pinyin Initials)

You can also launch installed macOS applications directly from NookClip without switching to Spotlight:

1. Press `⌘ ⇧ V` to summon the panel.
2. Type the application's name or initials (including Chinese Pinyin initials):
   - `term` or `zd` → **Terminal**
   - `code` → **Visual Studio Code**
   - `sf` → **Safari**
   - `wx` → **WeChat**
3. An application launch card appears at the top of the list — press **`⏎` (Return)** to bring that app to the front.
