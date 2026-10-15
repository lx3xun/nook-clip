import SwiftUI

// MARK: - US6 JSON 卡片（美化/压缩/原文三段 · 基于真实解析，非法 JSON 锁原文）

@MainActor
struct JSONPreviewCard: View {
    @State private var segment = 0
    /// 检测结果缓存（onAppear/onChange 计算一次）：此前为无缓存计算属性，
    /// 单帧 body 经 isValidJSON/effectiveSegment/lines/footerText 触发 5-6 次
    /// 全量 JSON 解析 + 双重序列化（审计 BUG-009）
    @State private var detection: LanguageClassifier.DetectionResult?
    /// 超限降级标记：超过上限的文本不做检测/美化（解析数 MB JSON 会卡死主线程）
    @State private var exceedsSizeLimit = false
    @State private var copied = false

    let text: String
    private let previewData = PreviewDataProvider.live

    /// 检测与格式化的文本大小上限（512KB）：超限锁定原文段
    private static let maxDetectionBytes = 512 * 1024

    /// 非法 JSON（或解析产物缺失、或超限降级）锁定原文段并禁用另两段（data-model §3.4）
    private var isValidJSON: Bool {
        !exceedsSizeLimit
            && detection?.isJSON == true
            && detection?.formattedJSON != nil
            && detection?.minifiedJSON != nil
    }

    private var effectiveSegment: Int { isValidJSON ? segment : 2 }

    private var lines: [String] {
        switch effectiveSegment {
        case 1:
            return CodePreviewCard.normalizedLines(detection?.minifiedJSON ?? "")
        case 2:
            return CodePreviewCard.normalizedLines(text)
        default:
            return CodePreviewCard.normalizedLines(detection?.formattedJSON ?? "")
        }
    }

    private var currentText: String {
        switch effectiveSegment {
        case 1:
            return detection?.minifiedJSON ?? ""
        case 2:
            return text
        default:
            return detection?.formattedJSON ?? ""
        }
    }

    private var footerText: String {
        switch effectiveSegment {
        case 1: return L10n.tr("preview.json.footer_minified")
        case 2: return isValidJSON ? L10n.tr("preview.json.footer_raw") : L10n.tr("preview.json.footer_invalid")
        default: return L10n.tr("preview.json.footer_formatted")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：JSON 胶囊 + 分段控件（同原型）
            HStack(spacing: 7) {
                PillView(text: "JSON", isAccent: true)
                copyButton
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    ForEach(Array([L10n.tr("preview.json.pretty"), L10n.tr("preview.json.minify"), L10n.tr("preview.json.raw")].enumerated()), id: \.offset) { index, label in
                        let selected = effectiveSegment == index
                        let enabled = isValidJSON || index == 2
                        Text(label)
                            .font(selected ? .nookClipMetaMedium : .nookClipMeta)
                            .foregroundStyle(selected ? NookClip.textPrimary : NookClip.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: NookClip.radiusThumb, style: .continuous)
                                        .fill(NookClip.bgControlElevated)
                                        .shadow(color: .black.opacity(0.08), radius: 1.5, x: 0, y: 0.5)
                                }
                            }
                            .opacity(enabled ? 1 : 0.35)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if enabled { segment = index }
                            }
                    }
                }
                .padding(2)
                .background(NookClip.bgInset)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 9)

            // 合法 JSON 的三段（美化/压缩/原文）都是 JSON：语言固定传入，
            // 不劳自动检测；非法 JSON 锁原文段，交给自动检测或回退
            CodeBlockView(lines: lines, forcedLanguage: isValidJSON ? "json" : nil)

            // 底部说明（⌘C 重复制已随快捷键精简移除，仅保留段落描述文案）
            Text(footerText)
                .font(.nookClip(11))
                .foregroundStyle(NookClip.textTertiary)
                .padding(.top, 8)
        }
        .onAppear { recomputeDetection() }
        .onChange(of: text) { recomputeDetection() }
    }

    /// 检测只算一次并缓存；超限文本直接降级原文（审计 BUG-009）
    private func recomputeDetection() {
        if text.utf8.count > Self.maxDetectionBytes {
            exceedsSizeLimit = true
            detection = nil
            return
        }
        exceedsSizeLimit = false
        detection = LanguageClassifier.detect(text: text)
    }

    private var copyButton: some View {
        Button {
            let contentToCopy = currentText
            guard !contentToCopy.isEmpty else { return }
            if previewData.copyText(contentToCopy) {
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        } label: {
            Image(systemName: copied ? NookClipIcon.Action.copied : NookClipIcon.Action.copy)
                .font(.system(size: NookClipIconSize.compact))
                .foregroundStyle(copied ? NookClip.colorSuccess : NookClip.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.tr("preview.json.copy"))
    }
}
