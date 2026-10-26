import SwiftUI

// MARK: - Tab: 外观 (Appearance)

@MainActor
struct AppearanceSettingsTab: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("enableTranslucency") private var enableTranslucency = true
    /// 背景透明度 0~0.5：越大背景越透明（默认 0.15）
    @AppStorage("backgroundTransparency") private var backgroundTransparency: Double = 0.15
    @AppStorage(UserDefaultsKey.rowSelectionStyle.rawValue) private var rowSelectionStyle = RowSelectionStyle.subtleAccent.rawValue

    var body: some View {
        SettingsPage(
            title: L10n.tr("settings.tab.appearance"),
            subtitle: L10n.tr("settings.subtitle.appearance"),
            status: [
                (L10n.tr("settings.status.appearance"), Self.appearanceLabel(appearance)),
                (L10n.tr("settings.general.transparency"), "\(Int(round(backgroundTransparency * 100)))%"),
                (L10n.tr("settings.general.language"), LocalizationManager.shared.selectedLanguage.title),
            ]
        ) {
            SettingsFoldGroup(
                index: 0,
                title: L10n.tr("settings.general.appearance_section"),
                summary: Self.appearanceLabel(appearance)
            ) {
                // 三张可视化卡片直接坐在面板里：它们本身就是「效果预览」，
                // 再包一层行反而会把预览挤小。
                HStack(spacing: 14) {
                    AppearanceOptionCard(
                        mode: "system",
                        title: L10n.tr("settings.general.appearance_system"),
                        isSelected: appearance == "system"
                    ) {
                        setAppearance("system")
                    }

                    AppearanceOptionCard(
                        mode: "light",
                        title: L10n.tr("settings.general.appearance_light"),
                        isSelected: appearance == "light"
                    ) {
                        setAppearance("light")
                    }

                    AppearanceOptionCard(
                        mode: "dark",
                        title: L10n.tr("settings.general.appearance_dark"),
                        isSelected: appearance == "dark"
                    ) {
                        setAppearance("dark")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)

                Rectangle()
                    .fill(NookClip.ruleSubtle)
                    .frame(height: 1)
                    .padding(.leading, 14)

                SettingsRow(
                    title: L10n.tr("settings.general.translucency"),
                    subtitle: L10n.tr("settings.general.translucency_desc"),
                    showDivider: enableTranslucency
                ) {
                    Toggle("", isOn: $enableTranslucency)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }

                if enableTranslucency {
                    SettingsRow(
                        title: L10n.tr("settings.general.transparency"),
                        showDivider: true
                    ) {
                        HStack(spacing: 8) {
                            Slider(value: $backgroundTransparency, in: 0...0.5, step: 0.05)
                                .frame(width: 120)
                            Text("\(Int(round(backgroundTransparency * 100)))%")
                                .font(.nookClipMono(12, .medium))
                                .monospacedDigit()
                                .foregroundStyle(NookClip.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }

                SettingsRow(title: L10n.tr("settings.general.language")) {
                    Picker("", selection: Binding(
                        get: { LocalizationManager.shared.selectedLanguage },
                        set: { LocalizationManager.shared.selectedLanguage = $0 }
                    )) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.title).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)
                }
            }

            // 列表与导航风格定制（005-ui-ux-redesign）
            SettingsFoldGroup(
                index: 1,
                title: L10n.tr("settings.appearance.list_section"),
                summary: Self.selectionStyleLabel(rowSelectionStyle)
            ) {
                SettingsRow(
                    title: L10n.tr("settings.appearance.selection_style"),
                    subtitle: L10n.tr("settings.appearance.selection_style_desc")
                ) {
                    Picker("", selection: $rowSelectionStyle) {
                        Text(L10n.tr("settings.appearance.selection_solid")).tag(RowSelectionStyle.solidAccent.rawValue)
                        Text(L10n.tr("settings.appearance.selection_subtle")).tag(RowSelectionStyle.subtleAccent.rawValue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 170)
                }
            }
        }
        .onAppear {
            // 旧版本残留的超范围值统一钳回 50%，保证滑块与百分数一致
            if backgroundTransparency > 0.5 { backgroundTransparency = 0.5 }
        }
    }

    private func setAppearance(_ mode: String) {
        appearance = mode
        NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
    }

    /// 折叠摘要与现状带共用：改档位时标题旁那句摘要自动跟上
    private static func appearanceLabel(_ mode: String) -> String {
        switch mode {
        case "light":
            return L10n.tr("settings.general.appearance_light")
        case "dark":
            return L10n.tr("settings.general.appearance_dark")
        default:
            return L10n.tr("settings.general.appearance_system")
        }
    }

    private static func selectionStyleLabel(_ style: String) -> String {
        style == RowSelectionStyle.solidAccent.rawValue
            ? L10n.tr("settings.appearance.selection_solid")
            : L10n.tr("settings.appearance.selection_subtle")
    }
}
