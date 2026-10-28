# Batch Actions & Undo Delete

When you need to clean up a dozen clips at once or merge several notes into a single message, NookClip provides smooth **Batch Multi-Select** and a **10-Second Undo Delete** safety net.

---

## 1. Entering Batch Multi-Select Mode

### Keyboard Multi-Select
- **`⇧ ↑` / `⇧ ↓` (Shift + Up/Down)**: Extend selection across consecutive rows.
- **`Esc`**: Clear multi-selection and return to single selection.

### Mouse Drag Selection
- **Click and drag vertically** across the list to select a range of entries in one motion.
- Hold `Shift` while dragging to add to your existing selection; dragging near the top or bottom edge auto-scrolls the list smoothly.
- **`⌘ + Click`**: Toggle individual non-adjacent entries.

---

## 2. High-Frequency Batch Actions

When multiple entries are selected, the bottom batch toolbar appears:

- **Merge Paste (`⏎` Return)**: Joins all selected text items with newlines and pastes them together in one shot.
- **Start Paste Stack (`⌥ ⏎`)**: Queues all selected items into the sequential Paste Stack (see [Paste Stack](./../advanced/paste-stack.md)).
- **Compare Two Entries (`⌘ D`)**: When exactly **2 entries** are selected, click **Diff** in the bottom toolbar (or press `⌘ D`) to open Inline Diff (see [Inline Diff](./../advanced/inline-diff.md)).
- **Batch Tag (`⌘ L`) & Batch Delete (`⌘ ⌫`)**: Tag or delete all selected entries at once.

---

## 3. 10-Second Undo Delete (`⌘ Z`)

Deleted an important entry by mistake?

- Deleting one or more items shows a **"Deleted · Press ⌘Z within 10s to undo"** toast bar at the bottom of the panel.
- Press **`⌘ Z`** before the countdown finishes to restore all deleted items to their exact original positions, timestamps, and tags.
- Even after 10 seconds, deleted items remain safely in the **Trash** category until emptied.
