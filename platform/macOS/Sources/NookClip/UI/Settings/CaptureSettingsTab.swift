import SwiftUI

// MARK: - Tab: 记录 (Capture) —— 记什么、不记什么

@MainActor
struct CaptureSettingsTab: View {
    @AppStorage("enableSensitiveProtection") private var enableSensitiveProtection = true
    @AppStorage("sensitiveClipboardTimeout") private var sensitiveClipboardTimeout = 30
    @AppStorage(UserDefaultsKey.formBurstAutoSuggestEnabled.rawValue) private var formBurstAutoSuggestEnabled = true
    // MARK: 粘完即焚
    @AppStorage(UserDefaultsKey.autoBurnOtpEnabled.rawValue) private var autoBurnOtpEnabled = true
    @AppStorage(UserDefaultsKey.autoBurnClearOnPaste.rawValue) private var autoBurnClearOnPaste = true
    @AppStorage(UserDefaultsKey.autoBurnHistoryBurnEnabled.rawValue) private var autoBurnHistoryBurnEnabled = false

    private var isAutoBurnActive: Bool {
        autoBurnOtpEnabled || autoBurnClearOnPaste
    }
    var body: some View {
        SettingsPage(
            title: L10n.tr("settings.tab.capture"),
            subtitle: L10n.tr("settings.subtitle.capture"),
            status: [
                (L10n.tr("settings.status.sensitive"), L10n.stateWord(enableSensitiveProtection)),
                (L10n.tr("settings.status.auto_burn"), L10n.stateWord(isAutoBurnActive)),
                (L10n.tr("settings.status.sensitive_clear"), sensitiveClipboardTimeout == 0
                    ? L10n.tr("settings.retention.unlimited")
                    : "\(sensitiveClipboardTimeout) " + L10n.tr("settings.general.seconds")),
                (L10n.tr("settings.status.form_burst"), L10n.stateWord(formBurstAutoSuggestEnabled)),
                (L10n.tr("settings.status.excluded"), "\(excludedCount)"),
            ]
        ) {
            SettingsFoldGroup(
                index: 0,
                title: L10n.tr("settings.general.privacy_ocr"),
                summary: L10n.stateWord(enableSensitiveProtection)
            ) {
                SettingsRow(
                    title: L10n.tr("settings.general.enable_sensitive"),
                    subtitle: L10n.tr("settings.general.sensitive_desc"),
                    showDivider: enableSensitiveProtection
                ) {
                    Toggle("", isOn: $enableSensitiveProtection)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }

                if enableSensitiveProtection {
                    SettingsRow(
                        title: L10n.tr("settings.general.sensitive_timeout"),
                        subtitle: L10n.tr("settings.general.sensitive_timeout_desc")
                    ) {
                        Picker("", selection: $sensitiveClipboardTimeout) {
                            Text("10 " + L10n.tr("settings.general.seconds")).tag(10)
                            Text("30 " + L10n.tr("settings.general.seconds")).tag(30)
                            Text("60 " + L10n.tr("settings.general.seconds")).tag(60)
                            Text(L10n.tr("settings.retention.unlimited")).tag(0)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
            }

            SettingsFoldGroup(
                index: 1,
                title: L10n.tr("settings.capture.auto_burn_title"),
                summary: isAutoBurnActive
                    ? L10n.tr("settings.capture.auto_burn_summary")
                    : L10n.stateWord(false)
            ) {
                SettingsRow(
                    title: L10n.tr("settings.capture.auto_burn_otp"),
                    subtitle: L10n.tr("settings.capture.auto_burn_otp_desc"),
                    showDivider: true
                ) {
                    Toggle("", isOn: $autoBurnOtpEnabled)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }

                SettingsRow(
                    title: L10n.tr("settings.capture.auto_burn_clear"),
                    subtitle: L10n.tr("settings.capture.auto_burn_clear_desc"),
                    showDivider: true
                ) {
                    Toggle("", isOn: $autoBurnClearOnPaste)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }

                SettingsRow(
                    title: L10n.tr("settings.capture.auto_burn_history"),
                    subtitle: L10n.tr("settings.capture.auto_burn_history_desc")
                ) {
                    Toggle("", isOn: $autoBurnHistoryBurnEnabled)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }
            }

            SettingsFoldGroup(
                index: 2,
                title: L10n.tr("settings.capture.form_burst_title"),
                summary: L10n.stateWord(formBurstAutoSuggestEnabled)
            ) {
                SettingsRow(
                    title: L10n.tr("settings.capture.form_burst_row_title"),
                    subtitle: L10n.tr("settings.capture.form_burst_row_subtitle")
                ) {
                    Toggle("", isOn: $formBurstAutoSuggestEnabled)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }
            }

            SettingsFoldGroup(
                index: 3,
                title: L10n.tr("excluded.title"),
                summary: "\(excludedCount)"
            ) {
                ExcludedAppsView()
            }
        }
    }

    /// 现状带与折叠摘要都要显示「已排除几个应用」，
    /// 值本身由 ExcludedAppsView 自己维护，这里只读它的 UserDefaults 镜像。
    private var excludedCount: Int {
        ExcludedAppsManager.shared.apps.count
    }
}
