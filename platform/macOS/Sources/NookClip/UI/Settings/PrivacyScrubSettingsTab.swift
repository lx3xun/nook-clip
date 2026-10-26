import AppKit
import SwiftUI

// MARK: - Tab: 隐私脱敏（内置规则 / 自定义规则 / 会话安全）

/// 语义占位符脱敏的设置页。
///
/// 为什么在 View 里维护一份「镜像状态」而不直接读 `ScrubService.shared`：
/// 这个服务目前是普通 `final class`（还没迁到 @Observable），属性变化不会通知
/// SwiftUI；若 body 直接读它，开关点了也不刷新。因此这里每次写入后立刻回读
/// （`syncFromService` 进场灌一次，各 setter 里写一份镜像），既不改动
/// ScrubService.swift，也保证列表计数、组级全选状态、映射表条数即时反映。
/// 等它加上 @Observable 后可整体删除镜像。
@MainActor
struct PrivacyScrubSettingsTab: View {
    /// 服务入口用计算属性而不是存储属性：避免在 View 的默认初始化表达式里
    /// 触碰 @MainActor 隔离的 `ScrubService.shared`
    private var scrub: ScrubService { ScrubService.shared }

    // MARK: 镜像状态

    /// 内置规则开关：id → 是否启用
    @State private var ruleEnabled: [String: Bool] = [:]
    @State private var customRules: [CustomScrubRule] = []
    /// 会话映射表条数（清空后要立刻归零，不能等下次 onAppear）
    @State private var vaultCount = 0
    @State private var ttlSeconds = 1800
    @State private var nlpEnabled = true
    /// 「粘贴前提醒」开关，与 `ScrubService.DefaultsKey.pasteHintEnabled` 同一键。
    /// 用 @AppStorage 而不是镜像 @State：预览区读的是同一个 key，
    /// 两边任一侧改动另一方都能立刻看到，不需要额外的同步通知。
    @AppStorage(ScrubService.DefaultsKey.pasteHintEnabled) private var pasteHintEnabled = true

    // MARK: 自定义规则编辑器状态

    @State private var editorMode: EditorMode?
    @State private var editorName = ""
    @State private var editorPattern = ""
    @State private var editorTag = "CUSTOM"
    @State private var editorIsRegex = false
    /// 「再点一次删除」的武装态：只记一条，3 秒后自动复位，避免误触
    @State private var pendingDeleteID: String?

    /// 行内编辑器只有两种形态：新增 / 改某一条
    private enum EditorMode: Equatable {
        case new
        case edit(String)

        var editingID: String? {
            if case .edit(let id) = self { return id }
            return nil
        }
    }

    /// 自动销毁档位。0 = 不跨调用保留映射表（与 ScrubService 的语义一致）
    private struct TTLPreset: Identifiable {
        let seconds: Int
        let titleKey: String
        var id: Int { seconds }
    }

    private static let ttlPresets: [TTLPreset] = [
        TTLPreset(seconds: 300, titleKey: "scrub.vault.ttl_5"),
        TTLPreset(seconds: 900, titleKey: "scrub.vault.ttl_15"),
        TTLPreset(seconds: 1800, titleKey: "scrub.vault.ttl_30"),
        TTLPreset(seconds: 3600, titleKey: "scrub.vault.ttl_60"),
        TTLPreset(seconds: 0, titleKey: "scrub.vault.ttl_off")
    ]

    // MARK: - body

    var body: some View {
        SettingsPage(
            title: L10n.tr("settings.tab.privacy"),
            subtitle: L10n.tr("settings.subtitle.privacy"),
            status: [
                (L10n.tr("settings.status.scrub"), "\(enabledRuleCount) / \(ScrubRuleDescriptor.all.count)"),
                (L10n.tr("scrub.vault.title"), "\(vaultCount)"),
                (L10n.tr("scrub.hint.settings.title"), L10n.stateWord(pasteHintEnabled)),
            ]
        ) {
            builtinRuleSections
            customRuleSection
            sessionSection
        }
        .onAppear(perform: syncFromService)
    }

