import SwiftUI

// MARK: - 时间线组头（11px tertiary · 高 24px · 吸顶不透底）
private final class GroupMenuTarget: NSObject {
    static let shared = GroupMenuTarget()
    var callback: ((String) -> Void)?

    @objc func selectGroup(_ sender: NSMenuItem) {
        if let groupID = sender.representedObject as? String {
            let cb = callback
            callback = nil
            cb?(groupID)
        }
    }
}

/// 日历翻页 3D 动效修饰器（围绕顶缘或底缘做 X 轴立体翻折 + 位移与透明度过渡）
private struct CalendarPageFlipModifier: ViewModifier {
    let angle: Double
    let offsetY: CGFloat
    let opacity: Double
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 1, y: 0, z: 0),
                anchor: anchor,
                perspective: 0.55
            )
            .offset(y: offsetY)
            .opacity(opacity)
    }
}

/// 时间分组跳转条目（吸顶组头下拉菜单的数据源）
struct TimelineRailItem: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int?
}

struct GroupHeaderView: View {
    var groupID: String = ""
    let title: String
    let count: Int
    var allGroups: [TimelineRailItem]? = nil
    var onSelectGroup: ((String) -> Void)? = nil
    @State private var isHovered = false

    private var pageIdentity: String {
        groupID.isEmpty ? title : groupID
    }

    private var calendarFlipTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: CalendarPageFlipModifier(angle: -78, offsetY: 9, opacity: 0, anchor: .bottom),
                identity: CalendarPageFlipModifier(angle: 0, offsetY: 0, opacity: 1, anchor: .bottom)
            ),
            removal: .modifier(
                active: CalendarPageFlipModifier(angle: 78, offsetY: -9, opacity: 0, anchor: .top),
                identity: CalendarPageFlipModifier(angle: 0, offsetY: 0, opacity: 1, anchor: .top)
            )
        )
    }

    /// 是否提供分组跳转入口（分组多于一个时由 MainView 注入）
    private var hasJumpMenu: Bool {
        guard let allGroups, let onSelectGroup else { return false }
        return !allGroups.isEmpty
    }

    var body: some View {
        HStack(spacing: 4) {
            if hasJumpMenu, let allGroups, let onSelectGroup {
                // 标题即入口：点击「今天 · 29」整块弹出分组菜单。
                // 常态无任何图标，悬停时文字提亮并淡入小 ⌄ —— 可发现性来自悬停，观感不来自装饰。
                Button {
                    showGroupMenu(allGroups: allGroups, onSelectGroup: onSelectGroup)
                } label: {
                    HStack(spacing: 3) {
                        titleCluster
                        Image(systemName: NookClipIcon.Nav.chevronUpDown)
                            .font(.system(size: NookClipIconSize.microSmall, weight: .semibold))
                            .foregroundStyle(NookClip.textSecondary)
                            .opacity(isHovered ? 1 : 0)
                            .animation(.easeOut(duration: 0.12), value: isHovered)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background {
                        if isHovered {
                            RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous)
                                .fill(NookClip.bgRowOn)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { isHovered = $0 }
                .help(L10n.tr("hints.time_jump"))
                // 负边距抵消内边距，标题文字仍与列表行左缘（12pt）对齐
                .padding(.leading, -5)
            } else {
                titleCluster
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: NookClip.heightGroupHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(.spring(response: 0.30, dampingFraction: 0.78), value: pageIdentity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NookClip.separator.opacity(0.6))
                .frame(height: 0.5)
        }
    }

    /// 「组名 · 计数」排印组：悬停时整体提到主文字色，表达可交互
    private var titleCluster: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.nookClipMetaMedium)
                .foregroundStyle(isHovered && hasJumpMenu ? NookClip.textPrimary : NookClip.textSecondary)
            Text("·")
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textTertiary)
            Text("\(count)")
                .font(.nookClipMeta)
                .monospacedDigit()
                .foregroundStyle(NookClip.textTertiary)
                .contentTransition(.numericText())
        }
        .id(pageIdentity)
        .transition(calendarFlipTransition)
    }

    private func showGroupMenu(allGroups: [TimelineRailItem], onSelectGroup: @escaping (String) -> Void) {
        let menu = NSMenu()
        for group in allGroups {
            let label = group.count.map { "\(group.title) (\($0))" } ?? group.title
            let item = NSMenuItem(title: label, action: #selector(GroupMenuTarget.selectGroup(_:)), keyEquivalent: "")
            item.target = GroupMenuTarget.shared
            item.representedObject = group.id
            menu.addItem(item)
        }
        GroupMenuTarget.shared.callback = onSelectGroup
        // popUp 为同步调用，返回即菜单已关闭
        if let event = NSApp.currentEvent, let window = NSApp.keyWindow ?? NSApp.mainWindow, let contentView = window.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: contentView)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: window.contentView)
        }
        // NSMenu 弹出会接管键盘；LSUIElement 应用里菜单关闭后面板还可能
        // 拿不回 key window 状态（键盘事件全部派发给 key window，面板收不到
        // 任何按键——↓×N 后切时间下拉、随后 ↑/↓/⏎ 全无响应的用户反馈即此因）。
        // 异步一拍等菜单 teardown 完成后，经面板统一入口夺回 key 状态
        DispatchQueue.main.async {
            (NSApp.windows.first { $0 is DraggablePanel } as? DraggablePanel)?
                .restoreKeyboardFocus()
        }
    }
}

