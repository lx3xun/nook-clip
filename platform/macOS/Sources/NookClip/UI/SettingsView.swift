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
        VStack(spacing: 0) {
            tabBarHeader

            Rectangle()
                .fill(NookClip.separator)
                .frame(height: 0.5)

            ScrollView {
                VStack(spacing: 18) {
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
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 580, height: 520)
        .background(NookClip.bgPanel)
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

    // MARK: - 顶栏标签导航 (Mac 偏好设置经典样式)
    private var tabBarHeader: some View {
        HStack(spacing: 4) {
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element.id) { index, tab in
                Button {
                    withAnimation(NookClip.animHover) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: NookClipIconSize.title, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab ? NookClip.accent : NookClip.textSecondary)
                        Text(tab.title)
                            .font(selectedTab == tab ? .nookClipMetaMedium : .nookClipMeta)
                            .foregroundStyle(selectedTab == tab ? NookClip.textPrimary : NookClip.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                                .fill(NookClip.bgRowOn)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                // Tab 键不再聚焦标签按钮（否则打开设置后「通用」默认持有键盘焦点环）
                .focusable(false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
