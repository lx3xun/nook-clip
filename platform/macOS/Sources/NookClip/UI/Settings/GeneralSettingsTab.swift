import ServiceManagement
import SwiftUI

// MARK: - Tab 5: 通用 (General) —— 系统行为

@MainActor
struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("SUEnableAutomaticChecks") private var autoCheckUpdates = true
    @AppStorage(UserDefaultsKey.updateSource.rawValue) private var updateSource = UpdateSource.auto.rawValue

    var body: some View {
        VStack(spacing: 16) {
            // 基础设置
            SettingsSectionView(title: L10n.tr("settings.general.app_section")) {
                SettingsRowView(
                    title: L10n.tr("settings.general.launch_at_login"),
                    subtitle: L10n.tr("settings.general.launch_desc"),
                    showDivider: false
                ) {

                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, enabled in
                            updateLaunchAtLogin(enabled)
                        }
                }
            }

            // 软件更新（Sparkle 应用内更新，替代旧版跳转 GitHub 页）
            SettingsSectionView(title: L10n.tr("settings.general.update_section")) {
                SettingsRowView(
                    title: L10n.tr("settings.general.update_auto"),
                    subtitle: L10n.tr("settings.general.update_auto_desc"),
                    showDivider: true
                ) {
                    Toggle("", isOn: $autoCheckUpdates)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }

                SettingsRowView(
                    title: L10n.tr("settings.general.update_source"),
                    subtitle: L10n.tr("settings.general.update_source_desc"),
                    showDivider: true
                ) {
                    Picker("", selection: $updateSource) {
                        Text(L10n.tr("settings.general.update_source_auto")).tag(UpdateSource.auto.rawValue)
                        Text(L10n.tr("settings.general.update_source_github")).tag(UpdateSource.github.rawValue)
                        Text(L10n.tr("settings.general.update_source_gitee")).tag(UpdateSource.gitee.rawValue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)
                }

                SettingsRowView(
                    title: L10n.tr("settings.general.version"),
                    subtitle: L10n.tr("settings.general.version_desc")
                ) {
                    HStack(spacing: 10) {
                        Text(AppBranding.appVersion)
                            .font(.nookClipMono(12, .medium))
                            .foregroundStyle(NookClip.textSecondary)
                        Button(L10n.tr("menu.check_updates")) {
                            UpdateService.shared.checkForUpdates()
                        }
                    }
                }
            }
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
