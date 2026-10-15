import AppKit
import Combine
import SwiftUI

// MARK: - Tab 3: 粘贴 (Paste) —— 怎么把内容贴出去

@MainActor
struct PasteSettingsTab: View {
    @AppStorage(UserDefaultsKey.hotkeyDisplay.rawValue) private var hotkeyDisplay = "⌘ ⇧ V"
    @AppStorage("pasteSoundEnabled") private var pasteSoundEnabled = true
    @State private var accessibilityTrusted = PasteService.isAccessibilityTrusted
    private let accessibilityStatusTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            // 全局唤起快捷键
            SettingsSectionView(title: L10n.tr("settings.hotkey.global_title")) {
                SettingsRowView(
                    title: L10n.tr("settings.hotkey.global_title"),
                    subtitle: L10n.tr("settings.hotkey.global_desc"),
                    showDivider: true
                ) {
                    ShortcutRecorderButton(hotkeyDisplay: $hotkeyDisplay)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(L10n.tr("settings.hotkey.recommended_presets"))
                            .font(.nookClipSubhead)
                            .foregroundStyle(NookClip.textSecondary)

                        ForEach(HotKeyShortcut.presets, id: \.displayString) { preset in
                            Button {
                                if HotKeyManager.shared.update(shortcut: preset) {
                                    hotkeyDisplay = preset.displayString
                                }
                            } label: {
                                Text(preset.displayString)
                                    .font(.nookClipRounded(11, hotkeyDisplay == preset.displayString ? .semibold : .regular))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        hotkeyDisplay == preset.displayString
                                            ? NookClip.bgChipSelected
                                            : NookClip.bgRowOn,
                                        in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                                            .stroke(
                                                hotkeyDisplay == preset.displayString
                                                    ? NookClip.accent.opacity(0.4)
                                                    : NookClip.separator,
                                                lineWidth: 0.5
                                            )
                                    )
                                    .foregroundStyle(
                                        hotkeyDisplay == preset.displayString
                                            ? NookClip.accent
                                            : NookClip.textSecondary
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text(L10n.tr("settings.hotkey.record_instructions"))
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            // 辅助功能权限（粘贴的前置条件）
            SettingsSectionView(title: L10n.tr("settings.permissions.section")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: accessibilityTrusted ? NookClipIcon.TCC.trusted : NookClipIcon.TCC.untrusted)
                            .font(.system(size: NookClipIconSize.titleLarge))
                            .foregroundStyle(accessibilityTrusted ? NookClip.colorSuccess : NookClip.colorSensitive)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(accessibilityTrusted ? L10n.tr("settings.permissions.trusted") : L10n.tr("settings.permissions.untrusted"))
                                .font(.nookClipSectionTitle)
                                .foregroundStyle(NookClip.textPrimary)
                            Text(accessibilityTrusted
                                 ? L10n.tr("settings.permissions.trusted_desc", hotkeyDisplay)
                                 : L10n.tr("settings.permissions.untrusted_desc"))
                                .font(.nookClipMeta)
                                .foregroundStyle(NookClip.textSecondary)
                        }
                    }

                    if accessibilityTrusted {
                        Text(L10n.tr("settings.permissions.trusted_success", hotkeyDisplay))
                            .font(.nookClipMeta)
                            .foregroundStyle(NookClip.textSecondary)
                    } else {
                        HStack(spacing: 10) {
                            Button(L10n.tr("settings.permissions.open_settings")) {
                                PasteService.openAccessibilitySettings()
                            }
                            .buttonStyle(.borderedProminent)

                            Button(L10n.tr("settings.permissions.recheck")) {
                                refreshAccessibilityStatus()
                            }
                            .buttonStyle(.bordered)

                            Button(L10n.tr("settings.permissions.restart")) {
                                PasteService.restartApp()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(NookClip.textSecondary)
                        }
                        .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("settings.permissions.stale_title"))
                                .font(.nookClipMetaMedium)
                                .foregroundStyle(NookClip.textPrimary)
                            Text(L10n.tr("settings.permissions.stale_desc"))
                                .font(.nookClipCaption)
                                .foregroundStyle(NookClip.textSecondary)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(14)
            }

            // 粘贴音效
            SettingsSectionView(title: L10n.tr("settings.paste.sound_section")) {
                SettingsRowView(
                    title: L10n.tr("settings.general.paste_sound"),
                    subtitle: L10n.tr("settings.general.paste_sound_desc")
                ) {
                    Toggle("", isOn: $pasteSoundEnabled)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }
            }

            // 内置快捷操作速查一览（分组：导航 / 粘贴 / 管理 / 面板；
            // 与 MainView 键盘主循环及 contracts C3 全表一致）
            SettingsSectionView(title: L10n.tr("settings.hotkey.group_navigation")) {
                VStack(spacing: 0) {
                    shortcutCheatRow(kbd: "↑ ↓", label: L10n.tr("settings.hotkey.action_move_selection"), divider: true)
                    shortcutCheatRow(kbd: "⇧ ↑ ↓", label: L10n.tr("settings.hotkey.action_multiselect"), divider: true)
                    shortcutCheatRow(kbd: "⌘ [ ]", label: L10n.tr("settings.hotkey.action_cycle_category"), divider: true)
                    shortcutCheatRow(kbd: "⌘ F", label: L10n.tr("settings.hotkey.action_focus_search"), divider: true)
                    shortcutCheatRow(kbd: "⌘ ↓", label: L10n.tr("settings.hotkey.action_category_menu"), divider: true)
                    shortcutCheatRow(kbd: "⌘ T", label: L10n.tr("settings.hotkey.action_time_menu"), divider: false)
                }
            }

            SettingsSectionView(title: L10n.tr("settings.hotkey.group_paste")) {
                VStack(spacing: 0) {
                    shortcutCheatRow(kbd: "⏎", label: L10n.tr("settings.hotkey.action_paste"), divider: true)
                    shortcutCheatRow(kbd: "⌘ ⏎", label: L10n.tr("settings.hotkey.action_paste_keep_open"), divider: true)
                    shortcutCheatRow(kbd: "⌥ ⏎", label: L10n.tr("settings.hotkey.action_paste_plain"), divider: false)
                }
            }

            SettingsSectionView(title: L10n.tr("settings.hotkey.group_manage")) {
                VStack(spacing: 0) {
                    shortcutCheatRow(kbd: "⌘ S", label: L10n.tr("settings.hotkey.action_favorite"), divider: true)
                    shortcutCheatRow(kbd: "⌘ R", label: L10n.tr("settings.hotkey.action_rename"), divider: true)
                    shortcutCheatRow(kbd: "⌘ ⌫", label: L10n.tr("settings.hotkey.action_delete"), divider: true)
                    shortcutCheatRow(kbd: "⌘ Z", label: L10n.tr("settings.hotkey.action_undo"), divider: false)
                }
            }

            SettingsSectionView(title: L10n.tr("settings.hotkey.group_panel")) {
                VStack(spacing: 0) {
                    shortcutCheatRow(kbd: "Esc", label: L10n.tr("settings.hotkey.action_dismiss"), divider: false)
                }
            }
        }
        .onAppear {
            refreshAccessibilityStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAccessibilityStatus()
        }
        .onReceive(accessibilityStatusTimer) { _ in
            refreshAccessibilityStatus()
        }
    }

    @MainActor
    private func refreshAccessibilityStatus() {
        accessibilityTrusted = PasteService.isAccessibilityTrusted
    }

    private func shortcutCheatRow(kbd: String, label: String, divider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.nookClipSubhead)
                    .foregroundStyle(NookClip.textPrimary)
                Spacer()
                KbdView(text: kbd, fontSize: 11)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            if divider {
                Rectangle()
                    .fill(NookClip.separator)
                    .frame(height: 0.5)
                    .padding(.leading, 14)
            }
        }
    }
}
