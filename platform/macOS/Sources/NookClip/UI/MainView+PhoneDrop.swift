import AppKit
import SwiftUI
import ImageIO

extension MainView {
    // 手机快传落地（LanIncomingDrop → 系统剪贴板 + 历史库）。
    // ClipboardMonitor 会跳过本应用自身写入（internalMarker），所以这里必须
    // **显式** store.save，不能指望监听器再抓一次；否则手机发来的内容不会进历史。

    /// 手机快传回传：写入系统剪贴板 + 存入历史库 + 轻提示（spec 014 · US1）。
    ///
    /// 说明：ClipboardMonitor 会跳过本应用自身写入（internalMarker），所以这里必须
    /// **显式** store.save，不能指望监听器再抓一次；否则手机发来的内容不会进历史。
    func receiveFromPhone(_ drop: LanIncomingDrop) {
        switch drop.kind {
        case .text:
            guard let text = drop.text, !text.isEmpty else { return }
            _ = PasteService.shared.copyText(text)
            let item = ClipboardItem(
                type: .text,
                title: "",
                summary: text,
                sourceAppBundleId: SourceAppModel.phoneDropBundleID,
                sourceAppName: L10n.tr("landrop.source_name"),
                sourcePlatform: "ios"
            )
            _ = store.save(item)
        case .image:
            guard let rawData = drop.data, !rawData.isEmpty else { return }
            let normalized = Self.normalizePhoneDropImageData(rawData, mimeType: drop.mimeType)
            guard let path = try? store.payloadStore.save(data: normalized.data, preferredExtension: normalized.ext) else { return }
            let customName = drop.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (customName.isEmpty || customName == "upload")
                ? L10n.tr("landrop.image_fallback_title")
                : customName
            let summary = Self.phoneDropImageSummary(forPath: path, dataCount: normalized.data.count)
            let item = ClipboardItem(
                type: .image,
                title: title,
                summary: summary,
                payloadPath: path,
                sourceAppBundleId: SourceAppModel.phoneDropBundleID,
                sourceAppName: L10n.tr("landrop.source_name"),
                sourcePlatform: "ios"
            )
            guard store.save(item) else { return }
            let persisted = store.items.first ?? item
            PasteService.shared.copyOnly(persisted)
        case .file:
            guard let data = drop.data, !data.isEmpty else { return }
            let ext = Self.phoneDropFileExtension(for: drop)
            guard let path = try? store.payloadStore.save(data: data, preferredExtension: ext) else { return }
            let customName = drop.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (customName.isEmpty || customName == "upload")
                ? L10n.tr("landrop.file_fallback_name")
                : customName
            let item = ClipboardItem(
                type: .file,
                title: title,
                summary: path,
                payloadPath: path,
                sourceAppBundleId: SourceAppModel.phoneDropBundleID,
                sourceAppName: L10n.tr("landrop.source_name"),
                sourcePlatform: "ios"
            )
            guard store.save(item) else { return }
            let persisted = store.items.first ?? item
            PasteService.shared.copyOnly(persisted)
        }
        showScrubFeedback(L10n.tr("landrop.received_toast"))
    }

    /// 将手机上传的任意图片字节（JPEG / HEIC / WebP / GIF / PNG / TIFF）归一化为
    /// macOS 系统剪贴板原生支持的 PNG（或 TIFF 兜底），并自动应用 EXIF 方向旋转，
    /// 避免非 PNG 原始字节被当作 `.tiff` 写入 `NSPasteboard` 导致其它应用无法粘贴。
    static func normalizePhoneDropImageData(_ data: Data, mimeType: String) -> (data: Data, ext: String) {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let isPNGBytes = data.count >= pngMagic.count && Array(data.prefix(pngMagic.count)) == pngMagic

        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
            if isPNGBytes && orientation == 1 {
                return (data, "png")
            }
            let width = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let height = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
            let maxDim = max(width, height)
            if maxDim > 0 {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDim,
                ]
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                   let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                    return (png, "png")
                }
            }
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
               let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                return (png, "png")
            }
        }

        if isPNGBytes {
            return (data, "png")
        }
        if let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "png")
        }
        if let image = NSImage(data: data),
           let tiff = image.tiffRepresentation {
            if let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                return (png, "png")
            }
            return (tiff, "tiff")
        }
        return (data, "png")
    }

    /// 生成与捕获管线（`ingest_image_item`）一致的图片摘要（尺寸 + 大小 + 内容哈希前 8 位），
    /// 保证不同图片不会因固定标题发生去重碰撞，相同图片重复发送则正常合并计数。
    static func phoneDropImageSummary(forPath path: String, dataCount: Int) -> String {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let hashPrefix = String(stem.prefix(8))
        let sizeDesc = ByteCountFormatter.string(fromByteCount: Int64(dataCount), countStyle: .file)
        if let dims = FileStore.pixelDimensions(atPath: path) {
            return "\(dims.width) × \(dims.height) px · \(sizeDesc) #\(hashPrefix)"
        }
        return "\(sizeDesc) #\(hashPrefix)"
    }

    /// 由回传 MIME / 文件名推断落盘扩展名（无则回退 dat）。
    static func phoneDropFileExtension(for drop: LanIncomingDrop) -> String {
        let fromName = (drop.fileName as NSString).pathExtension
        if !fromName.isEmpty { return fromName.lowercased() }
        switch drop.mimeType.lowercased() {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/webp": return "webp"
        case "image/tiff": return "tiff"
        case "application/pdf": return "pdf"
        case "application/json": return "json"
        case "text/plain; charset=utf-8", "text/plain": return "txt"
        default: return "dat"
        }
    }
}
