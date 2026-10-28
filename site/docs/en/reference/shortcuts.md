# Keyboard Shortcuts Reference

NookClip is built for a full-keyboard workflow. Almost every action can be performed without touching the mouse.

---

## 1. Global Shortcuts (Work in Any App)

| Shortcut | Action | Notes |
| :--- | :--- | :--- |
| **`⌘ ⇧ V`** | Summon / Hide Main Panel | Customizable under **Settings → Paste** |
| **`⌃ ⌥ V`** | Start / Stop Paste Stack Recording | Copies flow into the floating queue; press again to close |
| **`⌘ ⌥ P`** | Restore Pinned Note Mouse Clicks | Exits Click-Through Lock Mode on a pinned note |

---

## 2. Main Panel: Navigation & Selection

| Shortcut / Action | Action | Notes |
| :--- | :--- | :--- |
| **`↑` / `↓`** | Move Selection Up / Down | Hold to scroll smoothly |
| **`⇧ ↑` / `⇧ ↓`** | Extend Multi-Selection Up / Down | Enters batch mode |
| **Mouse Vertical Drag** | Drag-Select Range | Hold `Shift` to add to selection; auto-scrolls at edges |
| **`⌘ + Click`** | Toggle Single Entry Selection | Select non-adjacent entries |
| **`⌘ T`** | Cycle Time Groups | Jump between Today, Yesterday, Earlier |
| **`⌥ ↑` / `⌥ ↓`** | Jump to Previous / Next Diff Hunk | Active inside Inline Diff (`⌘ D`) |

---

## 3. Main Panel: Paste & Extract

| Shortcut | Action | Notes |
| :--- | :--- | :--- |
| **`⏎` (Return)** | Paste & Close Panel | Batch merge-paste when multi-selected; launches app when an app card is selected |
| **`⌥ ⏎`** | Plain Text Paste / Paste Stack | Strips formatting on a single text item; **starts Paste Stack when multiple items or table/contact rows are selected** |
| **`⌃ ⏎`** | Scrubbed Paste | Replaces 19 types of secrets with `<API_KEY_1>` placeholders before pasting |
| **`⌃ ⇧ ⏎`** | Unscrub Paste | Restores placeholders back to original secrets from in-memory map |
| **`⌘ ⏎`** | Paste & Keep Panel Open | Pastes into active window without hiding NookClip |
| **`⌘ C`** | Copy to System Clipboard | Updates clipboard without pasting |
| **`⌘ D`** | Inline Diff / Exit Diff | Also available in batch bar, preview header, and context menu; press `↑↓` while diffing to live-swap rows |
| **`⌘ C` (in Diff)** | Copy Merged Result | Copies text assembled from your Keep New / Old / Both choices |
| **`⏎` (in Diff)** | Paste Merged Result | Pastes merged text into active window and closes panel |

---

## 4. Main Panel: Organize & Manage

| Shortcut | Action | Notes |
| :--- | :--- | :--- |
| **`⌘ P`** | Pin to Screen | Floats selected entry on top of all windows; pressing again replaces in place |
| **`⌘ S`** | Star / Unstar Entry | Starred items are exempt from auto-cleanup |
| **`⌘ R`** | Rename / Set Custom Alias | Leave empty and press `Return` to clear alias |
| **`⌘ L`** | Edit Tags | Opens tag editor popover (supports batch tagging) |
| **`⌘ ⌫`** | Delete Selected Entries | Press `⌘ Z` within 10s to undo; otherwise moves to Trash |
| **`⌘ Z`** | Undo Last Delete | Restores deleted items in place within 10 seconds |

---

## 5. Main Panel: Search, Filter & Layered Return

| Shortcut | Action | Notes |
| :--- | :--- | :--- |
| **Just Type** | Instant Type-to-Search | No need to focus search bar first |
| **`⌘ F`** | Focus Search & Expand Filter Drawer | Opens category grid and tag stream |
| **`⌘ ↓`** | Expand / Collapse Filter Drawer | Toggles filter drawer below search bar |
| **`⌘ ]` / `⌘ [`** | Next / Previous Non-Empty Category | Automatically skips empty category slots |
| **`⌫` (Backspace)** | Remove Filters Step by Step | When search box is empty, clears `Tag → Category` |
| **`Esc`** | Layered Return | Unwinds: `Popover → Filter Drawer → Inline Diff → Multi-Select → Search & Filters → Close Panel` |
| **`⌘ ,`** | Open Settings | Configure General, Paste, Privacy, Sync, and Storage |
