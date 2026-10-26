import AppKit
import Foundation
import NaturalLanguage

// MARK: - 脱敏规则目录（设置页呈现 + 配置持久化的唯一事实来源）

/// 内置规则分组：设置页按「凭据 / 网络与设备 / 个人信息」三组呈现，
/// 与 `crates/nookclip-core/src/algorithms/scrub.rs` 的 19 条内置规则一一对应。
enum ScrubRuleGroup: String, CaseIterable, Identifiable, Sendable {
    /// 账号凭据：密钥、私钥、连接串
    case credentials
    /// 网络与设备：IP、MAC、主机账号、云存储桶、序列号
    case network
    /// 个人信息：邮箱、电话、证件、地址、姓名
    case personal

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .credentials: return "scrub.group.credentials"
        case .network: return "scrub.group.network"
        case .personal: return "scrub.group.personal"
        }
    }

    var icon: String {
        switch self {
        case .credentials: return "key.fill"
        case .network: return "network"
        case .personal: return "person.text.rectangle.fill"
        }
    }
}

/// 单条内置规则的展示元数据。`id` 必须与 Rust 侧 `BuiltinScrubRule::rule_id` 完全一致。
struct ScrubRuleDescriptor: Identifiable, Sendable {
    let id: String
    let group: ScrubRuleGroup
    let titleKey: String
    /// 占位符形态模板（如 `<EMAIL_N>`）。`N` 表示「第几个」，仅供内部拼接。
    let placeholder: String

    /// 给用户看的占位符样例：把模板里的 `N` 落成 `1`。
    /// 模板本身对用户像没填完的半成品，样例才是他按下 ⌃⏎ 后真正看到的东西。
    var placeholderExample: String {
        placeholder.replacingOccurrences(of: "_N", with: "_1")
    }

    /// 默认全开：Rust 侧空列表语义即「全部启用」，这里保持同一心智模型
    static let all: [ScrubRuleDescriptor] = [
        // 凭据
        .init(id: "api_keys", group: .credentials, titleKey: "scrub.rule.api_keys", placeholder: "<API_KEY_N>"),
        .init(id: "private_key", group: .credentials, titleKey: "scrub.rule.private_key", placeholder: "<PRIVATE_KEY_N>"),
        .init(id: "conn_secret", group: .credentials, titleKey: "scrub.rule.conn_secret", placeholder: "<SECRET_N>"),
        // 网络与设备
        .init(id: "ip_address", group: .network, titleKey: "scrub.rule.ip_address", placeholder: "<IP_N>"),
        .init(id: "mac_address", group: .network, titleKey: "scrub.rule.mac_address", placeholder: "<MAC_ADDR_N>"),
        .init(id: "home_username", group: .network, titleKey: "scrub.rule.home_username", placeholder: "/Users/<USER_N>"),
        .init(id: "user_at_host", group: .network, titleKey: "scrub.rule.user_at_host", placeholder: "<USER_HOST_N>"),
        .init(id: "cloud_bucket", group: .network, titleKey: "scrub.rule.cloud_bucket", placeholder: "<CLOUD_BUCKET_N>"),
        .init(id: "serial_number", group: .network, titleKey: "scrub.rule.serial_number", placeholder: "<SERIAL_N>"),
        // 个人信息
        .init(id: "email", group: .personal, titleKey: "scrub.rule.email", placeholder: "<EMAIL_N>"),
        .init(id: "phone", group: .personal, titleKey: "scrub.rule.phone", placeholder: "<PHONE_N>"),
        .init(id: "id_card", group: .personal, titleKey: "scrub.rule.id_card", placeholder: "<ID_CARD_N>"),
        .init(id: "ssn", group: .personal, titleKey: "scrub.rule.ssn", placeholder: "<SSN_N>"),
        .init(id: "passport", group: .personal, titleKey: "scrub.rule.passport", placeholder: "<PASSPORT_N>"),
        .init(id: "bank_card", group: .personal, titleKey: "scrub.rule.bank_card", placeholder: "<BANK_CARD_N>"),
        .init(id: "iban", group: .personal, titleKey: "scrub.rule.iban", placeholder: "<IBAN_N>"),
        .init(id: "birth_date", group: .personal, titleKey: "scrub.rule.birth_date", placeholder: "<BIRTH_DATE_N>"),
        .init(id: "person_name", group: .personal, titleKey: "scrub.rule.person_name", placeholder: "<NAME_N>"),
        .init(id: "address", group: .personal, titleKey: "scrub.rule.address", placeholder: "<ADDRESS_N>"),
    ]

