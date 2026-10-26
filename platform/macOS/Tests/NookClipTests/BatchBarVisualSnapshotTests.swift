import XCTest
import SwiftUI
@testable import NookClip

/// 仅用于设计评审的视觉快照：把多选工具栏的中英文/明暗状态渲染成 PNG 到 /tmp/nook-snaps/。
/// 不是行为断言测试（始终通过），便于人工确认四个动作名称全部可读、宽度不溢出。
///
/// 现在的设计是「常量布局」：四个动作常驻文字、宽度固定，悬停只加深底色。
/// 所以快照只需覆盖不同语言（中/繁/英，英文最宽）与明暗两套配色。
@MainActor
final class BatchBarVisualSnapshotTests: XCTestCase {

    private let outDir = URL(fileURLWithPath: "/tmp/nook-snaps")

    private func render<V: View>(_ view: V, name: String, scheme: ColorScheme) {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content:
            view
                .frame(width: NookClip.widthListCol, height: 54)
                .background(NookClip.bgFooter)
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
        try? png.write(to: outDir.appendingPathComponent("\(name)_\(suffix).png"))
    }

    func testRenderBatchBarStates() {
        for scheme in [ColorScheme.light, .dark] {
            // 真实组件，当前语言
            render(
                BatchBar(selectedCount: 2, onMergePaste: {}, onStartPasteStack: {}, onDelete: {}, onEditTags: {}),
                name: "batch_bar_default",
                scheme: scheme
            )
            // 英文最宽：验证「Merge & Paste / Paste Stack / Tags / Delete」同时出现也不溢出
            render(
                rowDemo(texts: [
                    .selectedCount: "2 selected",
                    .extend: "⇧↑ / ⇧↓ Extend selection",
                    .exit: "Esc Exit",
                    .primary: "Merge & Paste",
                    .pasteStack: "Paste Stack",
                    .tag: "Tags",
                    .delete: "Delete"
                ]),
                name: "batch_bar_default_en",
                scheme: scheme
            )
            // 繁体
            render(
                rowDemo(texts: [
                    .selectedCount: "已選取 2 項",
                    .extend: "⇧↑ / ⇧↓ 擴充選取",
                    .exit: "Esc 退出",
                    .primary: "合併貼上",
                    .pasteStack: "順序貼上",
                    .tag: "標籤",
                    .delete: "刪除"
                ]),
                name: "batch_bar_default_zh_hant",
                scheme: scheme
            )
            // 悬停态（左起第二个 = 顺序粘贴浮出底色），验证悬停只变底色、位置不动
            render(
                rowDemo(hoveredSecondary: 1),
                name: "batch_bar_hover_paste_stack",
                scheme: scheme
            )
        }
    }

    private enum TextKey: Hashable {
        case selectedCount, extend, exit, primary, pasteStack, tag, delete
    }

    /// 手搭一行复刻 BatchBar 的常量布局；`hoveredSecondary` 指定哪个次要按钮处于悬停态
    private func rowDemo(
        hoveredSecondary: Int? = nil,
        texts: [TextKey: String] = [:]
    ) -> some View {
        func text(_ key: TextKey, _ fallback: String) -> String { texts[key] ?? fallback }

        return VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(text(.selectedCount, L10n.tr("batch.selected_count", "2")))
                    .font(.nookClipSubheadMedium)
                    .foregroundStyle(NookClip.textPrimary)
                Text(text(.extend, L10n.tr("batch.extend_selection")))
                    .font(.nookClipCaption)
                    .foregroundStyle(NookClip.textTertiary)
                Text(text(.exit, L10n.tr("batch.exit_selection")))
                    .font(.nookClipCaption)
                    .foregroundStyle(NookClip.textTertiary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 4) {
                // 主按钮：吃满剩余宽度，宽度由列宽决定
                HStack(spacing: 5) {
                    Image(systemName: NookClipIcon.Action.merge)
                        .font(.system(size: NookClipIconSize.compactMedium, weight: .medium))
                    Text(text(.primary, L10n.tr("batch.merge_paste")))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    KbdView(text: "⏎", fontSize: 9)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(.nookClipSubheadMedium)
                .foregroundStyle(NookClip.accent)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .fill(NookClip.bgChipSelected)
                        .overlay {
                            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                                .strokeBorder(NookClip.borderRowSelectedSubtle, lineWidth: 0.5)
                        }
                }

                secondaryDemo(text(.pasteStack, L10n.tr("batch.paste_stack")), .primary, hovered: hoveredSecondary == 1)
                secondaryDemo(text(.tag, L10n.tr("tag.action")), .primary, hovered: hoveredSecondary == 2)
                secondaryDemo(text(.delete, L10n.tr("batch.delete")), .danger, hovered: hoveredSecondary == 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 54)
    }

    /// 次要按钮：常驻文字，悬停只加深底色（不改变宽度）
    private func secondaryDemo(
        _ title: String,
        _ role: BatchBar.ButtonRole,
        hovered: Bool
    ) -> some View {
        Text(title)
            .font(.nookClipMeta)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(role == .primary ? NookClip.accent : NookClip.colorDanger)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .fill(
                        hovered
                            ? (role == .primary ? NookClip.bgRowSelected : NookClip.bgDangerHover)
                            : Color.clear
                    )
            }
    }
}
