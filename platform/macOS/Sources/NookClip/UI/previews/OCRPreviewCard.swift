import SwiftUI

// MARK: - US6 OCR 卡片（同原型 ocrCard · 真实识别文本 · 复制经 PasteService · 支持规则提示与状态反馈）

@MainActor
struct OCRPreviewCard: View {
    var itemId: UUID? = nil
    let ocrText: String?
    var highlightKeywords: [String]? = nil
    var isScanning: Bool = false
    var currentStage: OCRProgressStage? = nil
    var onTriggerOCR: (() -> Void)? = nil

    /// 预览数据出口（文本复制）
    private let previewData = PreviewDataProvider.live

    @State private var copied = false
    @State private var hasAttemptedScan = false
    @State private var showRules = false

    private var hasText: Bool {
        if let ocrText, !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标题栏 + 规则展开/折叠按钮 + 离线标识
            HStack(spacing: 7) {
                Image(systemName: NookClipIcon.Action.ocr)
                    .font(.system(size: NookClipIconSize.regular))
                    .foregroundStyle(NookClip.textSecondary)
                Text(L10n.tr("preview.ocr_title"))
                    .font(.nookClipSectionTitle)
                    .foregroundStyle(NookClip.textPrimary)

                // 规则说明切换按钮（卡片内平滑展开，不产生悬浮透明遮挡与文字重叠）
                rulesToggleButton

                Spacer(minLength: 0)

                if isScanning {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(L10n.tr("preview.ocr.scanning"))
                            .font(.nookClipBadge)
                            .foregroundStyle(NookClip.accent)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(NookClip.bgChipSelected, in: Capsule())
                } else {
                    PillView(text: L10n.tr("preview.ocr.badge"))
                }
            }

            // 用户展开规则时展示：100% 实体纯色底板，在垂直流内平滑展开，绝不产生层级混淆
            if showRules {
                OCRRulesBanner()
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // 正文内容区域
            contentArea
                .font(.nookClipMono(12))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            // 操作区：复制按钮或底部能力小提示
            if hasText {
                copyButton
                    .padding(.top, 12)
            } else if !isScanning {
                footerRuleHint
                    .padding(.top, 10)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusCard, style: .continuous)
                .fill(NookClip.bgInset)
        }
        .onChange(of: isScanning) { oldVal, newVal in
            if oldVal && !newVal {
                hasAttemptedScan = true
            }
        }
        .onChange(of: itemId) { _, _ in
            hasAttemptedScan = false
            copied = false
        }
    }

    // MARK: - 规则展开/折叠按钮

