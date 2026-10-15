import AppKit
import SwiftUI

// MARK: - 快捷键录制组件

struct ShortcutRecorderButton: View {
    @Binding var hotkeyDisplay: String
    @StateObject private var model = ShortcutRecorderModel()
    @State private var localMonitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if model.isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if model.isRecording {
                            Circle()
                                .fill(NookClip.colorDanger)
                                .frame(width: 7, height: 7)
                            Text(L10n.tr("settings.hotkey.press_keys"))
                                .font(.nookClipMetaMedium)
                                .foregroundStyle(NookClip.accent)
                        } else {
                            Image(systemName: NookClipIcon.Control.keyboard)
                                .font(.system(size: NookClipIconSize.compact))
                                .foregroundStyle(NookClip.textSecondary)
                            Text(hotkeyDisplay)
                                .font(.nookClipRounded(12, .semibold))
                                .foregroundStyle(NookClip.textPrimary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        model.isRecording
                            ? NookClip.bgAccentSubtle
                            : NookClip.bgControlElevated,
                        in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                model.isRecording ? NookClip.accent.opacity(0.75) : NookClip.borderKbd,
                                lineWidth: model.isRecording ? 1.5 : 0.5
                            )
                    )
                }
                .buttonStyle(.plain)

                if model.isRecording {
                    Button(L10n.tr("settings.hotkey.cancel")) {
                        stopRecording()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if hotkeyDisplay != HotKeyShortcut.defaultShortcut.displayString {
                    Button {
                        resetToDefault()
                    } label: {
                        Image(systemName: NookClipIcon.Control.resetHotkey)
                            .font(.system(size: NookClipIconSize.compact))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NookClip.textSecondary)
                    .help(L10n.tr("settings.hotkey.reset_default"))
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(NookClip.colorDanger)
            }
        }
        .onDisappear {
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotKeyDidChange)) { _ in
            // 快捷键经其他入口变更（预设按钮/恢复默认）时终止录制态（审计 BUG-040）
            if model.isRecording {
                stopRecording()
            }
        }
    }

    private func startRecording() {
        model.startRecording()
        removeMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak model] event in
            guard let model else { return event }
            let consumed = model.handleKeyEvent(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) { display in
                hotkeyDisplay = display
                removeMonitor()
            }
            if !model.isRecording {
                removeMonitor()
            }
            return consumed ? nil : event
        }
    }

    private func stopRecording() {
        model.stopRecording()
        removeMonitor()
    }

    private func removeMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func resetToDefault() {
        model.resetToDefault { display in
            hotkeyDisplay = display
        }
    }
}
