import Foundation

// MARK: - 终端安全粘贴护栏（P0 · Terminal Safe-Paste）
//
// 这一层只做三件事：读开关、把剪贴板文本交给 Rust 判定、把判定结果翻译成
// 调用方可以直接执行的动作。真正的规则（哪些应用算终端、什么算高危、安全文本
// 长什么样）全在 `crates/nookclip-core/src/algorithms/terminal_guard.rs`，
// 与 Windows 端共用同一套，避免两端行为漂移。
//
// 为什么门面做在这里而不是 `PasteService` 里：粘贴服务只管「把字节写进剪贴板
// 再敲 ⌘V」，它不该知道「macOS 上 Warp 的 bundle id 是什么」这种规则；而
// `ClipboardWorkflow` 需要的是「这一下到底要不要拦」这一个布尔语义。门面把
// 原始判定记录压成决策，两边都不用直接碰 FFI 记录。

/// 一次粘贴在终端里的处理方式。
enum TerminalPasteDecision: Equatable {
    /// 不是终端、开关关闭，或内容为空：完全按原有路径粘贴
    case passthrough
    /// 单行低风险但末尾带回车：静默去掉回车再粘贴，只给一句轻提示
    case silentStrip(TerminalPasteAssessment)
    /// 多行或命中高危：必须让用户在弹窗里看清内容再决定
    case confirm(TerminalPasteAssessment)
}

/// 判定结果的 Swift 侧视图。
///
/// 不直接用 UniFFI 生成的 `FfiTerminalPasteAssessment`：那个类型会随 FFI
/// 字段变动而改签名，UI 与工作流不该跟着抖；这里只保留决策需要的部分。
struct TerminalPasteAssessment: Equatable {
    /// 命中的高危分类稳定标识（"multiline" / "sudo" / "rm_rf" …）
    let hazards: [String]
    /// 非空行数（1 = 单行）
    let lineCount: UInt32
    /// 仅去掉末尾换行的文本（保留原有换行结构）
    let safeText: String
    /// 多行被 ` && ` 串成一行的形态；不可安全串联时等于 `safeText`
    let singleLineText: String
    /// 多行能否安全合并（heredoc / 块结构 / 显式连接符时为 false）
    let canMergeSingleLine: Bool

    /// 「安全粘贴」实际写入剪贴板的文本。
    ///
    /// 多行一律用单行形态：整段内容只是被填进终端的输入行，用户自己按回车
    /// 才会执行；不能合并时（heredoc 等）退化为只去末尾换行，宁可让用户
    /// 逐行确认，也不擅自改写命令语义。
    var pasteText: String { singleLineText }

    /// 命中的高危分类对应的本地化文案，按固定顺序拼接。
    var localizedHazardSummary: String {
        hazards.map { L10n.tr("terminal.hazard.\($0)") }.joined(separator: " · ")
    }

    /// 弹窗标题下的一句现状描述，例如「3 行命令 · 含提权执行」。
    var localizedSummary: String {
        let lines = L10n.tr("terminal.confirm.lines", Int(lineCount))
        guard !hazards.isEmpty else { return lines }
        return "\(lines) · \(localizedHazardSummary)"
    }
}

enum TerminalPasteGuard {
    /// 开关缺省为开：这一档是纯收益的防误触（不含任何格式改写），
    /// 默认关闭等于让用户先踩一次坑才知道有这个功能。
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKey.terminalSafePasteEnabled.rawValue) as? Bool ?? true
    }

    /// 是否同时保护编辑器与 AI 工具（VS Code、Cursor、Xcode、JetBrains 等）的内置终端，缺省为开。
    static var isIdeEnabled: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKey.terminalSafePasteIdeEnabled.rawValue) as? Bool ?? true
    }

    /// 判定一次粘贴该怎么处理。
    ///
    /// - Parameters:
    ///   - bundleId: 目标应用 Bundle ID
    ///   - appName: 目标应用本地化名称（用于未登记 Bundle ID 的终端关键词兜底）
    ///   - includeIdeTerminals: 是否将编辑器与 AI 工具内置终端也纳入保护
    ///   - text: 即将写入剪贴板的明文
    static func decide(
        bundleId: String?,
        appName: String? = nil,
        includeIdeTerminals: Bool = isIdeEnabled,
        text: String
    ) -> TerminalPasteDecision {
        guard isEnabled else { return .passthrough }
        let bid = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bid.isEmpty || !name.isEmpty else { return .passthrough }
        guard !text.isEmpty else { return .passthrough }

        let raw = assessTerminalPasteRiskWithContext(
            bundleId: bid,
            appName: name,
            text: text,
            includeIdeTerminals: includeIdeTerminals
        )
        // 非终端目标：Rust 原样放行，客户端完全不介入
        guard raw.isTerminal else { return .passthrough }

        let assessment = TerminalPasteAssessment(
            hazards: raw.hazards,
            lineCount: raw.lineCount,
            safeText: raw.safeText,
            singleLineText: raw.singleLineText,
            canMergeSingleLine: raw.canMergeSingleLine
        )

        if raw.requiresConfirmation {
            return .confirm(assessment)
        }
        // 低风险且原文末尾确实有回车 → 静默削掉；没有回车就没什么可做的
        return raw.stripsTrailingNewline ? .silentStrip(assessment) : .passthrough
    }

    /// 目标应用是否受终端护栏保护（面板底栏或顺序粘贴栈装填判断用）。
    static func isTerminal(
        bundleId: String?,
        appName: String? = nil,
        includeIdeTerminals: Bool = isIdeEnabled
    ) -> Bool {
        let bid = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bid.isEmpty || !name.isEmpty else { return false }
        return isTerminalTargetApp(
            bundleId: bid,
            appName: name,
            includeIdeTerminals: includeIdeTerminals
        )
    }
}
