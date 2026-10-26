import ServiceManagement
import SwiftUI

// MARK: - Tab: 通用 (General) —— 系统行为

@MainActor
struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = true
    @AppStorage("SUEnableAutomaticChecks") private var autoCheckUpdates = true
    @AppStorage(UserDefaultsKey.updateSource.rawValue) private var updateSource = UpdateSource.auto.rawValue

    var body: some View {
        SettingsPage(
            title: L10n.tr("settings.tab.general"),
            subtitle: L10n.tr("settings.subtitle.general"),
            status: [
                (L10n.tr("settings.general.launch_at_login"), L10n.stateWord(launchAtLogin)),
                (L10n.tr("settings.general.update_auto"), L10n.stateWord(autoCheckUpdates)),
                (L10n.tr("settings.general.version"), AppBranding.appVersion),
            ]
        ) {
            SettingsFoldGroup(
                index: 0,
                title: L10n.tr("settings.general.app_section"),
                summary: L10n.tr("settings.general.launch_at_login")
                    + " · " + L10n.stateWord(launchAtLogin)
            ) {
                SettingsRow(
                    title: L10n.tr("settings.general.launch_at_login"),
                    subtitle: L10n.tr("settings.general.launch_desc")
                ) {
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, enabled in
                            updateLaunchAtLogin(enabled)
                        }
                }
            }

            SettingsFoldGroup(
                index: 1,
                title: L10n.tr("settings.general.update_section"),
                summary: L10n.tr("settings.general.update_auto")
                    + " · " + L10n.stateWord(autoCheckUpdates)
            ) {
                SettingsRow(
                    title: L10n.tr("settings.general.update_auto"),
                    subtitle: L10n.tr("settings.general.update_auto_desc"),
                    showDivider: true
                ) {
                    Toggle("", isOn: $autoCheckUpdates)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }

                SettingsRow(
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

                SettingsRow(
                    title: L10n.tr("settings.general.version"),
                    subtitle: L10n.tr("settings.general.version_desc")
                ) {
                    HStack(spacing: 10) {
                        Text(AppBranding.appVersion)
                            .font(.nookClipMono(12, .medium))
                            .monospacedDigit()
                            .foregroundStyle(NookClip.textSecondary)
                        Button {
                            UpdateService.shared.checkForUpdates()
                        } label: {
                            Text(L10n.tr("menu.check_updates"))
                                .font(.nookClipSubheadMedium)
                                .foregroundStyle(NookClip.textPrimary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background {
                                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                                        .fill(NookClip.bgRaised)
                                }
                        }
                        .buttonStyle(.plain)
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
