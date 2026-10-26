import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case capture
    case history
    case paste
    /// 隐私与脱敏（US1）：脱敏规则开关 / 自定义规则 / 会话映射表
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.tr("settings.tab.general")
        case .appearance: return L10n.tr("settings.tab.appearance")
        case .capture: return L10n.tr("settings.tab.capture")
        case .history: return L10n.tr("settings.tab.history")
        case .paste: return L10n.tr("settings.tab.paste")
        case .privacy: return L10n.tr("settings.tab.privacy")
        }
    }

    var icon: String {
        switch self {
        case .general: return NookClipIcon.Settings.general
        case .appearance: return NookClipIcon.Settings.appearance
        case .capture: return NookClipIcon.Settings.capture
        case .history: return NookClipIcon.Settings.history
        case .paste: return NookClipIcon.Settings.paste
        case .privacy: return NookClipIcon.Settings.privacy
        }
    }
}

// MARK: - 设置页外壳（方案 C：左栏导航 + 画布）

/// 设置窗口的整体框架。
///
/// 结构就三块：左边 208pt 的导航栏、右边一整块画布。**没有顶栏** —— 顶栏在
/// 偏好设置里唯一的用途是放窗口标题，而窗口标题栏本来就有标题，等于同一句话
/// 写两遍，还白占一截高度。把导航挪到左侧之后，画布获得了完整的竖向空间，
/// 每页的页头、现状带、分组全都可以直接坐在画布上，不需要再套一层卡片。
///
/// 颜色在这里一分为二：导航栏与画布地面同色（不靠明度分层），只有当前页是
/// 一个中性灰胶囊。整个设置页最"响"的东西应当是数据，而不是外壳。
@MainActor
struct SettingsView: View {
    var historyStore: InMemoryHistoryStore?
    @State private var selectedTab: SettingsTab

    init(historyStore: InMemoryHistoryStore? = nil, initialTab: SettingsTab = .general) {
        self.historyStore = historyStore
        self._selectedTab = State(initialValue: initialTab)
    }
    // 仅用于窗口级 preferredColorScheme；选中态与切换动作在 AppearanceSettingsTab
    @AppStorage("appearance") private var appearance = "system"
    @State private var languageId = UUID()

    var body: some View {
        HStack(spacing: 0) {
            rail
            canvas
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(NookClip.bgGround)
        .preferredColorScheme(preferredScheme)
        .onReceive(NotificationCenter.default.publisher(for: .languageDidChange)) { _ in
            languageId = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { notif in
            if let tab = notif.userInfo?["tab"] as? SettingsTab {
                selectedTab = tab
            } else if let raw = notif.userInfo?["tab"] as? String, let tab = SettingsTab(rawValue: raw) {
                selectedTab = tab
            }
        }
        .id(languageId)
    }

    // MARK: 左栏导航

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr("settings.window_title"))
                .font(.nookClipSubheadMedium)
                .tracking(0.4)
                .foregroundStyle(NookClip.textSecondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 14)

            VStack(spacing: 2) {
                ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element.id) { index, tab in
                    railItem(tab: tab, index: index)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 10) {
                Rectangle()
                    .fill(NookClip.ruleSubtle)
                    .frame(height: 1)
                HStack(spacing: 8) {
                    Text(AppBranding.appVersion)
                        .font(.nookClipMono(12, .regular))
                        .monospacedDigit()
                        .foregroundStyle(NookClip.textSecondary)
                    Spacer(minLength: 4)
                    Button {
                        UpdateService.shared.checkForUpdates()
                    } label: {
                        Text(L10n.tr("menu.check_updates"))
                            .font(.nookClipSubheadMedium)
                            .foregroundStyle(NookClip.textPrimary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                                    .fill(NookClip.bgRaised)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("settings.general.version_desc"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
        }
        .padding(.top, 16)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(width: SettingsMetrics.railWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle().fill(NookClip.ruleSubtle).frame(width: 1)
        }
    }

    private func railItem(tab: SettingsTab, index: Int) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(NookClip.animHover) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(isSelected ? NookClip.textOnAccent : NookClip.textSecondary)
                Text(tab.title)
                    .font(.nookClipBody)
                    .foregroundStyle(isSelected ? NookClip.textOnAccent : NookClip.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .fill(NookClip.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RailItemButtonStyle(isSelected: isSelected))
        // 保留键盘可达，但去掉系统默认的聚焦环：选中态已经用强调色实心胶囊
        // 表达，再叠一圈同样的蓝环只是把边缘糊掉一层
        .focusEffectDisabled()
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: 画布

    private var canvas: some View {
        VStack(spacing: 0) {
            switch selectedTab {
            case .general:
                GeneralSettingsTab()
            case .appearance:
                AppearanceSettingsTab()
            case .capture:
                CaptureSettingsTab()
            case .history:
                HistorySettingsTab(historyStore: historyStore)
            case .paste:
                PasteSettingsTab()
            case .privacy:
                PrivacyScrubSettingsTab()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NookClip.bgGround)
        // 强调色交回系统：开关、聚焦环、下拉高亮、选中态一律用 macOS 的
        // 系统强调色（设置里换颜色，这里跟着变）。外壳本身仍然是中性灰，
        // 颜色只出现在「当前选中」与「已开启」这两类状态上。
    }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

/// 侧栏项的指针反馈：悬停给一层极淡中性底，按下再深一档。
/// 选中项不叠悬停色，避免「已经是当前页了还闪一下」。
private struct RailItemButtonStyle: ButtonStyle {
    let isSelected: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if !isSelected && isHovering {
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .fill(NookClip.bgRowOn)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { isHovering = $0 }
    }
}