    static func grouped() -> [(group: ScrubRuleGroup, rules: [ScrubRuleDescriptor])] {
        ScrubRuleGroup.allCases.compactMap { group in
            let rules = all.filter { $0.group == group }
            return rules.isEmpty ? nil : (group, rules)
        }
    }
}

/// 用户自定义规则（可字面量、可正则）。与 Rust `CustomScrubRule` 字段一致。
struct CustomScrubRule: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var isRegex: Bool
    var pattern: String
    var placeholderTag: String
    var enabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String = "",
        isRegex: Bool = false,
        pattern: String = "",
        placeholderTag: String = "CUSTOM",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isRegex = isRegex
        self.pattern = pattern
        self.placeholderTag = placeholderTag
        self.enabled = enabled
    }

    /// 空 pattern 的规则不参与脱敏（也避免 Rust 侧空正则匹配全文）
    var isRunnable: Bool {
        enabled && !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 脱敏结果

/// 一次脱敏的完整结果：`⌃⏎` 用它写入剪贴板并向用户播报
struct ScrubOutcome {
    let scrubbedText: String
    let hasReplacements: Bool
    /// 按占位符聚合的替换统计（`<EMAIL_1>` → (email, 出现次数)）
    let replacements: [(placeholder: String, ruleKey: String, count: Int)]
    let activeVaultCount: Int

    var totalReplaced: Int {
        replacements.reduce(0) { $0 + $1.count }
    }

    /// 按占位符个数统计的条数（同值同号只算一次），用于「N 类共 M 处」播报
    var distinctCount: Int { replacements.count }

    /// 人类可读摘要，如「已脱敏 2 类 3 处 · 邮箱、手机号」。
    /// @MainActor：规则标题要经 L10n 取当前语言文案，而本地化管理器是主线程隔离的
    @MainActor
    var localizedSummary: String {
        guard hasReplacements else { return L10n.tr("scrub.result.none") }
        let ruleTitles = replacements.map { ScrubService.localizedTitle(for: $0.ruleKey) }.joined(separator: "、")
        return L10n.tr("scrub.result.summary", String(ruleTitles), String(totalReplaced))
    }
}

struct RestoreOutcome {
    let restoredText: String
    let restoredCount: Int
}

/// 预检结果：这条文本里有多少处敏感片段、分别命中哪些规则。
/// 与 `ScrubOutcome` 的关键区别是**零副作用**——不分配占位符、不写会话池。
struct ScrubScanOutcome: Equatable {
    let hitCount: Int
    let ruleKeys: [String]

    var hasHits: Bool { hitCount > 0 }

    /// 人类可读的规则清单，如「邮箱、手机号」（最多 3 条，超出用「等」兜住）。
    /// @MainActor：标题要经 L10n 取当前语言文案，本地化管理器主线程隔离。
    @MainActor
    var localizedRuleList: String {
        let titles = ruleKeys.prefix(3).map { ScrubService.localizedTitle(for: $0) }
        guard !titles.isEmpty else { return "" }
        let joined = titles.joined(separator: L10n.tr("scrub.hint.separator"))
        if ruleKeys.count > titles.count {
            return joined + L10n.tr("scrub.hint.more_rules")
        }
        return joined
    }
}

// MARK: - 脱敏服务

/// 语义占位符脱敏的门面：用户配置读写（UserDefaults）+ macOS 侧 NLP 实体识别
/// + Rust 核心（正则/校验位/区间归并/会话池）的唯一接线点。
///
/// 分工：本类只负责「配置 + NLP 补位 + 结果包装」，
/// 所有规则匹配、校验位判定、同值同号与映射表生命周期都在 Rust 侧，
/// 保证 `cargo test` 可独立验证安全不变量（见 plan.md Constitution Check）。
@MainActor
final class ScrubService {
    static let shared = ScrubService()

    /// UserDefaults 键（与 `UserDefaultsKey` 分开：这是脱敏专属配置域）
    enum DefaultsKey {
        static let disabledRules = "scrub.disabledBuiltinRules"
        static let legacyEnabledRules = "scrub.enabledBuiltinRules"
        static let customRules = "scrub.customRules"
        static let sessionTTL = "scrub.sessionTtlSeconds"
        static let nlpEntities = "scrub.nlpEntitiesEnabled"
        /// 预览区「这条含敏感信息，可按 ⌃⏎ 脱敏」的提示开关（默认开）
        static let pasteHintEnabled = "scrub.pasteHintEnabled"
    }

    /// 默认会话池 TTL：30 分钟（与文档红线一致）
    static let defaultSessionTTLSeconds = 1_800

    /// NLP 只处理这个长度内的文本：超长日志靠 Rust 正则已足够，
    /// 避免 NLTagger 在整段日志上引入感知到的卡顿
    private static let nlpByteLimit = 65_536

    /// 预览提示的采样上限（字符）：见 `scanForHint(_:)`
    static let hintSampleCharacterLimit = 200_000

    private let defaults: UserDefaults

    /// 关闭的内置规则 id 集合（空 = 全开，与 Rust 语义一致）
    private(set) var disabledRuleIDs: Set<String>

    private(set) var customRules: [CustomScrubRule]

    /// 会话池 TTL（秒）：0 = 不跨调用保留映射表（每次脱敏即用即弃）
    var sessionTTLSeconds: Int

    /// 是否启用 macOS 本地 NLP 识别姓名/地址（纯离线，不联网）
    var nlpEntitiesEnabled: Bool

    /// 预览区是否展示「含敏感信息 · 可按 ⌃⏎ 脱敏」提示。
    /// 默认开：这个提示是「发现性」而非「拦截」，关掉只影响提示不影响功能。
    ///
    /// 刻意做成**读 UserDefaults 的计算属性**而不是构造时缓存的存储属性：
    /// 设置页用 `@AppStorage` 写同一个键，本类要能立刻读到新值，
    /// 否则「关了开关但预览区提示还在」会被当成开关失效。
    var pasteHintEnabled: Bool {
        get { defaults.object(forKey: DefaultsKey.pasteHintEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DefaultsKey.pasteHintEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let persistedDisabled = defaults.stringArray(forKey: DefaultsKey.disabledRules)
            ?? defaults.stringArray(forKey: DefaultsKey.legacyEnabledRules)
            ?? []
        self.disabledRuleIDs = Set(persistedDisabled)
        self.sessionTTLSeconds = defaults.object(forKey: DefaultsKey.sessionTTL) as? Int
            ?? Self.defaultSessionTTLSeconds
        self.nlpEntitiesEnabled = defaults.object(forKey: DefaultsKey.nlpEntities) as? Bool ?? true
        self.customRules = Self.loadCustomRules(from: defaults)
    }

    // MARK: 配置

    private static func loadCustomRules(from defaults: UserDefaults) -> [CustomScrubRule] {
        guard let data = defaults.data(forKey: DefaultsKey.customRules) else { return [] }
        return (try? JSONDecoder().decode([CustomScrubRule].self, from: data)) ?? []
    }

    /// 某条内置规则当前是否启用
    func isRuleEnabled(_ id: String) -> Bool {
        !disabledRuleIDs.contains(id)
    }

    func setRule(_ id: String, enabled: Bool) {
        if enabled {
            disabledRuleIDs.remove(id)
        } else {
            disabledRuleIDs.insert(id)
        }
        persistDisabledRules()
    }

    /// 整组开关：组内全开 → 全部关闭；否则 → 全部打开（与系统设置的心智一致）
    func setGroup(_ group: ScrubRuleGroup, enabled: Bool) {
        let ids = ScrubRuleDescriptor.all.filter { $0.group == group }.map(\.id)
        for id in ids {
            if enabled {
                disabledRuleIDs.remove(id)
            } else {
                disabledRuleIDs.insert(id)
            }
        }
        persistDisabledRules()
    }

    func isGroupEnabled(_ group: ScrubRuleGroup) -> Bool {
        ScrubRuleDescriptor.all
            .filter { $0.group == group }
            .allSatisfy { isRuleEnabled($0.id) }
    }

    func isGroupPartiallyEnabled(_ group: ScrubRuleGroup) -> Bool {
        let states = ScrubRuleDescriptor.all.filter { $0.group == group }.map { isRuleEnabled($0.id) }
        return states.contains(true) && states.contains(false)
    }

    private func persistDisabledRules() {
        defaults.set(Array(disabledRuleIDs), forKey: DefaultsKey.disabledRules)
    }

    /// 保存自定义规则（空 pattern 的草稿不入库，但已禁用的有效规则必须保留）
    func saveCustomRules(_ rules: [CustomScrubRule]) {
        let validRules = rules.filter { !$0.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        customRules = validRules
        if let data = try? JSONEncoder().encode(validRules) {
            defaults.set(data, forKey: DefaultsKey.customRules)
        }
    }

    func addCustomRule(_ rule: CustomScrubRule) {
        var next = customRules
        next.append(rule)
        saveCustomRules(next)
    }

    func updateCustomRule(_ rule: CustomScrubRule) {
        var next = customRules
        if let idx = next.firstIndex(where: { $0.id == rule.id }) {
            next[idx] = rule
        } else {
            next.append(rule)
        }
        saveCustomRules(next)
    }

    func removeCustomRule(id: String) {
        saveCustomRules(customRules.filter { $0.id != id })
    }

    func setSessionTTLSeconds(_ seconds: Int) {
        sessionTTLSeconds = max(0, seconds)
        defaults.set(sessionTTLSeconds, forKey: DefaultsKey.sessionTTL)
    }

    func setNLPEntitiesEnabled(_ enabled: Bool) {
        nlpEntitiesEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.nlpEntities)
    }

    func setPasteHintEnabled(_ enabled: Bool) {
        pasteHintEnabled = enabled
    }

    /// 组装给 Rust 的配置
    func makeFFIConfig() -> FfiScrubConfig {
        // 始终显式列出启用的规则，不依赖「空 = 全启用」的隐式语义：
        // 用户把所有规则都关掉时，空列表必须真的表示「一条都不脱敏」，
        // 否则隐私开关会出现「全关反而全开」的反直觉行为。
        let enabled = ScrubRuleDescriptor.all
            .filter { isRuleEnabled($0.id) }
            .map(\.id)
        let ffiRules = customRules.filter(\.isRunnable).map { rule in
            FfiCustomScrubRule(
                id: rule.id,
                name: rule.name,
                isRegex: rule.isRegex,
                pattern: rule.pattern,
                placeholderTag: rule.placeholderTag,
                enabled: rule.enabled
            )
        }
        return FfiScrubConfig(
            enabledBuiltinRules: enabled,
            customRules: ffiRules,
            sessionTtlSeconds: UInt64(max(0, sessionTTLSeconds))
        )
    }

    // MARK: 脱敏 / 还原

    /// 对文本做语义占位符脱敏。`⌃⏎` 走这里。
    func scrub(_ text: String) -> ScrubOutcome {
        guard !text.isEmpty else {
            return ScrubOutcome(scrubbedText: text, hasReplacements: false, replacements: [], activeVaultCount: Int(activeScrubVaultCount()))
        }
        let spans = Self.detectEntitySpans(in: text, enabled: nlpEntitiesEnabled)
        let result = scrubSensitiveText(text: text, config: makeFFIConfig(), externalSpans: spans)
        let mapped = result.replacements.map {
            (placeholder: $0.placeholder, ruleKey: $0.ruleKey, count: Int($0.count))
        }
        return ScrubOutcome(
            scrubbedText: result.scrubbedText,
            hasReplacements: result.hasReplacements,
            replacements: mapped,
            activeVaultCount: Int(result.activeVaultCount)
        )
    }

    /// 预检：这条文本里有多少处敏感片段。**只扫描，不写会话池。**
    ///
    /// 预览区的「含敏感信息 · 可按 ⌃⏎ 脱敏」提示走这里。刻意不复用 `scrub`：
    /// 用户每点一下列表就调一次 `scrub` 会把占位符塞进映射表，导致后面按 ⌃⇧⏎
    /// 时冒出一堆从没粘贴过的「可还原」提示，既误导又白占 LRU 名额。
    ///
    /// - Parameter includeEntities: 是否跑 macOS NLP 识别人名/地址。提示场景默认关：
    ///   `NLTagger` 在长文本上要几十毫秒，而提示只是「有敏感信息」的存在性判断，
    ///   正则 + 校验位已经足够；真按 ⌃⏎ 脱敏时仍会走完整链路（含 NLP）。
    func scan(_ text: String, includeEntities: Bool = false) -> ScrubScanOutcome {
        guard !text.isEmpty else {
            return ScrubScanOutcome(hitCount: 0, ruleKeys: [])
        }
        let spans: [FfiExternalEntitySpan] = includeEntities
            ? Self.detectEntitySpans(in: text, enabled: nlpEntitiesEnabled)
            : []
        let result = scanScrubText(text: text, config: makeFFIConfig(), externalSpans: spans)
        return ScrubScanOutcome(
            hitCount: Int(result.hitCount),
            ruleKeys: result.ruleKeys
        )
    }

    /// 预览提示专用扫描：**超长文本只采样头部**。
    ///
    /// 提示只回答「这条记录里有没有敏感信息」这一个存在性问题，不需要精确总数。
    /// 而 500KB 的日志全文扫一遍虽然只要几毫秒，但用户在列表里按住方向键连划时
    /// 每条都扫一次就会累加成可感知的掉帧。20 万字符足够覆盖任何真实剪贴内容
    /// 的敏感片段分布（日志/长文里的密钥、邮箱几乎不会只出现在末尾）。
    ///
    /// 不开启本地 NLP 实体识别（人名/地名）：那一步要跑 NLTagger，成本远高于正则，
    /// 而提示只在选中时出现一次，为它付这个代价不划算——正则规则已经覆盖密钥、
    /// 卡号、身份证、手机号、邮箱、IP 这些真正不能外贴的东西。
    func scanForHint(_ text: String) -> ScrubScanOutcome {
        guard text.count > Self.hintSampleCharacterLimit else {
            return scan(text)
        }
        return scan(String(text.prefix(Self.hintSampleCharacterLimit)))
    }

    /// 把文本里的活跃占位符还原成真实值。`⌃⇧⏎` 走这里。
    func restore(_ text: String) -> RestoreOutcome {
        let result = restoreScrubbedText(text: text)
        return RestoreOutcome(restoredText: result.restoredText, restoredCount: Int(result.restoredCount))
    }

    /// 文本中当前仍可还原的占位符个数（会话池未过期）。
    /// 预览区据此决定是否显示「按 ⌃⇧⏎ 还原」横幅。
    func restorableCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int(countRestorablePlaceholders(text: text))
    }

    var activeVaultCount: Int {
        Int(activeScrubVaultCount())
    }

    /// 一键清空会话池（设置页按钮 + 退出登录等场景）
    func clearVault() {
        clearScrubSessionVault()
    }

    // MARK: 极简脱敏改写（粘贴前的直接产物）

    /// 便捷入口：返回脱敏后的文本，无命中时原样返回
    func scrubbedText(for text: String) -> String {
        scrub(text).scrubbedText
    }

    /// 从剪贴板文本还原（无命中返回 nil，调用方可回退普通粘贴）
    func restoredTextIfNeeded(_ text: String) -> String? {
        guard restorableCount(in: text) > 0 else { return nil }
        let outcome = restore(text)
        return outcome.restoredCount > 0 ? outcome.restoredText : nil
    }

    // MARK: 规则标题

    /// 把 rule_key（含 `custom_xxx`）转成用户可读标题
    static func localizedTitle(for ruleKey: String) -> String {
        if let descriptor = ScrubRuleDescriptor.all.first(where: { $0.id == ruleKey }) {
            return L10n.tr(descriptor.titleKey)
        }
        if ruleKey.hasPrefix("custom") {
            return L10n.tr("scrub.rule.custom")
        }
        // 兜底：把 rule_key 变成可读文本（api_key → API Key）
        return ruleKey
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: macOS 本地 NLP 实体识别

    /// 用 NaturalLanguage 框架在本机离线识别「人名 / 地名」的 UTF-8 字节区间，
    /// 交给 Rust 与正则命中一起做非重叠归并（Rust 只接受 person_name / address 两种键）。
    ///
    /// - 纯本地推理，不联网、不上传文本（文档红线：零联网默认态）
    /// - 超长文本直接跳过：NLTagger 成本随长度线性增长，日志场景收益低
    static func detectEntitySpans(in text: String, enabled: Bool) -> [FfiExternalEntitySpan] {
        guard enabled, !text.isEmpty, text.utf8.count <= nlpByteLimit else { return [] }

        // 注意：`.personalName` / `.placeName` 是 NLTag（标签值），不是 NLTagScheme。
        // 二者都归属 `NLTagScheme.nameType` 这一个标注方案，故方案只需声明 .nameType，
        // 再在枚举回调里按 tag 值分流（写错成 tagSchemes 会在运行期什么都拿不到）。
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        // 用文本自身的主导语言，中英混排时以占比高者为准
        if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
            tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
        }

        var spans: [FfiExternalEntitySpan] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        let fullRange = text.startIndex..<text.endIndex

        tagger.enumerateTags(in: fullRange, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            guard let tag else { return true }
            switch tag {
            case .personalName:
                if let span = makeSpan(text: text, range: tokenRange, ruleKey: "person_name") {
                    spans.append(span)
                }
            case .placeName:
                if let span = makeSpan(text: text, range: tokenRange, ruleKey: "address") {
                    spans.append(span)
                }
            default:
                // 组织名等其它实体不在本期脱敏范围，跳过
                break
            }
            return true
        }
        return spans
    }

    private static func makeSpan(
        text: String,
        range: Range<String.Index>,
        ruleKey: String
    ) -> FfiExternalEntitySpan? {
        let start = text[text.startIndex..<range.lowerBound].utf8.count
        let end = start + text[range].utf8.count
        guard start < end, end <= text.utf8.count else { return nil }
        return FfiExternalEntitySpan(
            startByte: UInt32(start),
            endByte: UInt32(end),
            ruleKey: ruleKey
        )
    }
}
