# Phone Drop

Sending a long block of text, a screenshot, or a file from your Mac to your phone used to mean messaging it to yourself, signing into a cloud drive, or installing the same app on both devices. With an Android phone—or a device that isn't signed into the same account—that route often just doesn't work.

**Phone Drop turns it into "scan and you're done":** select any item on your Mac, tap **Send to Phone**, and scan the QR code with your phone camera. The phone opens a web page where you can read and copy long text from your Mac and download original images or files, and you can push text and photos from the phone straight back to your Mac clipboard. **No app install is required, the mobile page adapts to your phone's language automatically, and data travels only across your local network—never through any cloud server.**

---

## 1. How to Trigger It / How It Works

1. Select any item in the NookClip main panel (text, code, image, or file).
2. Open the **⋯ More** menu at the right of the preview header and choose **Send to Phone**.
3. A popover shows a QR code, the **LAN address**, and a live countdown. It stays valid for **5 minutes** by default.
4. Connect your phone to the **same Wi-Fi** as your Mac, scan with the system camera, and the page opens in the phone browser—ready to send and receive.

> If the selected item is a URL, the QR code defaults to a **Link QR** and hints that you can switch to **Two-way transfer**, so the phone can open the link and still send content back to the Mac.

Meanwhile, your Mac starts a small temporary service on the local machine and generates a **one-time random token**. Only a device that scanned this QR code can access it. **Keep the Phone Drop view open during transfer**—closing the popover, dismissing the main panel, or letting the countdown finish stops the service immediately, disconnects the link, and releases the port.

---

## 2. What You Can Do on the Phone

The phone page has two parts: the top shows content from your Mac, and the bottom sends content back.

**Download (Mac → Phone)**

| Content type | What you do on the phone |
| :--- | :--- |
| Long text / code | Read it in full, then tap **Copy** to copy it to the phone clipboard |
| Image | View the original; long-press or tap **Download** to save it to the photo library |
| File | Tap **Download** to save it to the phone |

**Upload (Phone → Mac)**

| Content type | What you do on the phone |
| :--- | :--- |
| Text | Type in the box at the bottom of the page and tap **Send**; it lands on the Mac clipboard instantly and is saved to history |
| Image / file | Pick an image from the photo library, or choose a file, then send it back to the Mac in one tap |

When the Mac receives something, it shows a light toast ("Received clipboard content from your phone") and saves the item to history automatically, so you can keep using it just like any other entry.

---

## 3. Security Boundaries

- **Same local network only**: the Mac and phone must be on the same Wi-Fi / LAN; cross-network access is impossible.
- **One-time random token**: every session generates a fresh random token, so the link is valid only for that session—old QR codes won't open.
- **Auto-expires after 5 minutes**: the service shuts down when the default countdown ends, or immediately when you tap **Stop Sharing**.
- **Port released on close**: closing the popover or letting the countdown finish stops the temporary service at once and releases the port—there is no always-on listener.
- **50MB per upload**: any single file or image sent from the phone must be 50MB or smaller, so large files don't exhaust memory.
- **No cloud server involved**: all data moves directly between your Mac and your phone—never to a third-party server, and no account login is needed.

---

## 4. FAQ

**Q: The page won't open after scanning—what's wrong?**
First confirm the Mac and phone are on the same Wi-Fi. If the Mac has no LAN connection, NookClip shows "Connect to Wi-Fi or a LAN first"; connect and tap **Send to Phone** again.

**Q: Can I still scan after closing the panel?**
No. The Phone Drop view displays a reminder: "Keep this view open during transfer — closing or switching disconnects immediately." Closing the popover, dismissing the main panel, or letting the countdown finish stops the service at once, releases the port, and invalidates the old QR code and link. Tap **Send to Phone** again to generate a new QR code.

**Q: I uploaded from the phone but the Mac didn't respond.**
Make sure the Phone Drop QR code view is still open on your Mac (not closed or switched away) and both devices are on the same network. On success the Mac shows "Received clipboard content from your phone" and stores it in history.

**Q: Do I need to install an app on the phone?**
No. The phone opens a web page—just scan with your phone's built-in camera. It works on both iOS and Android.
