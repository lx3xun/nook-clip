import XCTest
import SwiftUI
@testable import NookClip

final class MainViewLayoutTests: XCTestCase {
    @MainActor
    func testHeaderLayoutAndViewportCalculations() {
        XCTAssertEqual(NookClip.searchTopInset, 0)
        XCTAssertEqual(NookClip.heightSearch, 42)
        XCTAssertEqual(NookClip.searchBottomGap, 0)
        // 分类/标签已收进搜索框展开面板，不再常驻分类条；搜索框下方 6pt 间距已撤销
        // 从 0 开始精确推导：0 + 42 + 0 = 42
        XCTAssertEqual(NookClip.listViewportTopY, 42, "列表视口顶 Y 应紧贴搜索框下沿（间距为 0）")
        // 吸顶组头（24pt）不算作列表内容区域，列表内容有效可视区顶 Y = 42 + 24 = 66
        XCTAssertEqual(NookClip.listContentTopY, 66, "列表内容有效可视区顶 Y 应扣除 24pt 吸顶时间分组头")
    }
    @MainActor
    func testTenRowsHeightCalculation() {
        let headerHeight = NookClip.listViewportTopY // 42
        let topScrollAnchor = CGFloat(1)
        let groupHeader = NookClip.heightGroupHeader // 24
        let tenRows = CGFloat(10) * NookClip.heightRowList // 10 * 54 = 540
        let footerHeight = NookClip.heightFooter // 22
        let expectedTotal = headerHeight + topScrollAnchor + groupHeader + tenRows + footerHeight // 629
        XCTAssertEqual(PanelGeometry.minHeight, expectedTotal, "默认窗口最小高度应正好完整展示1组头+10行数据")
    }

    @MainActor
    func testMainViewHosting() {
        let store = makeIsolatedStore()
        let view = MainView(
            store: store,
            clipboardWriter: PasteService.shared
        )
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(host.window)
    }

    @MainActor
    func testKeyboardNavigationScrollsRowsFullyClearOfStickyHeaderAndFooter() {
        let store = makeIsolatedStore()
        let now = Date()
        var orderedIDs: [UUID] = []
        for i in 0..<8 {
            let id = UUID()
            orderedIDs.append(id)
            store.save(ClipboardItem(
                id: id,
                type: .text,
                title: "今天条目 \(i)",
                summary: "Today item \(i)",
                createdAt: now.addingTimeInterval(Double(-i * 60)),
                lastUsedAt: now.addingTimeInterval(Double(-i * 60))
            ))
        }
        for i in 0..<8 {
            let id = UUID()
            orderedIDs.append(id)
            store.save(ClipboardItem(
                id: id,
                type: .text,
                title: "昨天条目 \(i)",
                summary: "Yesterday item \(i)",
                createdAt: now.addingTimeInterval(Double(-86400 - i * 60)),
                lastUsedAt: now.addingTimeInterval(Double(-86400 - i * 60))
            ))
        }

        var capturedActions: PanelKeyActions?
        var latestRowFrames: [String: CGRect] = [:]
        let view = MainView(
            store: store,
            clipboardWriter: PasteService.shared,
            installKeyActions: { actions in
                capturedActions = actions
            }
        )
        .onPreferenceChange(RowFramesPreferenceKey.self) { frames in
            latestRowFrames = frames
        }

        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: PanelGeometry.minHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        XCTAssertNotNil(capturedActions, "键盘动作表应已注入")
        let safeTop = NookClip.listContentTopY // 102pt（扣除 78pt 顶栏 + 24pt 吸顶组头）
        let bannerInset = PasteService.isAccessibilityTrusted ? CGFloat(0) : NookClip.heightListBottomBanner
        let safeBottom = PanelGeometry.minHeight - NookClip.heightFooter - bannerInset

        for step in 1..<15 {
            capturedActions?.arrow(1, false)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
            let targetID = orderedIDs[step]
            if let frame = latestRowFrames[targetID.uuidString] {
                XCTAssertGreaterThanOrEqual(frame.minY, safeTop - 1.5, "第 \(step + 1) 行上沿不得被吸顶组头遮挡")
                XCTAssertLessThanOrEqual(frame.maxY, safeBottom + 1.5, "第 \(step + 1) 行下沿不得被底部提示栏遮挡")
            }
        }
        for step in (0..<14).reversed() {
            capturedActions?.arrow(-1, false)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
            if step > 1, let frame = latestRowFrames[orderedIDs[step].uuidString] {
                XCTAssertGreaterThanOrEqual(frame.minY, safeTop - 1.5, "向上切换到第 \(step + 1) 行时上沿不得被吸顶组头遮挡")
                XCTAssertLessThanOrEqual(frame.maxY, safeBottom + 1.5, "向上切换到第 \(step + 1) 行时下沿不得被底栏遮挡")
            }
        }
        // 等待 scrollToWithRetry 的 150ms 兜底滚动完成
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()
        // 回到首行时，首行 minY 必须 ≥ safeTop (102pt)，绝不被吸顶组头遮挡
        if let topRowMinY = latestRowFrames.values.map(\.minY).min() {
            XCTAssertGreaterThanOrEqual(topRowMinY, safeTop - 1.5, "回到首行时首行上沿须位于吸顶组头（102pt）正下方")
        }
    }

    @MainActor
    func testVisualRenderSnapshotsLightAndDark() throws {
        let store = makeIsolatedStore()
        let now = Date()
        store.save(ClipboardItem(
            type: .text,
            title: "季度产品路线图摘要",
            summary: "NookClip v2.0 聚焦 macOS 原生体验、极速键盘主循环与本地加密安全保护，确保在多显示器与深浅外观下始终清晰克制。",
            createdAt: now.addingTimeInterval(-3600),
            lastUsedAt: now.addingTimeInterval(-120),
            copyCount: 3,
            isFavorite: true,
            sourceAppBundleId: "com.apple.Notes",
            sourceAppName: "备忘录"
        ))
        store.save(ClipboardItem(
            type: .url,
            title: "",
            summary: "https://developer.apple.com/design/human-interface-guidelines/macos",
            createdAt: now.addingTimeInterval(-1800),
            lastUsedAt: now.addingTimeInterval(-90),
            copyCount: 1,
            isFavorite: false,
            sourceAppBundleId: "com.apple.Safari",
            sourceAppName: "Safari"
        ))
        store.save(ClipboardItem(
            type: .text,
            title: "",
            summary: "#007AFF",
            createdAt: now.addingTimeInterval(-1200),
            lastUsedAt: now.addingTimeInterval(-60),
            copyCount: 2,
            isFavorite: false,
            sourceAppBundleId: "com.figma.Desktop",
            sourceAppName: "Figma"
        ))

        let view = MainView(
            store: store,
            clipboardWriter: PasteService.shared
        )
        let host = NSHostingView(rootView: view)
        let rect = NSRect(x: 0, y: 0, width: 750, height: 625)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host

        for appName in [NSAppearance.Name.aqua, NSAppearance.Name.darkAqua] {
            window.appearance = NSAppearance(named: appName)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
            XCTAssertNotNil(rep)
        }
    }
}