    /// 现状带用：已启用的内置规则条数（自定义规则不计入，口径与折叠摘要一致）
    private var enabledRuleCount: Int {
        ScrubRuleDescriptor.all.filter { ruleEnabled[$0.id] ?? true }.count
    }

    // MARK: - 分组一：内置脱敏规则（凭据 / 网络与设备 / 个人信息）

    private var builtinRuleSections: some View {
        // 三个分组各占一个折叠分组，标题直接用分组名，组内首行是本组的批量开关。
        // 摘要显示「已启用 N / M 条」，折叠起来也能看到这一组的当前状态。
        ForEach(Array(ruleBuckets.enumerated()), id: \.element.id) { bucketIndex, bucket in
            let enabled = bucket.rules.filter { ruleEnabled[$0.id] ?? true }.count
            SettingsFoldGroup(
                index: bucketIndex,
                title: L10n.tr(bucket.group.titleKey),
                summary: "\(enabled) / \(bucket.rules.count)"
            ) {
                groupMasterRow(bucket)
                ForEach(Array(bucket.rules.enumerated()), id: \.element.id) { index, descriptor in
                    ruleRow(descriptor, showDivider: index < bucket.rules.count - 1)
                }
            }
        }
    }

    /// 把 `ScrubRuleDescriptor.grouped()` 的元组包成 Identifiable，供 ForEach 使用
    private var ruleBuckets: [ScrubRuleBucket] {
        ScrubRuleDescriptor.grouped().map { ScrubRuleBucket(group: $0.group, rules: $0.rules) }
    }

    /// 组级开关。部分启用时副标题显示「N/M 已启用」，
    /// 开关本身只有开关两态（SwiftUI 原生 Switch 不支持 mixed），点一下即整组全开，
    /// 与 `ScrubService.setGroup` 的语义一致
    private func groupMasterRow(_ bucket: ScrubRuleBucket) -> some View {
        let enabledCount = bucket.rules.filter { ruleEnabled[$0.id] ?? true }.count
        let allOn = enabledCount == bucket.rules.count
        return SettingsRow(
            title: L10n.tr("scrub.group.master"),
            subtitle: L10n.tr("scrub.group.enabled_count", String(enabledCount), String(bucket.rules.count)),
            showDivider: true
        ) {
            Toggle("", isOn: Binding(
                get: { allOn },
                set: { setGroup(bucket.group, enabled: $0) }
            ))
            .toggleStyle(.nookSwitch)
            .labelsHidden()
        }
    }

