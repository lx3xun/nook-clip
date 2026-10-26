import AppKit
import SwiftUI

// MARK: - 设置页组件（方案 C：侧栏 + 现状带 + 可折叠分组）
//
// 这一套组件只服务设置页，与主面板的毛玻璃/aurora 体系相互独立：
//   · 分面靠 1px 描边，不靠阴影（阴影只留给真正浮起来的东西：菜单、popover）
//   · 颜色不进 chrome，唯一的有色只落在数据（存储条、统计数字）与状态胶囊上
//   · 圆角只有一种：面板 8、控件 6

enum SettingsMetrics {
    /// 左栏宽度（与方案 C 的 208pt 一致）
    static let railWidth: CGFloat = 208
    /// 画布左右内边距
    static let canvasPadding: CGFloat = 26
    /// 面板圆角
    static let panelRadius: CGFloat = 8
    /// 折叠标题行的高度（收起后一组就占这么高）
    static let foldRowHeight: CGFloat = 46
    /// 面板内一行的最小高度
    static let rowMinHeight: CGFloat = 38
}

// MARK: - 页面骨架：页头 + 现状带 + 折叠分组区

/// 设置页每一页的统一骨架。
///
/// 页头写「这一页管什么」，现状带用三格回答「现在是什么状态」，
/// 下面才是可折叠的分组。折叠的意义很实际：历史与同步一页有 4 组、
/// 展开合计 1125pt，而窗口只有 720pt —— 不折叠就一定看不全。
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let status: [(label: String, value: String)]
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.nookClip(24, .medium))
                    .tracking(-0.2)
                    .foregroundStyle(NookClip.textPrimary)
                Text(subtitle)
                    .font(.nookClipBody)
                    .foregroundStyle(NookClip.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsMetrics.canvasPadding)
            .padding(.top, 26)
            .padding(.bottom, 20)

            if !status.isEmpty {
                SettingsStatusStrip(cells: status)
                    .padding(.horizontal, SettingsMetrics.canvasPadding)
                    .padding(.bottom, 22)
            }

            // GeometryReader 给出折叠区真正能用多高，折叠判断依据它而不是行数猜测
            GeometryReader { proxy in
                SettingsFoldArea(availableHeight: proxy.size.height) {
                    content()
                }
            }
            .padding(.horizontal, SettingsMetrics.canvasPadding)
            .padding(.bottom, SettingsMetrics.canvasPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 现状带

/// 三格现状带：等分、格间竖线、上下各一条规则线。
/// 数字与版本号用等宽 + tabular，保证换值时不跳动。
struct SettingsStatusStrip: View {
    let cells: [(label: String, value: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                VStack(alignment: .leading, spacing: 4) {
                    Text(cell.label)
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textSecondary)
                    Text(cell.value)
                        .font(.nookClipMono(15, .regular))
                        .monospacedDigit()
                        .foregroundStyle(NookClip.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, index == 0 ? 0 : 14)

                if index < cells.count - 1 {
                    // 竖线必须给定高度：Rectangle 没有固有高度，一旦让它自适应就会
                    // 把整条现状带撑到占满画布剩余空间
                    Rectangle()
                        .fill(NookClip.ruleSubtle)
                        .frame(width: 1, height: 34)
                }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(NookClip.ruleSubtle).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(NookClip.ruleSubtle).frame(height: 1)
        }
    }
}

// MARK: - 折叠区

/// 折叠区：每组**各自独立**开合，互不牵连。
///
/// 上一版用一个 `openCount` 数字表示「前几组是开的」，代价是点任意一组都会
/// 连坐其它组：想关掉第 1 组，结果把后面的全关了；想开第 4 组，前面的又
/// 全被撑开。用户看到的现象就是「展开和收起不听话」。现在改成一个集合，
/// 点哪组只动哪组。
///
/// 默认策略按**真实高度贪心**给出：初次渲染时所有组先全部展开，于是每一组
/// 的内容高度都能量到；然后从第一组往后累加，装不下就把剩下的组收起。
/// 这样打开设置页时不需要滚动就看得到尽可能多的状态。
///
/// 为什么用「收起的集合」而不是「展开的集合」当默认值：内容高度只有展开时
/// 才测得到。若默认只有第一组展开，后面各组的高度永远是空的，贪心逻辑根本
/// 看不见它们 —— 表现就是第一组开着、下面全收起、页面下半屏空着。默认全开
/// 让第一帧把所有高度量完，再按测量结果收起尾部。
/// 用户一旦自己点过，就完全交给他，不再自动改写。
struct SettingsFoldArea<Content: View>: View {
    let availableHeight: CGFloat
    @ViewBuilder let content: () -> Content

    /// 每组的展开内容高度（默认全开时一帧内即可量到全部）
    @State private var heights: [Int: CGFloat] = [:]
    /// 被收起的组。默认空集合 = 全部展开，用途见上面的类型注释。
    @State private var closedIndices: Set<Int> = []
    /// 自动收起算过一次就不再重算，避免测量抖动导致组在眼前反复开合
    @State private var hasAutoExpanded = false
    /// 用户手动点过之后，自动策略永久退场
    @State private var userAdjusted = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                content()
            }
            .onPreferenceChange(SettingsFoldHeightKey.self) { measured in
                var changed = false
                for (index, height) in measured where heights[index] != height {
                    heights[index] = height
                    changed = true
                }
                if changed, !userAdjusted {
                    autoExpandIfNeeded()
                }
            }
        }
        // 滚动始终可用：展开一个大分组后，后面的分组会被挤到可视区之外，
        // 这时必须能滚下去 —— 之前按「是否手动调过」禁用滚动，用户展开
        // 「个人信息」这种 10 行的组之后，下面几组就再也够不着了
        .scrollDisabled(false)
        .environment(\.settingsFoldContext, SettingsFoldContext(
            isOpen: { index in !closedIndices.contains(index) },
            toggle: { index in toggle(index) },
            report: { index, height in heights[index] = height }
        ))
    }

    private func autoExpandIfNeeded() {
        guard !hasAutoExpanded, !heights.isEmpty else { return }
        hasAutoExpanded = true

        let indices = heights.keys.sorted()
        // 先扣掉所有组的标题行：收起的组也一直占着这一行，不扣会把最后几组
        // 挤到可视区之外，出现「底下露半行」的裁切
        var used = SettingsMetrics.foldRowHeight * CGFloat(indices.count)
        var open: Set<Int> = []
        for index in indices {
            guard let contentHeight = heights[index] else { continue }
            if used + contentHeight > availableHeight + 0.5 { break }
            used += contentHeight
            open.insert(index)
        }
        // 一组都装不下时至少开第一组，否则整页看起来只有几个光秃秃的标题
        if open.isEmpty, let first = indices.first {
            open.insert(first)
        }
        closedIndices = Set(indices).subtracting(open)
    }

    private func toggle(_ index: Int) {
        userAdjusted = true
        if closedIndices.contains(index) {
            closedIndices.remove(index)
        } else {
            closedIndices.insert(index)
        }
    }
}

