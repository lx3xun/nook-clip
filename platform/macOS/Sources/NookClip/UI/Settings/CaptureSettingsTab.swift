import SwiftUI

// MARK: - Tab 1: 捕捉 (Capture) —— 什么内容进入历史

@MainActor
struct CaptureSettingsTab: View {
    @AppStorage("enableSensitiveProtection") private var enableSensitiveProtection = true
    @AppStorage("sensitiveClipboardTimeout") private var sensitiveClipboardTimeout = 30

    var body: some View {
        VStack(spacing: 16) {
            // 敏感数据保护
            SettingsSectionView(title: L10n.tr("settings.general.privacy_ocr")) {
                SettingsRowView(
                    title: L10n.tr("settings.general.enable_sensitive"),
                    subtitle: L10n.tr("settings.general.sensitive_desc"),
                    showDivider: enableSensitiveProtection
                ) {
                    Toggle("", isOn: $enableSensitiveProtection)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }
                if enableSensitiveProtection {
                    SettingsRowView(title: L10n.tr("settings.general.sensitive_timeout")) {
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

            // 排除应用列表
            ExcludedAppsView()
        }
    }
}
