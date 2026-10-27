import AppKit
import Combine
import SwiftUI

// MARK: - Tab: 粘贴 (Paste) —— 怎么把内容贴出去

@MainActor
struct PasteSettingsTab: View {
    @AppStorage(UserDefaultsKey.hotkeyDisplay.rawValue) private var hotkeyDisplay = "⌘ ⇧ V"
    @AppStorage("pasteSoundEnabled") private var pasteSoundEnabled = true
    /// 终端防误触护栏开关（缺省开启：关掉它等于让用户先踩一次坑）
    @AppStorage(UserDefaultsKey.terminalSafePasteEnabled.rawValue) private var terminalSafePasteEnabled = true
    /// 是否同时保护 VS Code / Cursor / Xcode / JetBrains 等编辑器与 AI 工具内置终端（缺省开启）
    @AppStorage(UserDefaultsKey.terminalSafePasteIdeEnabled.rawValue) private var terminalSafePasteIdeEnabled = true
    @State private var accessibilityTrusted = PasteService.isAccessibilityTrusted
    private let accessibilityStatusTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage(
            title: L10n.tr("settings.tab.paste"),
            subtitle: L10n.tr("settings.subtitle.paste"),
            status: [
                (L10n.tr("settings.status.hotkey"), hotkeyDisplay),
                (L10n.tr("settings.status.accessibility"), accessibilityStateWord),
                (L10n.tr("settings.paste.sound_section"), L10n.stateWord(pasteSoundEnabled)),
                (L10n.tr("settings.status.terminal_guard"), L10n.stateWord(terminalSafePasteEnabled)),
            ]
        ) {
            // 1. 全局唤起快捷键
            SettingsFoldGroup(
                index: 0,
                title: L10n.tr("settings.hotkey.global_title"),
                summary: hotkeyDisplay
            ) {
                SettingsRow(
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
                                    // 当前生效的预设：淡强调色底 + 强调色文字，
                                    // 与侧栏、开关用同一套「选中」语汇
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
                                                    ? NookClip.accent.opacity(0.55)
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

            // 2. 辅助功能权限（粘贴的前置条件）
            SettingsFoldGroup(
                index: 1,
                title: L10n.tr("settings.permissions.section"),
                summary: accessibilityStateWord
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        // 权限状态是「事实」不是「装饰」：用线性图标 + 语义色，
                        // 不用系统那枚实心绿圆 —— 设置页里唯一的高饱和色应该留给
                        // 真正需要被看见的数据，不是每个分组旁边的一枚勋章
                        Image(systemName: accessibilityTrusted ? NookClipIcon.TCC.trusted : NookClipIcon.TCC.untrusted)
                            .font(.system(size: 18, weight: .regular))
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

            // 3. 粘贴音效
            SettingsFoldGroup(
                index: 2,
                title: L10n.tr("settings.paste.sound_section"),
                summary: L10n.stateWord(pasteSoundEnabled)
            ) {
                SettingsRow(
                    title: L10n.tr("settings.general.paste_sound"),
                    subtitle: L10n.tr("settings.general.paste_sound_desc")
                ) {
                    Toggle("", isOn: $pasteSoundEnabled)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }
            }

            // 4. 终端防误触护栏
            //
            // 放在音效之后、速查之前：它改的是「按回车的后果」，比音效重要得多，
            // 但又不如快捷键和权限那样必须第一时间看到。
            SettingsFoldGroup(
                index: 3,
                title: L10n.tr("settings.paste.terminal_section"),
                summary: L10n.stateWord(terminalSafePasteEnabled)
            ) {
                SettingsRow(
                    title: L10n.tr("settings.paste.terminal_guard_title"),
                    subtitle: L10n.tr("settings.paste.terminal_guard_desc"),
                    showDivider: terminalSafePasteEnabled
                ) {
                    Toggle("", isOn: $terminalSafePasteEnabled)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }

                if terminalSafePasteEnabled {
                    SettingsRow(
                        title: L10n.tr("settings.paste.terminal_ide_title"),
                        subtitle: L10n.tr("settings.paste.terminal_ide_desc")
                    ) {
                        Toggle("", isOn: $terminalSafePasteIdeEnabled)
                            .toggleStyle(.nookSwitch)
                            .labelsHidden()
                    }
                }
            }

            // 5. 键位速查
            //
            // 原先四张速查表各占一个分组，翻下去全是键位、很吵。
            // 现在收进同一组：折叠时一行摘要就够，展开后按「导航 / 粘贴 / 管理 / 面板」分段。
            // 与 MainView 键盘主循环及 contracts C3 全表一致。
            SettingsFoldGroup(
                index: 4,
                title: L10n.tr("settings.hotkey.cheatsheet"),
                summary: L10n.tr("settings.hotkey.cheatsheet_sum")
            ) {
                cheatSectionTitle(L10n.tr("settings.hotkey.group_navigation"))
                shortcutCheatRow(kbd: "↑ ↓", label: L10n.tr("settings.hotkey.action_move_selection"), divider: true)
                shortcutCheatRow(kbd: "⇧ ↑ ↓", label: L10n.tr("settings.hotkey.action_multiselect"), divider: true)
                shortcutCheatRow(kbd: "⌘ [ ]", label: L10n.tr("settings.hotkey.action_cycle_category"), divider: true)
                shortcutCheatRow(kbd: "⌘ F", label: L10n.tr("settings.hotkey.action_focus_search"), divider: true)
                shortcutCheatRow(kbd: "⌘ ↓", label: L10n.tr("settings.hotkey.action_category_menu"), divider: true)
                shortcutCheatRow(kbd: "⌘ T", label: L10n.tr("settings.hotkey.action_time_menu"), divider: true)

                cheatSectionTitle(L10n.tr("settings.hotkey.group_paste"))
                shortcutCheatRow(kbd: "⏎", label: L10n.tr("settings.hotkey.action_paste"), divider: true)
                shortcutCheatRow(kbd: "⌘ ⏎", label: L10n.tr("settings.hotkey.action_paste_keep_open"), divider: true)
                shortcutCheatRow(kbd: "⌥ ⏎", label: L10n.tr("settings.hotkey.action_paste_plain"), divider: true)
                shortcutCheatRow(kbd: "⌃ ⏎", label: L10n.tr("preview.scrub.button"), divider: true)
                shortcutCheatRow(kbd: "⌃ ⇧ ⏎", label: L10n.tr("scrub.banner.restore"), divider: true)

                cheatSectionTitle(L10n.tr("settings.hotkey.group_manage"))
                shortcutCheatRow(kbd: "⌘ P", label: L10n.tr("preview.pin.button"), divider: true)
                shortcutCheatRow(kbd: "⌘ S", label: L10n.tr("settings.hotkey.action_favorite"), divider: true)
                shortcutCheatRow(kbd: "⌘ R", label: L10n.tr("settings.hotkey.action_rename"), divider: true)
                shortcutCheatRow(kbd: "⌘ ⌫", label: L10n.tr("settings.hotkey.action_delete"), divider: true)
                shortcutCheatRow(kbd: "⌘ Z", label: L10n.tr("settings.hotkey.action_undo"), divider: true)

                cheatSectionTitle(L10n.tr("settings.hotkey.group_panel"))
                shortcutCheatRow(kbd: "Esc", label: L10n.tr("settings.hotkey.action_dismiss"), divider: false)
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

    private var accessibilityStateWord: String {
        accessibilityTrusted
            ? L10n.tr("settings.status.trusted")
            : L10n.tr("settings.status.untrusted")
    }

    @MainActor
    private func refreshAccessibilityStatus() {
        accessibilityTrusted = PasteService.isAccessibilityTrusted
    }

    /// 速查表里的分段小标题：比正文小一号、灰色，只用来分组不抢视线
    private func cheatSectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.nookClipMeta)
            .foregroundStyle(NookClip.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
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
                    .fill(NookClip.ruleSubtle)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}