    private var rulesToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                showRules.toggle()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: showRules ? "info.circle.fill" : "info.circle")
                    .font(.system(size: 10, weight: .regular))
                Text(showRules ? L10n.tr("preview.ocr.rules_hide") : L10n.tr("preview.ocr.rules_show"))
                    .font(.nookClip(10))
            }
            .foregroundStyle(showRules ? NookClip.accent : NookClip.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                showRules ? NookClip.accent.opacity(0.12) : Color.clear,
                in: Capsule()
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.tr("preview.ocr.rules_title"))
    }

    // MARK: - 状态内容区

    @ViewBuilder
    private var contentArea: some View {
        if hasText {
            SearchHighlight.text(ocrText ?? "", keywords: highlightKeywords)
                .textSelection(.enabled)
                .foregroundStyle(NookClip.codeText)
        } else if isScanning {
            OCRProgressLogView(activeStage: currentStage ?? .loadingEngine)
                .padding(.vertical, 4)
        } else if hasAttemptedScan {
            // 识别完成但无文字反馈
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("preview.ocr.no_text_detected"))
                    .font(.nookClipSubhead)
                    .foregroundStyle(NookClip.textSecondary)

                if let onTriggerOCR {
                    Button(action: onTriggerOCR) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text(L10n.tr("preview.ocr.retry"))
                        }
                        .font(.nookClip(11, .medium))
                        .foregroundStyle(NookClip.accent)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.vertical, 2)
        } else {
            // 初始未识别状态：明确告知并提供识别动作
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("preview.ocr.not_scanned"))
                    .font(.nookClipSubhead)
                    .foregroundStyle(NookClip.textTertiary)

                if let onTriggerOCR {
                    Button(action: onTriggerOCR) {
                        HStack(spacing: 5) {
                            Image(systemName: NookClipIcon.Action.ocr)
                                .font(.system(size: 11, weight: .medium))
                            Text(L10n.tr("preview.ocr.recognize"))
                                .font(.nookClip(11, .medium))
                        }
                        .foregroundStyle(NookClip.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(NookClip.bgControlElevated, in: RoundedRectangle(cornerRadius: NookClip.radiusControl))
                        .overlay {
                            RoundedRectangle(cornerRadius: NookClip.radiusControl)
                                .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 复制按钮

    private var copyButton: some View {
        Button {
            if previewData.copyText(ocrText ?? "") {
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? NookClipIcon.Action.copied : NookClipIcon.Action.copy)
                    .font(.system(size: NookClipIconSize.compact))
                Text(copied ? L10n.tr("preview.ocr.copied") : L10n.tr("preview.ocr.copy"))
            }
            .font(.nookClipSubheadMedium)
            .foregroundStyle(copied ? NookClip.colorSuccess : NookClip.accent)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .fill(copied ? NookClip.colorSuccess.opacity(0.12) : NookClip.bgChipSelected)
            )
            .overlay {
                RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                    .strokeBorder(copied ? NookClip.colorSuccess.opacity(0.28) : NookClip.borderRowSelectedSubtle, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    // MARK: - 底部规则辅助说明

    private var footerRuleHint: some View {
        Text(L10n.tr("preview.ocr.footer_hint"))
            .font(.nookClip(10))
            .foregroundStyle(NookClip.textTertiary)
    }
}

// MARK: - 按需 OCR 识别与内存回收实时步骤日志视图

struct OCRProgressLogView: View {
    let activeStage: OCRProgressStage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(OCRProgressStage.allCases, id: \.rawValue) { stage in
                if stage <= activeStage {
                    logRow(for: stage, isCurrent: stage == activeStage)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(NookClip.bgCode)
        }
        .overlay {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
        }
        .animation(.easeOut(duration: 0.16), value: activeStage)
    }

    private func logRow(for stage: OCRProgressStage, isCurrent: Bool) -> some View {
        HStack(spacing: 7) {
            if isCurrent {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: NookClipIcon.Status.success)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NookClip.colorSuccess)
                    .frame(width: 12, height: 12)
            }
            Text(stage.localizedTitle)
                .font(.nookClipMono(11))
                .foregroundStyle(isCurrent ? NookClip.textPrimary : NookClip.textSecondary)
                .lineLimit(1)
        }
    }
}

// MARK: - 规则说明看板（卡片内垂直展开 · 100% 实体纯色底板 · 绝不透光与重叠）

private struct OCRRulesBanner: View {
    /// 100% 不透明实色底（深色深炭黑 · 浅色纯白微灰），确保无论上层窗口透明度如何，文字都清晰可读
    private static let solidBoxBg = Color(
        nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.20, alpha: 1.0)
                : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1.0)
        })
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(NookClip.accent)
                Text(L10n.tr("preview.ocr.rules_title"))
                    .font(.nookClip(11, .semibold))
                    .foregroundStyle(NookClip.textPrimary)
            }

            Divider()
                .opacity(0.4)

            VStack(alignment: .leading, spacing: 4) {
                ruleRow(title: L10n.tr("preview.ocr.rule_format_title"), desc: L10n.tr("preview.ocr.rule_format_desc"))
                ruleRow(title: L10n.tr("preview.ocr.rule_lang_title"), desc: L10n.tr("preview.ocr.rule_lang_desc"))
                ruleRow(title: L10n.tr("preview.ocr.rule_limit_title"), desc: L10n.tr("preview.ocr.rule_limit_desc"))
            }
            .font(.nookClip(10))
            .foregroundStyle(NookClip.textSecondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .fill(Self.solidBoxBg)
        }
        .overlay {
            RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                .strokeBorder(NookClip.borderHairline, lineWidth: 0.5)
        }
    }

    private func ruleRow(title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("•")
                .foregroundStyle(NookClip.accent)
            Text("\(title)：\(desc)")
                .lineSpacing(2)
        }
    }
}
