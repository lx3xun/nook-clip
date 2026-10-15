import AppKit
import Foundation

/// 预览数据提供者：把条目路径转为预览所需数据（分辨率、文件大小、路径有效性、
/// 全图/缩略图），并集中预览区的剪贴板复制与敏感明文自毁出口。
/// PreviewPane 与各预览卡片不直接调用 FileManager、FileStore.shared 或 PasteService.shared。
/// 文件元数据方法线程安全（后台懒加载场景）；剪贴板方法在主线程视图上下文调用。
struct PreviewDataProvider {
    /// 载荷图片缓存与元数据（具体类型：图片缓存 API 不在 PayloadStore 协议内）
    let fileStore: FileStore
    let clipboardWriter: any ClipboardWriter

    /// 叶子预览卡片的组合默认（色值/文件/图片/OCR 卡）：纯展示视图无替身需求，
    /// 按「小接口原则」不做参数穿透接线；主路径（MainView → PreviewPane）为全注入。
    static let live = PreviewDataProvider(fileStore: .shared, clipboardWriter: PasteService.shared)

    // MARK: - 文件元数据

    func imageInfo(for path: String) -> (dimensions: String, fileSize: String)? {
        fileStore.imageInfo(for: path)
    }

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func fileSize(atPath path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
    }

    // MARK: - 图片

    /// 预览解码：按预览窗格量级下采样（≤2048px），不驻留 5K 原图全尺寸位图
    func previewImage(for path: String) -> NSImage? {
        fileStore.thumbnail(for: path, maxPixelSize: FileStore.previewMaxPixelSize)
    }

    func thumbnail(for path: String, maxPixelSize: CGFloat) -> NSImage? {
        fileStore.thumbnail(for: path, maxPixelSize: maxPixelSize)
    }

    // MARK: - 剪贴板出口（MainActor：ClipboardWriter 协议随实现隔离，003 警告清理）

    /// 敏感明文查看到期后的自毁入口：仅当系统剪贴板仍为该明文时清空
    @MainActor
    func clearClipboardIfContent(matches plainText: String) {
        clipboardWriter.clearClipboardIfContent(matches: plainText)
    }

    @MainActor
    @discardableResult
    func copyText(_ text: String, containsSensitive: Bool = false) -> Bool {
        let success = clipboardWriter.copyText(text, containsSensitive: containsSensitive)
        if success {
            NotificationCenter.default.post(name: .restoreKeyboardFocus, object: nil)
        }
        return success
    }
}