    /// 单条规则行。
    ///
    /// 副标题给出「这条规则会把内容替换成什么样」的具体样例（`<EMAIL_1>` 而非
    /// 模板 `<EMAIL_N>`）：`N` 是编号占位符，直接展示会像没填完的模板；
    /// 给 `1` 就是一个真实产物，用户一眼能对上自己将看到的结果。
    /// 用等宽字体呈现，让它读起来像代码样例而不是被截断的正文。
    private func ruleRow(_ descriptor: ScrubRuleDescriptor, showDivider: Bool) -> some View {
        SettingsRow(showDivider: showDivider) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(descriptor.titleKey))
                    .font(.nookClipBody)
                    .foregroundStyle(NookClip.textPrimary)
                Text(descriptor.placeholderExample)
                    .font(.nookClipMono(11))
                    .foregroundStyle(NookClip.textSecondary)
            }
        } trailing: {
            Toggle("", isOn: ruleBinding(descriptor.id))
                .toggleStyle(.nookSwitch)
                .labelsHidden()
        }
    }

    private func ruleBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { ruleEnabled[id] ?? true },
            set: { newValue in
                ruleEnabled[id] = newValue
                scrub.setRule(id, enabled: newValue)
            }
        )
    }

    private func setGroup(_ group: ScrubRuleGroup, enabled: Bool) {
        scrub.setGroup(group, enabled: enabled)
        // 整组写入后回读一次，保证组内每行与组级开关同步翻转
        withAnimation(.easeOut(duration: 0.18)) {
            for descriptor in ScrubRuleDescriptor.all where descriptor.group == group {
                ruleEnabled[descriptor.id] = scrub.isRuleEnabled(descriptor.id)
            }
        }
    }

    // MARK: - 分组二：自定义规则

    private var customRuleSection: some View {
        SettingsFoldGroup(
            index: ruleBuckets.count,
            title: L10n.tr("scrub.custom.title"),
            summary: customRules.isEmpty ? L10n.tr("scrub.custom.empty_short") : "\(customRules.count)"
        ) {
            VStack(spacing: 0) {
                if customRules.isEmpty && editorMode == nil {
                    customEmptyRow
                }

                ForEach(customRules) { rule in
                    if editorMode?.editingID == rule.id {
                        customRuleEditor(showDivider: true)
                    } else {
                        customRuleRow(rule)
                    }
                }

                if editorMode == .new {
                    customRuleEditor(showDivider: true)
                }

                addRuleRow
            }
            // 增删规则时只有高度变化，用短促淡出即可，不做位移弹跳
            .animation(.easeOut(duration: 0.18), value: customRules)
            .animation(.easeOut(duration: 0.18), value: editorMode)
        }
    }

    private var customEmptyRow: some View {
        VStack(spacing: 0) {
            Text(L10n.tr("scrub.custom.empty"))
                .font(.nookClipMeta)
                .foregroundStyle(NookClip.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            Rectangle()
                .fill(NookClip.ruleSubtle)
                .frame(height: 1)
                .padding(.leading, 14)
        }
    }

    private func customRuleRow(_ rule: CustomScrubRule) -> some View {
        SettingsRow(showDivider: true) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName(for: rule))
                        .font(.nookClipBody)
                        .foregroundStyle(rule.enabled ? NookClip.textPrimary : NookClip.textSecondary)
                        .lineLimit(1)

                    if rule.isRegex {
                        regexBadge
                    }
                }

                Text(rule.pattern)
                    .font(.nookClipCode)
                    .foregroundStyle(NookClip.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } trailing: {
            HStack(spacing: 12) {
                Button {
                    beginEditing(rule)
                } label: {
                    Image(systemName: NookClipIcon.Context.rename)
                        .font(.system(size: NookClipIconSize.compactMedium))
                        .foregroundStyle(NookClip.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("scrub.custom.edit_title"))

                Toggle("", isOn: customRuleBinding(rule))
                    .toggleStyle(.nookSwitch)
                    .labelsHidden()

                deleteControl(rule)
            }
        }
    }

    /// 正则规则的身份徽标：不抢眼，只提示「这条不是字面量匹配」
    private var regexBadge: some View {
        Text(L10n.tr("scrub.custom.regex_badge"))
            .font(.nookClipBadge)
            .foregroundStyle(NookClip.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(NookClip.bgRaised, in: Capsule())
    }

    /// 删除的二次确认做成「按钮就地变文案」而不是弹窗：
    /// 设置页里弹 alert 会打断连续整理规则的节奏，也更容易误点确认
    @ViewBuilder
    private func deleteControl(_ rule: CustomScrubRule) -> some View {
        if pendingDeleteID == rule.id {
            Button {
                deleteRule(rule)
            } label: {
                Text(L10n.tr("scrub.custom.delete_confirm"))
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.colorDanger)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                armDelete(rule.id)
            } label: {
                Image(systemName: NookClipIcon.Action.delete)
                    .font(.system(size: NookClipIconSize.compactMedium))
                    .foregroundStyle(NookClip.colorDanger)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("scrub.custom.delete"))
        }
    }

    private var addRuleRow: some View {
        HStack {
            Button {
                beginAdding()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: NookClipIconSize.micro, weight: .semibold))
                    Text(L10n.tr("scrub.custom.add"))
                        .font(.nookClipMetaMedium)
                }
                .foregroundStyle(editorMode == nil ? NookClip.textPrimary : NookClip.textDisabled)
            }
            .buttonStyle(.plain)
            .disabled(editorMode != nil)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 行内编辑器：新增与编辑共用同一份草稿状态，靠 editorMode 决定落库动作。
    ///
    /// 用 `Grid` 而不是 HStack + 固定标签宽度：标签列的宽度由最长的那个标签
    /// （三语文案长度差异很大）自动决定，既保证四个字段左缘严格对齐，
    /// 又不会像固定宽度那样把「占位符标签」压成两行。
    private func customRuleEditor(showDivider: Bool) -> some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    editorLabel(L10n.tr("scrub.custom.name"))
                    TextField("", text: $editorName)
                        .textFieldStyle(.roundedBorder)
                        .font(.nookClipBody)
                }

                GridRow {
                    editorLabel(L10n.tr("scrub.custom.is_regex"))
                    Toggle("", isOn: $editorIsRegex)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                }

                GridRow {
                    editorLabel(L10n.tr("scrub.custom.pattern"))
                    TextField("", text: $editorPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.nookClipCode)
                }

                // 正则非法时给出即时反馈并禁用保存：否则规则存下去也不会命中。
                // 单独占一 Grid 行，空出标签列，提示才会与输入框左缘对齐
                if hasInvalidRegex {
                    GridRow {
                        Color.clear
                            .frame(width: 0, height: 0)
                            .gridCellUnsizedAxes([.horizontal, .vertical])
                        Text(L10n.tr("scrub.custom.invalid_regex"))
                            .font(.nookClipMeta)
                            .foregroundStyle(NookClip.colorDanger)
                            .transition(.opacity)
                    }
                }

                GridRow {
                    editorLabel(L10n.tr("scrub.custom.tag"))
                    // 占位符标签只能是大写字母/数字/下划线：这里做输入即净化，
                    // 避免用户输入 `-` 或中文后 Rust 侧生成非法占位符
                    TextField("", text: tagBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.nookClipCode)
                        .frame(width: 150)
                }

                GridRow {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    HStack(spacing: 10) {
                        Spacer()
                        Button(L10n.tr("scrub.custom.cancel")) {
                            closeEditor()
                        }
                        .buttonStyle(.bordered)

                        Button(L10n.tr("scrub.custom.save")) {
                            commitEditor()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSaveDraft)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(.easeOut(duration: 0.18), value: hasInvalidRegex)

            if showDivider {
                Rectangle()
                    .fill(NookClip.ruleSubtle)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }

    /// 编辑器标签列：单行不换行，太长时尾部截断（Grid 已按最宽标签定列宽）
    private func editorLabel(_ title: String) -> some View {
        Text(title)
            .font(.nookClipMeta)
            .foregroundStyle(NookClip.textSecondary)
            .lineLimit(1)
    }

    // MARK: 自定义规则编辑动作

    private func beginAdding() {
        pendingDeleteID = nil
        editorName = ""
        editorPattern = ""
        editorTag = "CUSTOM"
        editorIsRegex = false
        withAnimation(.easeOut(duration: 0.18)) {
            editorMode = .new
        }
    }

    private func beginEditing(_ rule: CustomScrubRule) {
        pendingDeleteID = nil
        editorName = rule.name
        editorPattern = rule.pattern
        editorTag = rule.placeholderTag
        editorIsRegex = rule.isRegex
        withAnimation(.easeOut(duration: 0.18)) {
            editorMode = .edit(rule.id)
        }
    }

    private func closeEditor() {
        withAnimation(.easeOut(duration: 0.18)) {
            editorMode = nil
        }
        editorName = ""
        editorPattern = ""
        editorTag = "CUSTOM"
        editorIsRegex = false
    }

    private func commitEditor() {
        guard canSaveDraft else { return }
        let pattern = editorPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = editorName.trimmingCharacters(in: .whitespacesAndNewlines)

        var rule: CustomScrubRule
        if let id = editorMode?.editingID,
           let existing = customRules.first(where: { $0.id == id }) {
            rule = existing
        } else {
            rule = CustomScrubRule()
        }
        rule.name = trimmedName
        rule.isRegex = editorIsRegex
        rule.pattern = pattern
        rule.placeholderTag = editorTag.isEmpty ? "CUSTOM" : editorTag

        withAnimation(.easeOut(duration: 0.18)) {
            if editorMode?.editingID != nil {
                scrub.updateCustomRule(rule)
            } else {
                scrub.addCustomRule(rule)
            }
            customRules = scrub.customRules
            editorMode = nil
        }
        editorName = ""
        editorPattern = ""
        editorTag = "CUSTOM"
        editorIsRegex = false
    }

    private func deleteRule(_ rule: CustomScrubRule) {
        withAnimation(.easeOut(duration: 0.18)) {
            scrub.removeCustomRule(id: rule.id)
            customRules = scrub.customRules
            pendingDeleteID = nil
            if editorMode?.editingID == rule.id {
                editorMode = nil
            }
        }
    }

    private func armDelete(_ id: String) {
        pendingDeleteID = id
        // 3 秒后自动撤销武装态：悬着一个「再点一次删除」很容易误触
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if pendingDeleteID == id {
                withAnimation(.easeOut(duration: 0.18)) {
                    pendingDeleteID = nil
                }
            }
        }
    }

    private func customRuleBinding(_ rule: CustomScrubRule) -> Binding<Bool> {
        Binding(
            get: { customRules.first(where: { $0.id == rule.id })?.enabled ?? rule.enabled },
            set: { newValue in
                var updated = rule
                updated.enabled = newValue
                scrub.updateCustomRule(updated)
                customRules = scrub.customRules
            }
        )
    }

    /// 标签输入净化：大写化 + 只留 A-Z / 0-9 / `_`
    private var tagBinding: Binding<String> {
        Binding(
            get: { editorTag },
            set: { editorTag = Self.sanitizePlaceholderTag($0) }
        )
    }

    private static func sanitizePlaceholderTag(_ raw: String) -> String {
        let filtered = raw.uppercased().filter { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_")
        }
        return String(filtered.prefix(20))
    }

    /// 正则合法性即时校验（字面量规则不需要校验）
    private var hasInvalidRegex: Bool {
        guard editorIsRegex else { return false }
        let pattern = editorPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: pattern)) == nil
    }

    private var canSaveDraft: Bool {
        let pattern = editorPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }
        return !hasInvalidRegex
    }

    /// 规则名留空时用 pattern 前 20 字符兜底，保证每行都有可辨识的主标题
    private func displayName(for rule: CustomScrubRule) -> String {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty { return rule.placeholderTag }
        return pattern.count > 20 ? String(pattern.prefix(20)) + "…" : pattern
    }

    // MARK: - 分组三：会话安全（映射表 / 自动销毁 / 本地 NLP）

    private var sessionSection: some View {
        SettingsFoldGroup(
            index: ruleBuckets.count + 1,
            title: L10n.tr("scrub.session.section"),
            summary: L10n.tr(Self.ttlPresets.first { $0.seconds == ttlSeconds }?.titleKey ?? "scrub.vault.ttl_off")
        ) {
            SettingsRow(title: L10n.tr("scrub.vault.title"), showDivider: true) {
                HStack(spacing: 10) {
                    vaultCountBadge
                    clearVaultButton
                }
            }

            SettingsRow(title: L10n.tr("scrub.vault.ttl"), showDivider: true) {
                HStack(spacing: 6) {
                    ForEach(Self.ttlPresets) { preset in
                        ttlPill(preset)
                    }
                }
            }

            SettingsRow(
                title: L10n.tr("scrub.nlp.title"),
                subtitle: L10n.tr("scrub.nlp.desc"),
                showDivider: true
            ) {
                Toggle("", isOn: Binding(
                    get: { nlpEnabled },
                    set: { newValue in
                        nlpEnabled = newValue
                        scrub.setNLPEntitiesEnabled(newValue)
                    }
                ))
                .toggleStyle(.nookSwitch)
                .labelsHidden()
            }

            // 粘贴前提醒：默认开。关掉只影响预览区那行提示，
            // 不影响 ⌃⏎ 脱敏粘贴与 ⌃⇧⏎ 还原本身——功能不会被设置项阉割。
            SettingsRow(
                title: L10n.tr("scrub.hint.settings.title"),
                subtitle: L10n.tr("scrub.hint.settings.desc"),
                showDivider: true
            ) {
                Toggle("", isOn: $pasteHintEnabled)
                    .toggleStyle(.nookSwitch)
                    .labelsHidden()
            }

            footerNote
        }
    }

    private var vaultCountBadge: some View {
        Text(L10n.tr("scrub.vault.count", String(vaultCount)))
            .font(.nookClipRounded(11, .medium))
            // 徽标是单行计数，宽度随数字变；禁止换行，否则「N 条映射」会折成两行
            .lineLimit(1)
            .foregroundStyle(vaultCount > 0 ? NookClip.textPrimary : NookClip.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                NookClip.bgRaised,
                in: Capsule()
            )
    }

    private var clearVaultButton: some View {
        Button(L10n.tr("scrub.vault.clear")) {
            scrub.clearVault()
            // 立即回读：按钮的可用性与徽标要跟着归零，不能等下次 onAppear
            vaultCount = scrub.activeVaultCount
        }
        .buttonStyle(.plain)
        .font(.nookClipMeta)
        .lineLimit(1)
        .foregroundStyle(vaultCount > 0 ? NookClip.colorDanger : NookClip.textDisabled)
        .disabled(vaultCount == 0)
        .help(L10n.tr("scrub.vault.clear"))
    }

    /// 档位胶囊：与 PasteSettingsTab 的快捷键预设按钮同一套描边/底色规则
    private func ttlPill(_ preset: TTLPreset) -> some View {
        let selected = ttlSeconds == preset.seconds
        return Button {
            withAnimation(NookClip.animHover) {
                ttlSeconds = preset.seconds
            }
            scrub.setSessionTTLSeconds(preset.seconds)
        } label: {
            Text(L10n.tr(preset.titleKey))
                .font(.nookClipRounded(11, selected ? .semibold : .regular))
                // 胶囊文案必须单行：五个档位横排，任一档换行都会把整行撑高
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    selected ? NookClip.bgChipSelected : NookClip.bgRowOn,
                    in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
                        .stroke(selected ? NookClip.accent.opacity(0.55) : NookClip.separator, lineWidth: 0.5)
                )
                .foregroundStyle(selected ? NookClip.accent : NookClip.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var footerNote: some View {
        Text(L10n.tr("scrub.footer.privacy"))
            .font(.nookClipMeta)
            .foregroundStyle(NookClip.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }

    // MARK: - 与服务同步

    /// ScrubService 非 @Observable，进入页面时把它的真实状态灌进镜像
    private func syncFromService() {
        var enabled: [String: Bool] = [:]
        for descriptor in ScrubRuleDescriptor.all {
            enabled[descriptor.id] = scrub.isRuleEnabled(descriptor.id)
        }
        ruleEnabled = enabled
        customRules = scrub.customRules
        ttlSeconds = scrub.sessionTTLSeconds
        nlpEnabled = scrub.nlpEntitiesEnabled
        vaultCount = scrub.activeVaultCount
    }
}

// MARK: - 分组包装

/// `ScrubRuleDescriptor.grouped()` 返回元组，无法直接 ForEach，
/// 这里只做一层 Identifiable 包装，不复制任何规则数据
private struct ScrubRuleBucket: Identifiable {
    let group: ScrubRuleGroup
    let rules: [ScrubRuleDescriptor]

    var id: String { group.id }
}
