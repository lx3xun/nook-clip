import SwiftUI

// MARK: - Tab 4: 外观 (Appearance)

@MainActor
struct AppearanceSettingsTab: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("enableTranslucency") private var enableTranslucency = true
    /// 背景透明度 0~0.5：越大背景越透明（默认 0.15）
    @AppStorage("backgroundTransparency") private var backgroundTransparency: Double = 0.15
    @AppStorage(UserDefaultsKey.rowSelectionStyle.rawValue) private var rowSelectionStyle = RowSelectionStyle.subtleAccent.rawValue

    var body: some View {
        VStack(spacing: 16) {
            // 外观模式可视化卡片选择
            SettingsSectionView(title: L10n.tr("settings.general.appearance_section")) {
                VStack(spacing: 12) {
                    HStack(spacing: 18) {
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
                    .padding(.vertical, 12)
                }

                SettingsRowView(
                    title: L10n.tr("settings.general.translucency"),
                    subtitle: L10n.tr("settings.general.translucency_desc"),
                    showDivider: enableTranslucency
                ) {
                    Toggle("", isOn: $enableTranslucency)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }

                if enableTranslucency {
                    SettingsRowView(
                        title: L10n.tr("settings.general.transparency"),
                        showDivider: true
                    ) {
                        HStack(spacing: 8) {
                            Slider(value: $backgroundTransparency, in: 0...0.5, step: 0.05)
                                .frame(width: 120)
                            Text("\(Int(round(backgroundTransparency * 100)))%")
                                .font(.nookClipMono(12, .medium))
                                .foregroundStyle(NookClip.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }

                SettingsRowView(title: L10n.tr("settings.general.language")) {
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
            SettingsSectionView(title: L10n.tr("settings.appearance.list_section")) {
                SettingsRowView(
                    title: L10n.tr("settings.appearance.selection_style"),
                    subtitle: L10n.tr("settings.appearance.selection_style_desc"),
                    showDivider: true
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
}
