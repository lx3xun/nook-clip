import XCTest
import SwiftUI
@testable import NookClip

/// 仅用于设计评审的视觉快照：把标签相关 UI 渲染成 PNG 到 /tmp/nook-snaps/。
/// 不是行为断言测试（始终通过），便于人工查看改造后的视觉。
@MainActor
final class TagVisualSnapshotTests: XCTestCase {

    private let outDir = URL(fileURLWithPath: "/tmp/nook-snaps")

    private func render<V: View>(_ view: V, name: String, size: CGSize, scheme: ColorScheme) {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content:
            view
                .frame(width: size.width, height: size.height)
                .background(scheme == .dark ? Color(hex: 0x1E1E22) : Color(hex: 0xF7F7F9))
                .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("render failed \(name)")
            return
        }
        let suffix = scheme == .dark ? "dark" : "light"
        let url = outDir.appendingPathComponent("\(name)_\(suffix).png")
        try? png.write(to: url)
    }

    func testRenderTagVisuals() {
        for scheme in [ColorScheme.light, .dark] {
            render(previewRowDemo(), name: "preview_toolbar", size: CGSize(width: 460, height: 130), scheme: scheme)
            render(rowInlineDemo(), name: "list_row_tags", size: CGSize(width: 330, height: 130), scheme: scheme)
            render(searchSuggestionDemo(), name: "search_suggestion", size: CGSize(width: 340, height: 90), scheme: scheme)
            render(editorDemo(), name: "tag_editor", size: CGSize(width: 420, height: 150), scheme: scheme)
        }
    }

    private func makeRow(_ tags: [String], copyCount: Int = 1) -> ClipboardRowModel {
        var item = ClipboardItem(
            type: .text,
            title: "GET /v1/orders",
            summary: "GET /v1/orders?status=open",
            createdAt: Date(timeIntervalSince1970: 1000),
            lastUsedAt: Date(timeIntervalSince1970: 1000)
        )
        item.copyCount = copyCount
        item.tags = tags
        return ClipboardRowModel(item: item)
    }

    // 预览区顶部工具栏（标签并入、无字符数/类型元信息）
    @ViewBuilder private func previewRowDemo() -> some View {
        VStack(spacing: 0) {
            PreviewToolbar(
                isFavorite: false,
                item: makeRow(["api", "deploy", "swift", "customer-reply"], copyCount: 12),
                contentText: "GET /v1/orders?status=open",
                onEditTags: {},
                tags: ["api", "deploy", "swift", "customer-reply"],
                onSelectTag: { _ in }, onRemoveTag: { _ in },
                onRenameTag: { _ in }, onDeleteTag: { _ in },
                onScrubPaste: {},
                onPinToScreen: {},
                canScrubPaste: true
            )
            Divider().opacity(0.3)
            PreviewToolbar(
                isFavorite: true,
                item: makeRow([], copyCount: 3),
                contentText: "body",
                onEditTags: {},
                tags: [],
                onPinToScreen: {}
            )
            Divider().opacity(0.3)
            PreviewToolbar(
                isFavorite: false,
                item: makeRow([], copyCount: 1),
                contentText: "body",
                onEditTags: {},
                tags: [],
                onPinToScreen: {}
            )
        }
        .background(NookClip.bgPreview)
    }

    // 列表行：静止 vs 悬停（副行标签只在悬停/选中露）
    @ViewBuilder private func rowInlineDemo() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sampleRow(tags: ["api", "deploy", "swift"], active: false, selected: false)
            Divider()
            sampleRow(tags: ["api", "deploy", "swift"], active: true, selected: false)
            Divider()
            sampleRow(tags: ["api"], active: false, selected: true)
        }
        .background(NookClip.bgContent)
    }

    @ViewBuilder private func sampleRow(tags: [String], active: Bool, selected: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6).fill(NookClip.bgRowOn)
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(NookClip.textSecondary))
            VStack(alignment: .leading, spacing: 3) {
                Text("@GET /v1/orders?status=open")
                    .font(.nookClipMono(12)).foregroundStyle(NookClip.textPrimary).lineLimit(1)
                HStack(spacing: 4) {
                    Text("Xcode · 端点定义")
                        .font(.nookClipMeta).foregroundStyle(NookClip.textTertiary).lineLimit(1)
                    if active || selected {
                        RowTagsInlineView(tags: tags, maxVisible: 2, isActive: true)
                    }
                }
            }
            Spacer(minLength: 4)
            Text("昨天").font(.nookClipMeta).foregroundStyle(NookClip.textTertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: NookClip.heightRowList)
        .background(selected ? NookClip.bgRowSelectedSubtle : Color.clear)
    }

    // 搜索框 `#` 候选下拉：复刻真实层级（左列 VStack 的 overlay 盖在分类栏之上）
    @ViewBuilder private func searchSuggestionDemo() -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(NookClip.textTertiary)
                Text("#de").font(.nookClipBody).foregroundStyle(NookClip.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: NookClip.heightSearch)
            .background(RoundedRectangle(cornerRadius: NookClip.radiusControl).fill(NookClip.bgRowOn))
            .padding(.bottom, NookClip.searchBottomGap)
            HStack(spacing: 5) {
                Text("全部").font(.nookClipMeta).foregroundStyle(NookClip.accent)
                Text("收藏").font(.nookClipMeta).foregroundStyle(NookClip.textSecondary)
                Text("代码").font(.nookClipMeta).foregroundStyle(NookClip.textSecondary)
                Text("链接").font(.nookClipMeta).foregroundStyle(NookClip.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 24)
            Spacer()
        }
        .frame(width: NookClip.widthListCol, alignment: .top)
        .background(NookClip.bgContent)
        // 真实层级：整列 overlay，应盖住分类栏
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                TagChipView(tag: "deploy", size: .compact, onTap: {})
                TagChipView(tag: "design", size: .compact, onTap: {})
                TagChipView(tag: "debug", size: .compact, onTap: {})
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .fill(NookClip.bgPopover)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .strokeBorder(NookClip.separator, lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
            .offset(x: 12, y: NookClip.heightSearch + NookClip.searchBottomGap - 2)
        }
    }

    // 编辑器候选行示意（复刻 TagEditorPopover.candidateRow，验证不再重复 #）
    // 注：不直接渲染 TagEditorPopover，因为其输入框是 NSTextField，ImageRenderer 离屏渲染不支持。
    @ViewBuilder private func editorDemo() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 候选：未选中（number 图标 = #）
            HStack(spacing: 6) {
                Image(systemName: "number").font(.system(size: 9, weight: .bold)).foregroundStyle(NookClip.textTertiary).frame(width: 12)
                Text("test").font(.nookClipMeta).foregroundStyle(NookClip.textPrimary)
                Spacer()
                Text("1").font(.nookClipBadge).monospacedDigit().foregroundStyle(NookClip.textTertiary)
            }.padding(.horizontal, 10).frame(height: 26)
            // 候选：已选中（checkmark）
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(NookClip.accent).frame(width: 12)
                Text("api").font(.nookClipMeta).foregroundStyle(NookClip.accent)
                Spacer()
                Text("3").font(.nookClipBadge).monospacedDigit().foregroundStyle(NookClip.accent.opacity(0.85))
            }.padding(.horizontal, 10).frame(height: 26)
            // 候选：半选（minus）
            HStack(spacing: 6) {
                Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(NookClip.textTertiary).frame(width: 12)
                Text("deploy").font(.nookClipMeta).foregroundStyle(NookClip.textPrimary)
                Spacer()
                Text("2").font(.nookClipBadge).monospacedDigit().foregroundStyle(NookClip.textTertiary)
            }.padding(.horizontal, 10).frame(height: 26)
            // 创建新标签行
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(NookClip.accent)
                Text("创建「#newtag」").font(.nookClipMeta).foregroundStyle(NookClip.accent)
                Spacer()
            }.padding(.horizontal, 10).frame(height: 26)
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookClip.bgPopover))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NookClip.separator, lineWidth: 0.5))
        .padding(12)
    }

    func testRenderChipStrip() {
        for scheme in [ColorScheme.light, .dark] {
            render(VStack(spacing:8){
                HStack(spacing:4){
                    TagChipView(tag:"api", size:.compact, onRemove:{}, onTap:{})
                    TagChipView(tag:"deploy", size:.compact, onRemove:{}, onTap:{})
                    TagChipView(tag:"customer-reply", size:.compact, onRemove:{}, onTap:{})
                }
                HStack(spacing:4){
                    TagChipView(tag:"api", size:.regular)
                    TagChipView(tag:"swift", size:.regular, isSelected:true, onRemove:{}, onTap:{})
                }
            }.padding(14), name:"chip_strip", size: CGSize(width: 380, height: 96), scheme: scheme)
        }
    }
}

