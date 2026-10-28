import SwiftUI

// MARK: - 手机快传面板（specs/014 US1）
//
// 在预览区之上浮起的一张卡片：展示局域网快传二维码、剩余倒计时、可达网卡切换、
// 手机回传计数，以及「停止分享 / 关闭」。关闭或倒计时归零都会立刻释放监听端口。
// 面板自身持有 LanQuickDropController（@StateObject），出现即启动、消失即停止，
// 从而保证「平时 0 端口监听」的隐私不变量。

struct LanQuickDropPanel: View {
    let payload: LanSharedPayload
    /// 手机回传内容 → 主应用（写剪贴板 + 入库）
    var onReceive: (LanIncomingDrop) -> Void
    var onClose: () -> Void

    @StateObject private var controller = LanQuickDropController()
    @State private var mode: Mode = .drop

    private enum Mode: Hashable {
        case link
        case drop
    }

    /// 短网址条目允许在「链接二维码」与「双向快传」之间切换
    private var isLinkPayload: Bool {
        guard payload.kind == .text,
              let raw = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count <= 512,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return true
    }

    private var activeQRText: String {
        if mode == .link, let text = payload.text {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return controller.shareURLString
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            card
                .frame(width: 400)
                .padding(20)
        }
        .transition(.opacity)
        .task {
            if isLinkPayload { mode = .link }
            await controller.start(payload: payload, onReceive: onReceive)
        }
        .onDisappear { controller.stop() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isLinkPayload {
                Picker("", selection: $mode) {
                    Text(L10n.tr("landrop.mode_link")).tag(Mode.link)
                    Text(L10n.tr("landrop.mode_drop")).tag(Mode.drop)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if mode == .link {
                    Text(L10n.tr("landrop.url_mode_hint"))
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textTertiary)
                }
            }

            mainContent

            footer
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(NookClip.bgPopover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: NookClipIcon.Action.phoneDrop)
                .font(.system(size: NookClipIconSize.title, weight: .medium))
                .foregroundStyle(NookClip.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("landrop.title"))
                    .font(.nookClipSubheadMedium)
                    .foregroundStyle(NookClip.textPrimary)
                Text(L10n.tr("landrop.subtitle"))
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button {
                dismiss()
            } label: {
                Image(systemName: NookClipIcon.Action.closeCircle)
                    .font(.system(size: NookClipIconSize.titleLarge))
                    .foregroundStyle(NookClip.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("landrop.close"))
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch controller.failure {
        case .noNetwork, .startFailed:
            messageState(
                icon: NookClipIcon.Status.wifiSlash,
                text: L10n.tr("landrop.no_network")
            )
        case .expired:
            messageState(
                icon: NookClipIcon.Feedback.warning,
                text: L10n.tr("landrop.stopped")
            )
        case nil:
            if controller.isRunning || mode == .link {
                qrBlock
            } else {
                messageState(icon: NookClipIcon.Status.loading, text: L10n.tr("landrop.starting"))
            }
        }
    }

    private func messageState(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: NookClipIconSize.hero, weight: .regular))
                .foregroundStyle(NookClip.textTertiary)
            Text(text)
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 208)
    }

    @ViewBuilder
    private var qrBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                qrImage
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("landrop.scan_hint"))
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if mode == .drop {
                        Text(verbatim: controller.shareURLString)
                            .font(.nookClipCode)
                            .foregroundStyle(NookClip.textTertiary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                        if controller.remainingSeconds > 0 {
                            Label {
                                Text(L10n.tr("landrop.countdown", controller.remainingSeconds))
                                    .monospacedDigit()
                            } icon: {
                                Image(systemName: NookClipIcon.AutoBurn.countdown)
                            }
                            .font(.nookClipMeta)
                            .foregroundStyle(NookClip.colorSensitive)
                        }
                        if controller.receivedCount > 0 {
                            Label {
                                Text(L10n.tr("landrop.received_count", controller.receivedCount))
                                    .monospacedDigit()
                            } icon: {
                                Image(systemName: NookClipIcon.Status.success)
                            }
                            .font(.nookClipMeta)
                            .foregroundStyle(NookClip.colorSuccess)
                        }
                        if controller.availableIPs.count > 1 {
                            ipPicker
                        }
                    } else if let text = payload.text {
                        Text(verbatim: text)
                            .font(.nookClipCode)
                            .foregroundStyle(NookClip.textTertiary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            if mode == .drop {
                keepOpenBanner
            }
        }
    }

    private var keepOpenBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: NookClipIcon.Feedback.warning)
                .font(.system(size: NookClipIconSize.compact, weight: .medium))
                .foregroundStyle(NookClip.colorSensitive)
            Text(L10n.tr("landrop.keep_open_hint"))
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            NookClip.bgInset,
            in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
        )
    }

    private var qrImage: some View {
        Group {
            if let image = QRCodeGenerator.image(for: activeQRText, targetPixel: 560) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 168, height: 168)
                    .padding(8)
                    .background(NookClip.bgQRCodeCanvas, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                            .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
                    }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: NookClipIcon.Empty.qrcode)
                        .font(.system(size: NookClipIconSize.heroLarge))
                        .foregroundStyle(NookClip.textTertiary)
                    Text(L10n.tr("preview.qrcode.unavailable"))
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 184, height: 184)
                .background(NookClip.bgInset, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
            }
        }
    }

    private var ipPicker: some View {
        Menu {
            ForEach(controller.availableIPs, id: \.self) { ip in
                Button {
                    controller.selectIP(ip)
                } label: {
                    if ip == controller.selectedIP {
                        Label(ip, systemImage: NookClipIcon.Nav.checkmark)
                    } else {
                        Text(ip)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: NookClipIcon.Status.wifi)
                Text(L10n.tr("landrop.ip_label"))
                Image(systemName: NookClipIcon.Nav.chevronDown)
                    .font(.system(size: NookClipIconSize.microChevron, weight: .semibold))
            }
            .font(.nookClipMeta)
            .foregroundStyle(NookClip.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                controller.stop()
                onClose()
            } label: {
                Text(L10n.tr("landrop.stop"))
                    .font(.nookClipBodyMedium)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(NookClip.bgInset, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
                    .foregroundStyle(NookClip.colorDanger)
            }
            .buttonStyle(.plain)

            Button {
                dismiss()
            } label: {
                Text(L10n.tr("landrop.close"))
                    .font(.nookClipBodyMedium)
                    .foregroundStyle(NookClip.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(NookClip.accent, in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func dismiss() {
        controller.stop()
        onClose()
    }
}
