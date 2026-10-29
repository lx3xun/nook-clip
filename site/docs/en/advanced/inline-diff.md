# Inline Diff (`⌘ D`)

Comparing two config revisions, checking what an AI changed in your code, or verifying which numbers changed in a contract usually means opening an external diff tool and pasting both versions into separate tabs.

**NookClip brings diffing right into your clipboard history: press `⌘ D` (or click "Diff" in the batch bar, preview header, or context menu) to turn the preview pane into a line- and word-level red/green diff view, live-swap rows with `↑↓`, and cherry-pick hunks to copy or paste a merged result.**

---

## 1. How to Trigger Inline Diff

In addition to pressing **`⌘ D`**, you can click any of the 3 visible UI entry points: the **Diff button in the bottom batch toolbar** (when 2 items are selected), **Diff inside the ⋯ More menu of the top-right preview header**, or **Compare Two Entries (`⌘ D`) in the right-click context menu**.

| Your Selection | What NookClip Compares |
| :--- | :--- |
| 1st item selected (or nothing selected) | Compares the **top 2 entries** in the current list: #2 as **Old** and #1 as **New** |
| Single item #N (`N > 1`) selected | Compares **selected item #N** (**Old**) against **#1 at the top of the list** (**New**) |
| Exactly **2 items** multi-selected | Compares those two items: the lower row in the list is **Old**, the upper row is **New** |
| **3 or more items** selected | Shows a clear notice ("Select at most 2 items to compare") instead of guessing |

While diffing, both compared rows are highlighted in the left list with **Old** and **New** badges.

### Live-Swap Entries Without Exiting Diff Mode

You don't need to exit diff mode to compare against another history entry:

- **Press `↑` / `↓` or click any other row in the list**: Keeps the pinned anchor side fixed (by default **New**) and immediately swaps the other side to the newly selected row, refreshing the diff in real time.
- **Change which side is pinned**: Click the **Old** or **New** badge in the preview header (or click either active row in the list) to move the pin; or **`⌘`-click / `⇧`-click** another row to pin the current cursor row and compare against the clicked row.

### Exiting Diff Mode

- Press **`⌘ D`** again, or
- Press **`Esc`** (diff mode unwinds before multi-select and search filters), or
- Click **`×`** in the diff header or **Exit Diff** in the bottom bar.

---

## 2. Two-Level Highlighting (Line + Word/Character)

1. **Line background**: Deleted lines show a soft red background with `-`; added lines show a soft green background with `+`.
2. **Word & token emphasis**: When only part of a line changed (e.g. `timeout: 30` → `timeout: 60` or `maxRetryCount` → `maxRetryTotal`), only the changed tokens (`30`/`60` or `Count`/`Total`) are highlighted with deeper red/green pills, and deleted tokens include **strikethrough** so differences remain clear without relying on color alone.

> 💡 **Smart Tokenization**: Splits `camelCase`, `snake_case`, words, and numbers cleanly, while CJK characters, punctuation, and emojis split on character boundaries without breaking multi-byte sequences.

---

## 3. Three Diff Views

Switch anytime using the segmented control on the right of the summary banner:

- **Inline (Default)**: Deleted and added lines stacked vertically for compact, natural reading.
- **Side-by-Side**: **Old** on the left and **New** on the right with horizontal line alignment.
- **Changes Only**: Folds large unchanged context sections so you can focus strictly on modifications.

---

## 4. Copy or Paste Merged Output

The bottom action bar provides two primary exits:

- Click **Copy Merged (`⌘ C`)**: Writes the diff output text to your system clipboard;
- Click **Paste Merged (`⏎`)**: Pastes the merged result directly into your active window and closes the panel.

---
## 5. Shortcuts Inside Diff Mode

| Shortcut | Action |
| :--- | :--- |
| **`⌘ D`** | Enter / Exit Inline Diff |
| **`↑`** / **`↓`** (or click another row) | Keep pinned anchor side and live-swap the other entry (`⇧ ↑/↓` or `⌘-click` switches anchor) |
| **`⌥ ↑`** / **`⌥ ↓`** | Jump to previous / next changed hunk |
| **`⌘ C`** | Copy merged text |
| **`⏎`** | Paste merged text into active window |
| **`Esc`** | Exit Inline Diff |

---

## 6. Edge Cases & Safeguards

- **Unrecognized Images**: If one entry is an image without OCR text, NookClip prompts you to run **Recognize Text (OCR)** first.
- **Encrypted Sensitive Entries**: Requires clicking **Unlock & Compare** before decrypting; plaintext is wiped from memory as soon as you exit diff mode or close the panel.
