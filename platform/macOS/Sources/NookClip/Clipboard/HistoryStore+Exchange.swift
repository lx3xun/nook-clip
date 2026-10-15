import AppKit
import Foundation

// MARK: - 备份导出与恢复导入（T031：转发 HistoryExchangeService，签名不变）
extension InMemoryHistoryStore {
    func exportToJSON(mode: SensitiveExportMode = .masked) throws -> Data {
        let jsonStr = try rustStore.engine.exportJson(mode: mode)
        return jsonStr.data(using: .utf8) ?? Data()
    }
    /// FR-005：Markdown 导出走 Rust exchange，携带敏感模式（排除/掩码/明文）
    func exportToMarkdown(mode: SensitiveExportMode = .masked) throws -> String {
        try rustStore.engine.exportMarkdown(mode: mode)
    }

    /// 导入成功后全量刷新内存镜像（导入属全量变更，T041 置全量对账）
    func importFromJSON(_ data: Data) throws -> Int {
        let rust = rustStore
        // 尝试以 legacy [ClipboardItem] 格式解码
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let legacyItems = try? decoder.decode([ClipboardItem].self, from: data) {
                var imported = 0
                let existingIDs = Set(rust.page(limit: 100000, offset: 0).map(\.id))
                for item in legacyItems {
                    if existingIDs.contains(item.id) {
                        continue
                    }
                    if rust.save(item) != nil {
                        imported += 1
                    }
                }
                if imported > 0 {
                    items = rust.page(limit: Self.pageSize, offset: 0)
                    trashItems = rust.trashItems()
                    refreshHasMore()
                    publishMutation()
                }
                return imported
            }
        guard let jsonStr = String(data: data, encoding: .utf8) else {
            throw NookClipError.InvalidData("Invalid UTF-8 encoding in backup file")
        }
        let report = try rust.engine.importJson(jsonContent: jsonStr)
        if report.importedCount > 0 {
            items = rust.page(limit: Self.pageSize, offset: 0)
            trashItems = rust.trashItems()
            refreshHasMore()
            publishMutation()
        }
        return Int(report.importedCount)
    }
}