/// 折叠区通过 environment 把「第几组是否展开 / 怎么切换」传给每个分组，
/// 这样各 Tab 里写分组时不用关心折叠状态的存放位置。
struct SettingsFoldContext {
    let isOpen: (Int) -> Bool
    let toggle: (Int) -> Void
    let report: (Int, CGFloat) -> Void

    static let passthrough = SettingsFoldContext(
        isOpen: { _ in true },
        toggle: { _ in },
        report: { _, _ in }
    )
}

private struct SettingsFoldContextKey: EnvironmentKey {
    static let defaultValue = SettingsFoldContext.passthrough
}

extension EnvironmentValues {
    var settingsFoldContext: SettingsFoldContext {
        get { self[SettingsFoldContextKey.self] }
        set { self[SettingsFoldContextKey.self] = newValue }
    }
}

/// 每组展开后的内容高度，交给折叠区做贪心判断
struct SettingsFoldHeightKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - 可折叠分组

/// 一个可折叠分组：标题行（左标题、右摘要、箭头）+ 展开后的白面板。
///
/// 摘要这一句是折叠方案能成立的关键 —— 收起之后仍然看得出这组里是什么状态，
/// 否则用户得逐组点开才知道自己要不要进去。
struct SettingsFoldGroup<Content: View>: View {
    let index: Int
    let title: String
    let summary: String
    @ViewBuilder let content: () -> Content

