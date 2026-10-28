# Offline Image OCR & Search by Text

Screenshots of error logs, tables, or slides often contain text you need to copy or search for later.

NookClip integrates Apple's native **Vision framework** for 100% offline, on-device optical character recognition (OCR).

---

## 1. Why On-Demand OCR?

Running OCR automatically in the background on every single copied image wastes CPU/battery and bloats RAM.

NookClip uses an **On-Demand OCR** design:
- **Zero Idle Overhead**: Copying images normally stores a lightweight snapshot while keeping background memory around ~20MB.
- **Instant When Needed**: Click **Recognize Text** on any image entry to extract text offline in ~0.2 seconds.

---

## 2. How to Extract Text from an Image

1. Select an image entry in NookClip.
2. Click **Recognize Text** (magnifying glass badge) on the card or at the top of the preview pane.
3. The extracted text appears right inside the preview pane.
4. Select any portion of the text or click **Copy Text** to copy it all.

---

## 3. Search Images by Their Text

Once OCR has been run on an image, NookClip indexes the extracted text into your local SQLite FTS5 search index:

- Next time you type a word, error code, or invoice number that appeared inside that screenshot,
- **The image entry itself will appear in your search results with the matching text highlighted!**
