# Basic Usage

NookClip is designed around a **zero-friction, keyboard-first workflow**. Keep copying normally with `⌘ C`, and summon your history whenever you need it.

---

## 1. Summon & Dismiss the Panel

- **Keyboard Shortcut**: Press **`⌘ ⇧ V`** (Command + Shift + V) from any application.
- **Menu Bar Click**: Click the NookClip icon in the macOS menu bar.
- **Auto-Dismiss**: Click anywhere outside the panel or press **`Esc`** to close it cleanly without stealing focus from your active app.

---

## 2. Browse & Preview Entries

The panel uses a clean **Left List · Right Preview** split layout:

- **Navigate**: Use **`↑` / `↓`** arrow keys to move through your history.
- **Rich Live Preview**: The right pane immediately displays the full content of the selected entry:
  - **Plain Text**: Full text with character and line counts.
  - **Code**: Automatic language detection with syntax highlighting.
  - **Images**: Crisp thumbnail, pixel dimensions, and file size.
  - **Colors**: Copying `#1677FF` or `rgb(...)` renders a live color swatch.
  - **Files & Links**: File path inspection or URL preview card (with an instant QR code for scanning on your phone).

---

## 3. Type-to-Search (No Need to Click the Search Box)

As soon as you summon the panel, **just start typing** — no need to click the search bar or press `⌘ F` first:

- Your keystrokes go straight into the search field.
- Results filter in under a millisecond with matched keywords highlighted in both the list and preview pane.

---

## 4. Four Core Paste Actions

Once you select an entry, choose how to paste it:

| Shortcut | Action | Best For |
| :--- | :--- | :--- |
| **`⏎` (Return)** | **Direct Paste**: Closes the panel and pastes into the active app | Everyday pasting |
| **`⌥ ⏎` (Option + Return)** | **Plain Text Paste / Paste Stack**: Strips formatting for a single text item; starts the Paste Stack when multiple items or structured table/contact rows are selected | Pasting clean text into editors, or sequential form filling |
| **`⌘ ⏎` (Command + Return)** | **Paste & Keep Open**: Pastes into the active app while keeping the panel open | Comparing or pasting multiple items in a row |
| **`⌘ C`** | **Copy Only**: Writes the item to the system clipboard without pasting | Updating the clipboard to paste manually later |

> 💡 **Partial Text Selection**: You can also highlight any substring inside the right preview pane with your mouse and press `⌘ C` to copy just that selection.

---

## 5. Layered `Esc` Navigation

To prevent accidentally closing the panel and losing your current filter state, **`Esc`** unwinds one layer at a time:

1. If the **Rename Alias** or **Edit Tags** popover is open, `Esc` closes the popover;
2. If the **Filter Drawer** below the search bar is expanded, `Esc` collapses the drawer;
3. If **Inline Diff (`⌘ D`)** is active, `Esc` exits diff mode back to normal preview;
4. If **Batch Multi-Select** is active, `Esc` clears the multi-selection;
5. If a **search query, tag filter, category filter, or time group** is active, `Esc` clears them step by step;
6. When all filters are clear, `Esc` hides the main panel.