    @Environment(\.settingsFoldContext) private var fold

    private var isOpen: Bool { fold.isOpen(index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(NookClip.animHover) {
                    fold.toggle(index)
                }
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.nookClipBodyMedium)
                        .foregroundStyle(NookClip.textPrimary)
                    Spacer(minLength: 8)
                    Text(summary)
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textSecondary)
                        .lineLimit(1)
                    Image(systemName: NookClipIcon.Settings.disclosure)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NookClip.textSecondary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)，\(summary)")
            .accessibilityValue(isOpen ? L10n.tr("settings.fold.expanded") : L10n.tr("settings.fold.collapsed"))

            if isOpen {
                SettingsPanel {
                    content()
                }
                .padding(.bottom, 16)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SettingsFoldHeightKey.self,
                            value: [index: proxy.size.height]
                        )
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if index > 0 {
                Rectangle().fill(NookClip.ruleSubtle).frame(height: 1)
            }
        }
    }
}

// MARK: - 面板与行

/// 白面板：1px 描边分面、无阴影、圆角 8
struct SettingsPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous)
                .fill(NookClip.bgSurface)
        }
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous)
                .strokeBorder(NookClip.borderPanel, lineWidth: 1)
        }
    }
}

/// 行左侧标准文案：13pt medium 标题 + 可选 12pt 次要色说明
struct SettingsRowTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.nookClipBodyMedium)
                .foregroundStyle(NookClip.textPrimary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.nookClipSubhead)
                    .foregroundStyle(NookClip.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 面板里的一行：左文案、右控件，行间 1px 规则线（左侧内缩对齐文字）
struct SettingsRow<Leading: View, Trailing: View>: View {
    var showDivider: Bool
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    init(
        showDivider: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.showDivider = showDivider
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                leading()
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: SettingsMetrics.rowMinHeight)

            if showDivider {
                Rectangle()
                    .fill(NookClip.ruleSubtle)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}

extension SettingsRow where Leading == SettingsRowTitle {
    init(
        title: String,
        subtitle: String? = nil,
        showDivider: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            showDivider: showDivider,
            leading: { SettingsRowTitle(title: title, subtitle: subtitle) },
            trailing: trailing
        )
    }
}

/// 只有文案、没有右侧控件的行（说明、当前值展示）
extension SettingsRow where Leading == SettingsRowTitle, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, showDivider: Bool = false) {
        self.init(
            showDivider: showDivider,
            leading: { SettingsRowTitle(title: title, subtitle: subtitle) },
            trailing: { EmptyView() }
        )
    }
}

// MARK: - 数字与状态胶囊

/// 面板里带数值的统计项：数字等宽 tabular，单位小一号灰色。
/// 数字必须是等宽的 —— 7 条变 12 条时行宽不该跳。
struct SettingsStatValue: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.nookClipMono(13, .medium))
                .monospacedDigit()
                .foregroundStyle(NookClip.textPrimary)
            Text(unit)
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textSecondary)
        }
    }
}

// MARK: - 原生系统开关样式

/// 对齐 macOS 原生开关规范（.toggleStyle(.switch)），完全支持系统无障碍、高对比度与键盘交互
extension ToggleStyle where Self == SwitchToggleStyle {
    static var nookSwitch: SwitchToggleStyle { SwitchToggleStyle() }
}
