import AppKit
import Foundation
import ImageIO
import OSLog

public final class FileStore: @unchecked Sendable {
    public static let shared: FileStore = {
        if NSClassFromString("XCTestCase") != nil {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("nook-test-content-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            return FileStore(directory: tempDir)
        }
        return FileStore(directory: AppPaths.contentDirectory)
    }()

    /// T052（FR-026）：迁移与孤儿清理失败必须留日志，不再静默吞错
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip",
        category: "FileStore"
    )

    public let directory: URL
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // 解码缩略图位图总内存上限 16MB（列表 64px 缩略图约 16KB/张，可缓存上百张及当前预览图）：
        // 避免高分辨率图片预览在后台驻留过多未压缩位图
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 120
        return cache
    }()
    /// 预览解码上限（像素）：预览窗格 aspectFit 展示量级（宽 ~500pt × 2x Retina
    /// + 余量）。超过该尺寸的原图按此下采样，避免 5K 截图/单反原片
    /// 的未压缩位图驻留
    static let previewMaxPixelSize: CGFloat = 1440

    /// 释放内存中的解码位图缓存（面板收起闲置后调用，不影响磁盘文件）
    public func clearMemoryCache() {
        thumbnailCache.removeAllObjects()
    }

    internal init(directory: URL = AppPaths.contentDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func save(data: Data, preferredExtension: String) throws -> String {
        try savePayloadAssetFile(
            storageDir: directory.path,
            data: data,
            preferredExtension: preferredExtension
        )
    }

    func load(path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    func remove(path: String?) {
        guard let path else { return }
        thumbnailCache.removeObject(forKey: "\(path)_\(Int(Self.previewMaxPixelSize))" as NSString)
        // 移除常用规格的缩略图缓存（如列表 80px、预览 300px 等），交由 NSCache 的 countLimit 自然淘汰，避免颠簸
        thumbnailCache.removeObject(forKey: "\(path)_80" as NSString)
        thumbnailCache.removeObject(forKey: "\(path)_120" as NSString)
        thumbnailCache.removeObject(forKey: "\(path)_300" as NSString)
        // 磁盘删除仅限本 store 管理的 Content 目录：
        // 文件类条目 payloadPath 指向用户原始文件（App Support 之外），历史清理/淘汰不得误删
        guard isManaged(path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// 路径是否位于本 store 管理的载荷目录（AppPaths.contentDirectory）内。
    /// 磁盘限额统计（enforceDiskLimit）也依赖此判定：文件类条目的 payloadPath 指向
    /// 用户原始文件，不计入 NookClip 自身缓存配额（审计 BUG-005）
    func isManaged(_ path: String) -> Bool {
        let rootPath = directory.standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return target == rootPath || target.hasPrefix(rootPath + "/")
    }

    /// T054（FR-026，审查 F-1）：本地载荷孤儿对账——删除受管目录中「无引用且
    /// 修改时间超过宽限」的文件。宽限策略对齐云端孤儿附件清理（24h，审计
    /// BUG-008 同源取舍：同步/迁移中途的文件尚未被引用时不得误删）。
    /// 仅扫描受管目录（AppPaths.contentDirectory），不触碰用户原始文件；
    /// 修改时间不可读时保守跳过（宁可暂留也不误删）。返回删除数量。
    @discardableResult
    func sweepOrphans(referencedPaths: Set<String>, olderThan: TimeInterval) -> Int {
        let count = try? sweepOrphanPayloadAssets(
            storageDir: directory.path,
            referencedFilenames: Array(referencedPaths),
            olderThanSeconds: olderThan
        )
        return Int(count ?? 0)
    }


    func thumbnail(for path: String, maxPixelSize: CGFloat = 80) -> NSImage? {
        let cacheKey = "\(path)_\(Int(maxPixelSize))" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        // cost = 解码位图字节数（T052）：使 totalCostLimit 按真实内存占用淘汰
        let cost = cgImage.bytesPerRow * cgImage.height
        thumbnailCache.setObject(image, forKey: cacheKey, cost: max(cost, 1))
        return image
    }

    /// 像素尺寸（只读元数据不解码全图；线程安全，供预览工具栏等轻量场景）
    static func pixelDimensions(atPath path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width: width, height: height)
    }

    func imageInfo(for path: String) -> (dimensions: String, fileSize: String)? {
        guard let attr = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attr[.size] as? Int64 else {
            return nil
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let formattedSize = formatter.string(fromByteCount: size)
        guard let dims = Self.pixelDimensions(atPath: path) else {
            return ("", formattedSize)
        }
        return (L10n.tr("general.pixels", dims.width, dims.height), formattedSize)
    }
}