/// 组头 frame 持续上报（列表列坐标系；key = 组 id）。注意 pinned 组头静止时上报的是
/// 「未吸顶的虚拟位置」（滚动惯性中才是渲染位置），吸顶判定须按「已过视口顶的
/// 最后一组」而非「贴顶」——见 MainView.handleHeaderFrames
struct HeaderFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 列表数据行 frame 持续上报（列表列坐标系；key = 行 id 字符串），用于精确判定选中行是否被吸顶组头或底栏遮挡
struct RowFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - 底部操作指引栏（28px · kbd 组）

struct HintsFooterView: View {
    struct Hint {
        let kbds: [String]
        let label: String
    }

    let hints: [Hint]
    /// "?" 帮助弹卡的其余快捷键（空 = 不显示 ? 按钮）：底栏放不下的
    /// 快捷键在此渐进披露，点击 ? 展开、点击外部收起
    var moreHints: [Hint] = []
    @State private var helpOpen = false
    var body: some View {
        ZStack {
            // 常驻核心提示（选择 / 粘贴 / 分类）去框化纯排印展示
            HStack(spacing: 12) {
                ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                    HStack(spacing: 4) {
                        Text(hint.kbds.joined(separator: " "))
                            .font(.nookClipMono(10, .medium))
                            .foregroundStyle(NookClip.textSecondary)
                        Text(hint.label)
                            .font(.nookClipMeta)
                            .foregroundStyle(NookClip.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            }
            .padding(.horizontal, moreHints.isEmpty ? 0 : 20)
            .frame(maxWidth: .infinity, alignment: .center)

            // 右侧帮助按钮
            if !moreHints.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    helpButton
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: NookClip.heightFooter)
        .background(NookClip.bgFooter)
        // 其余快捷键弹卡：脚栏上方右对齐，点击外部收起
        .overlay(alignment: .bottomTrailing) {
            if helpOpen {
                ZStack(alignment: .bottomTrailing) {
                    OutsideTapCatcher { helpOpen = false }
                    helpCard
                }
            }
        }
    }

    private var helpButton: some View {
        Button {
            helpOpen.toggle()
        } label: {
            Image(systemName: NookClipIcon.Nav.help)
                .font(.system(size: NookClipIconSize.compactMedium, weight: .regular))
                .foregroundStyle(helpOpen ? NookClip.textPrimary : NookClip.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("hints.more"))
    }
    /// 弹卡行布局与底栏一致（kbd 键帽 + 说明），卡片复用下拉菜单的 popover 规格
    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(moreHints.enumerated()), id: \.offset) { _, hint in
                HStack(spacing: 3) {
                    ForEach(Array(hint.kbds.enumerated()), id: \.offset) { _, kbd in
                        KbdView(text: kbd)
                    }
                    Text(hint.label)
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(width: 208, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .fill(NookClip.bgPopover)
        }
        .overlay {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .strokeBorder(NookClip.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        .offset(y: -(NookClip.heightFooter + 6))
    }
}