/// 标签候选下拉的命中区几何测试：确保点击下拉不会被面板当成「搜索框外点击」而取消焦点。
@MainActor
final class TagDropdownHitZoneTests: XCTestCase {
    private func makePanel() -> DraggablePanel {
        DraggablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    func testTagDropdownBandIsInteractive() {
        let panel = makePanel()
        let h = panel.frame.height
        // 下拉带垂直范围：[h - hotZoneTagDropdownHeight, h - hotZoneSearchBarTopInset]
        let midY = h - (NookClip.hotZoneSearchBarTopInset + NookClip.hotZoneTagDropdownHeight) / 2
        let p = NSPoint(x: 100, y: midY)
        XCTAssertTrue(panel.isTagDropdownArea(at: p), "下拉带中部应命中 isTagDropdownArea")
        XCTAssertTrue(panel.isInteractiveArea(at: p), "下拉带中部必须按交互区正常分发（否则点击落空）")
        XCTAssertFalse(panel.isSearchBarArea(at: p), "下拉带不属于搜索框带（二者不重叠）")
    }

    func testSearchBarAndDropdownCoverage() {
        let panel = makePanel()
        let h = panel.frame.height
        // 搜索框带中部
        let searchMid = h - NookClip.hotZoneSearchBarTopInset / 2
        XCTAssertTrue(panel.isSearchBarArea(at: NSPoint(x: 100, y: searchMid)))
        // 下拉带最底部附近也应命中
        let nearBottom = h - NookClip.hotZoneTagDropdownHeight + 1
        XCTAssertTrue(panel.isTagDropdownArea(at: NSPoint(x: 100, y: nearBottom)))
    }
}