// MARK: - 首次启动演示数据播种
extension InMemoryHistoryStore {
    /// 空库时播种 7 条核心功能演示记录；仅每台设备一次
    ///（涵盖上手引导、敏感凭证加密、代码/JSON 高亮、离线 OCR 图片、链接二维码、色彩胶囊与快捷键速查）
    func seedDemoItemsIfNeeded() {
        guard rustStore.page(limit: 1, offset: 0).isEmpty,
              !defaults.bool(forKey: Self.demoSeededKey) else { return }

        let now = Date.now
        let secretPlain = "sk-proj-NookDemoKeyForLocalEncryption256GCM"
        let secretMasked = "sk-proj-••••••••56GCM"

        var seeded: [ClipboardItem] = [
            // 1. 欢迎与 30 秒上手指南（默认首行选中）
            ClipboardItem(
                type: .text,
                title: L10n.tr("demo.item1.title"),
                summary: L10n.tr("demo.item1.summary"),
                createdAt: now,
                lastUsedAt: now,
                isFavorite: true,
                sourceAppBundleId: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip",
                sourceAppName: "NookClip"
            ),
            // 2. 敏感凭证保护演示（AES-256-GCM 加密落盘，仅存本机）
            ClipboardItem(
                type: .text,
                title: L10n.tr("demo.item2.title"),
                summary: secretMasked,
                createdAt: now.addingTimeInterval(-60),
                lastUsedAt: now.addingTimeInterval(-60),
                sourceAppBundleId: "com.apple.Terminal",
                sourceAppName: "Terminal",
                isSensitive: true,
                encryptedContent: KeychainCryptoService.shared.encrypt(text: secretPlain)
            ),
            // 3. 代码高亮与 JSON 格式化合一演示
            ClipboardItem(
                type: .text,
                title: L10n.tr("demo.item3.title"),
                summary: L10n.tr("demo.item3.summary"),
                createdAt: now.addingTimeInterval(-180),
                lastUsedAt: now.addingTimeInterval(-180),
                isFavorite: true,
                sourceAppBundleId: "com.apple.dt.Xcode",
                sourceAppName: "Xcode",
                metadata: ClipboardMetadata(language: "json")
            ),
            // 4. 链接解析与跨端二维码演示
            ClipboardItem(
                type: .url,
                title: L10n.tr("demo.item5.title"),
                summary: "https://github.com/lx3xun/nook-clip",
                createdAt: now.addingTimeInterval(-900),
                lastUsedAt: now.addingTimeInterval(-900),
                sourceAppBundleId: "com.apple.Safari",
                sourceAppName: "Safari",
                metadata: ClipboardMetadata(url: "https://github.com/lx3xun/nook-clip")
            ),
            // 5. 十六进制色彩胶囊与 HEX/RGB 转换演示
            ClipboardItem(
                type: .text,
                title: L10n.tr("demo.item6.title"),
                summary: "#007AFF",
                createdAt: now.addingTimeInterval(-1800),
                lastUsedAt: now.addingTimeInterval(-1800),
                sourceAppBundleId: "com.figma.Desktop",
                sourceAppName: "Figma"
            ),
            // 6. 进阶快捷键速查卡（时间戳设为昨天，自然展示「今天 / 昨天」时间分组与时间轴跳转）
            ClipboardItem(
                type: .text,
                title: L10n.tr("demo.item7.title"),
                summary: L10n.tr("demo.item7.summary"),
                createdAt: now.addingTimeInterval(-86400),
                lastUsedAt: now.addingTimeInterval(-86400),
                isFavorite: true,
                sourceAppBundleId: "com.apple.Notes",
                sourceAppName: L10n.tr("demo.source.notes")
            )
        ]

        // 插入第 4 条（索引 3）：图片与离线 Vision OCR 演示（动态绘制带清晰中英文排版卡片，支持真实 OCR 识别）
        if let imageData = Self.makeDemoOCRCardPNGData(),
           let payloadPath = try? payloadStore.save(data: imageData, preferredExtension: "png") {
            let imageItem = ClipboardItem(
                type: .image,
                title: L10n.tr("demo.item4.title"),
                summary: "640 × 320",
                createdAt: now.addingTimeInterval(-600),
                lastUsedAt: now.addingTimeInterval(-600),
                payloadPath: payloadPath,
                sourceAppName: L10n.tr("demo.source.screenshot")
            )
            seeded.insert(imageItem, at: 3)
        }

        var persistedItems: [ClipboardItem] = []
        for item in seeded {
            let raw = item.isSensitive ? secretPlain : item.summary
            if let saved = rustStore.save(item, rawText: raw) {
                persistedItems.append(saved)
            } else {
                persistedItems.append(item)
            }
        }
        items = persistedItems
        defaults.set(true, forKey: Self.demoSeededKey)
        hasMoreItems = false
    }

    /// 生成带清晰文字排版的演示 PNG（640×320），让用户点击「识别文字」即可真实提取出中英文内容
    private static func makeDemoOCRCardPNGData() -> Data? {
        let width = 640
        let height = 320
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        defer { NSGraphicsContext.restoreGraphicsState() }

        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.18, alpha: 1.0).setFill()
        rect.fill()

        let cardRect = rect.insetBy(dx: 24, dy: 24)
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 16, yRadius: 16)
        NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.28, alpha: 1.0).setFill()
        path.fill()
        NSColor(calibratedRed: 0.23, green: 0.51, blue: 0.96, alpha: 0.5).setStroke()
        path.lineWidth = 2
        path.stroke()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 28),
            .foregroundColor: NSColor.white
        ]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor(calibratedRed: 0.58, green: 0.77, blue: 0.99, alpha: 1.0)
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1.0)
        ]

        NSString(string: "NookClip · Apple Vision OCR").draw(
            at: NSPoint(x: 52, y: 218),
            withAttributes: titleAttrs
        )
        NSString(string: L10n.tr("demo.ocr_card.subtitle")).draw(
            at: NSPoint(x: 52, y: 170),
            withAttributes: subtitleAttrs
        )
        NSString(string: L10n.tr("demo.ocr_card.hint")).draw(
            at: NSPoint(x: 52, y: 112),
            withAttributes: bodyAttrs
        )
        NSString(string: "100% On-Device · Zero Cloud Upload · Instant FTS5").draw(
            at: NSPoint(x: 52, y: 68),
            withAttributes: bodyAttrs
        )
        ctx.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}