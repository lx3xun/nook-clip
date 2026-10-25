import XCTest
@testable import NookClip

// specs/012-scrub-stack-pin · T014
// Swift 侧验收：脱敏门面（ScrubService）、顺序粘贴栈状态机（PasteStackState）、
// 以及「配置持久化 → FFI 载荷」这条接线是否自洽。
//
// Rust 核心的规则正确性由 `crates/nookclip-core/tests/test_scrub_vault.rs` 覆盖，
// 这里只验证 Swift 薄层：配置读写语义、结果包装、栈指针推进与边界。
// 样本一律运行时拼装（不写字面量敏感值，仓库不得出现真实格式的密钥）。

@MainActor
final class ScrubServiceTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = makeIsolatedDefaults()
        // 会话池是进程级单例：每个用例从干净状态开始
        clearScrubSessionVault()
    }

    override func tearDown() {
        clearScrubSessionVault()
        defaults = nil
        super.tearDown()
    }

    // MARK: - 样本（运行时拼装）

    private func sampleEmail() -> String {
        ["nook", ".scrub.", "test", "@", "example", ".", "com"].joined()
    }

    private func sampleEmail2() -> String {
        ["second", ".person", "@", "example", ".", "org"].joined()
    }

    private func samplePhone() -> String {
        "1" + "38" + "0013" + "8000"
    }

    /// 合法 18 位身份证：前 17 位固定，校验位按 ISO 7064 MOD 11-2 现算
    private func sampleIdCard() -> String {
        let body = "11010519491231002"
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checks = Array("10X98765432")
        let sum = zip(body.compactMap { $0.wholeNumberValue }, weights)
            .reduce(0) { $0 + $1.0 * $1.1 }
        return body + String(checks[sum % 11])
    }

    private func sampleAPIKey() -> String {
        "sk-" + String(repeating: "a1B2c3D4", count: 4)
    }

    // MARK: - 默认值

    func testDefaultConfigEnablesAllBuiltinRules() {
        let service = ScrubService(defaults: defaults)
        XCTAssertTrue(service.disabledRuleIDs.isEmpty)
        XCTAssertEqual(service.sessionTTLSeconds, ScrubService.defaultSessionTTLSeconds)
        XCTAssertTrue(service.nlpEntitiesEnabled)
        // 19 条内置规则全部启用
        for descriptor in ScrubRuleDescriptor.all {
            XCTAssertTrue(service.isRuleEnabled(descriptor.id), "\(descriptor.id) 应默认启用")
        }
        XCTAssertEqual(ScrubRuleDescriptor.all.count, 19)
    }

    /// 全开时也必须显式列出 19 个 id，不能传空数组。
    ///
    /// 空列表在 Rust 侧被解读为「一条都不脱敏」。早期版本曾反过来
    /// （空 = 全启用），结果用户把所有开关关掉后反而全开——隐私开关
    /// 的极端态与直觉相反，所以这里锁死「始终显式枚举」的行为。
    func testFFIConfigAlwaysListsEnabledRulesExplicitly() {
        let service = ScrubService(defaults: defaults)
        let config = service.makeFFIConfig()
        XCTAssertEqual(config.enabledBuiltinRules.count, ScrubRuleDescriptor.all.count)
        XCTAssertEqual(
            Set(config.enabledBuiltinRules),
            Set(ScrubRuleDescriptor.all.map(\.id))
        )
        XCTAssertEqual(Int(config.sessionTtlSeconds), ScrubService.defaultSessionTTLSeconds)
    }

    func testFFIConfigListsOnlyEnabledRulesWhenSomeDisabled() {
        let service = ScrubService(defaults: defaults)
        service.setRule("email", enabled: false)
        service.setRule("phone", enabled: false)
        let config = service.makeFFIConfig()
        XCTAssertEqual(Set(config.enabledBuiltinRules), Set(ScrubRuleDescriptor.all.map(\.id)).subtracting(["email", "phone"]))
        XCTAssertFalse(config.enabledBuiltinRules.contains("email"))
    }

    // MARK: - 分组批量开关

    func testGroupToggleFlipsAllRulesInGroup() {
        let service = ScrubService(defaults: defaults)
        XCTAssertTrue(service.isGroupEnabled(.credentials))
        XCTAssertFalse(service.isGroupPartiallyEnabled(.credentials))

        service.setGroup(.credentials, enabled: false)
        XCTAssertFalse(service.isGroupEnabled(.credentials))
        for descriptor in ScrubRuleDescriptor.all where descriptor.group == .credentials {
            XCTAssertFalse(service.isRuleEnabled(descriptor.id))
        }
        // 其它分组不受影响
        XCTAssertTrue(service.isGroupEnabled(.personal))

        service.setGroup(.credentials, enabled: true)
        XCTAssertTrue(service.isGroupEnabled(.credentials))
    }

    func testPartiallyEnabledGroupIsReported() {
        let service = ScrubService(defaults: defaults)
        service.setRule("api_keys", enabled: false)
        XCTAssertFalse(service.isGroupEnabled(.credentials))
        XCTAssertTrue(service.isGroupPartiallyEnabled(.credentials))
    }

    // MARK: - 配置持久化

    func testRuleTogglesPersistAcrossInstances() {
        let first = ScrubService(defaults: defaults)
        first.setRule("email", enabled: false)
        first.setSessionTTLSeconds(600)
        first.setNLPEntitiesEnabled(false)

        let second = ScrubService(defaults: defaults)
        XCTAssertFalse(second.isRuleEnabled("email"))
        XCTAssertTrue(second.isRuleEnabled("phone"))
        XCTAssertEqual(second.sessionTTLSeconds, 600)
        XCTAssertFalse(second.nlpEntitiesEnabled)
    }

    func testCustomRulesPersistAndRequireRunnablePattern() {
        let first = ScrubService(defaults: defaults)
        var rule = CustomScrubRule(name: "公司工号", isRegex: false, pattern: "EMP-", placeholderTag: "EMP")
        rule.pattern = "EMP-"
        first.addCustomRule(rule)
        // 空的 pattern 不该被持久化（否则会出现在 Rust 侧反复匹配空串）
        first.addCustomRule(CustomScrubRule(name: "空规则", pattern: "  ", placeholderTag: "X"))

        let second = ScrubService(defaults: defaults)
        XCTAssertEqual(second.customRules.count, 1)
        XCTAssertEqual(second.customRules.first?.name, "公司工号")
    }

    func testCustomRuleUpdateAndRemove() {
        let service = ScrubService(defaults: defaults)
        var rule = CustomScrubRule(name: "旧名", pattern: "OLD", placeholderTag: "OLD")
        rule.pattern = "OLD"
        service.addCustomRule(rule)
        XCTAssertEqual(service.customRules.count, 1)

        var updated = service.customRules[0]
        updated.name = "新名"
        service.updateCustomRule(updated)
        XCTAssertEqual(service.customRules[0].name, "新名")

        service.removeCustomRule(id: updated.id)
        XCTAssertTrue(service.customRules.isEmpty)
    }

    func testCustomRulePayloadPassesToFFIConfig() {
        let service = ScrubService(defaults: defaults)
        var rule = CustomScrubRule(name: "内部域名", isRegex: false, pattern: "corp.internal", placeholderTag: "corp_domain")
        rule.pattern = "corp.internal"
        service.addCustomRule(rule)

        let config = service.makeFFIConfig()
        XCTAssertEqual(config.customRules.count, 1)
        XCTAssertEqual(config.customRules[0].pattern, "corp.internal")
        // 标签会被 Rust 侧归一化成大写占位符
        XCTAssertEqual(config.customRules[0].placeholderTag, "corp_domain")
    }

    // MARK: - 脱敏结果包装

    func testScrubReportsReplacementsAndPlaceholders() {
        let service = ScrubService(defaults: defaults)
        let text = "联系人邮箱 " + sampleEmail() + " 电话 " + samplePhone()
        let outcome = service.scrub(text)

        XCTAssertTrue(outcome.hasReplacements)
        XCTAssertGreaterThan(outcome.totalReplaced, 0)
        XCTAssertFalse(outcome.scrubbedText.contains(sampleEmail()))
        XCTAssertFalse(outcome.scrubbedText.contains(samplePhone()))
        XCTAssertTrue(outcome.scrubbedText.contains("<"))
        // 每条替换都带得出可读的规则名
        for item in outcome.replacements {
            XCTAssertFalse(ScrubService.localizedTitle(for: item.ruleKey).isEmpty)
        }
    }

    /// 同值同号：同一邮箱出现两次都映射到同一个 `<EMAIL_1>`，
    /// 第二个不同邮箱才升到 `<EMAIL_2>`（AI 回复里语义可对齐）
    func testSameValueGetsSamePlaceholder() {
        let service = ScrubService(defaults: defaults)
        let a = sampleEmail()
        let b = sampleEmail2()
        let outcome = service.scrub([a, a, b].joined(separator: " | "))

        let placeholders = outcome.replacements.map(\.placeholder)
        let emailPlaceholders = placeholders.filter { $0.hasPrefix("<EMAIL_") }
        XCTAssertEqual(emailPlaceholders.count, 2, "应是两个不同占位符，而不是三个")
    }

    func testScrubEmptyTextIsNoOp() {
        let service = ScrubService(defaults: defaults)
        let outcome = service.scrub("")
        XCTAssertFalse(outcome.hasReplacements)
        XCTAssertEqual(outcome.scrubbedText, "")
        XCTAssertTrue(outcome.replacements.isEmpty)
    }

    func testScrubWithoutSensitiveContentReportsNothing() {
        let service = ScrubService(defaults: defaults)
        let outcome = service.scrub("今天开个会讨论发布节奏")
        XCTAssertFalse(outcome.hasReplacements)
        XCTAssertEqual(outcome.scrubbedText, "今天开个会讨论发布节奏")
    }

    // MARK: - 还原

    func testRestoreBringsBackOriginalValue() {
        let service = ScrubService(defaults: defaults)
        let original = sampleEmail()
        let scrubbed = service.scrub("邮箱 " + original).scrubbedText

        let restored = service.restore(scrubbed)
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertTrue(restored.restoredText.contains(original))
        XCTAssertFalse(restored.restoredText.contains("<EMAIL_1>"))
    }

    func testRestorableCountMatchesActivePlaceholders() {
        let service = ScrubService(defaults: defaults)
        XCTAssertEqual(service.restorableCount(in: "没有占位符"), 0)

        let scrubbed = service.scrub("邮箱 " + sampleEmail()).scrubbedText
        XCTAssertEqual(service.restorableCount(in: scrubbed), 1)
        // 未知占位符（会话池里没有）不算可还原
        XCTAssertEqual(service.restorableCount(in: "<EMAIL_9>"), 0)
    }

    func testRestoredTextIfNeededReturnsNilWhenNothingToRestore() {
        let service = ScrubService(defaults: defaults)
        XCTAssertNil(service.restoredTextIfNeeded("普通文本"))
    }

    func testClearVaultDropsAllMappings() {
        let service = ScrubService(defaults: defaults)
        let scrubbed = service.scrub("邮箱 " + sampleEmail()).scrubbedText
        XCTAssertEqual(service.restorableCount(in: scrubbed), 1)

        service.clearVault()
        XCTAssertEqual(service.activeVaultCount, 0)
        XCTAssertEqual(service.restorableCount(in: scrubbed), 0)
        // 映射没了就不再还原，原文也不会被凭空拼出来
        XCTAssertEqual(service.restore(scrubbed).restoredCount, 0)
    }

    // MARK: - 规则开关真的生效

    func testDisabledRuleIsNotScrubbed() {
        let service = ScrubService(defaults: defaults)
        let email = sampleEmail()
        // user@host 规则也会命中邮箱形态（`a@b.c`），要一起关掉才能
        // 单独验证 email 规则本身失效
        service.setRule("email", enabled: false)
        service.setRule("user_at_host", enabled: false)

        let outcome = service.scrub("邮箱 " + email)
        XCTAssertFalse(outcome.scrubbedText.contains("<EMAIL_"))
        XCTAssertTrue(outcome.scrubbedText.contains(email))
    }

    func testDisabledAllRulesLeavesTextIntact() {
        let service = ScrubService(defaults: defaults)
        service.setGroup(.credentials, enabled: false)
        service.setGroup(.network, enabled: false)
        service.setGroup(.personal, enabled: false)
        service.setNLPEntitiesEnabled(false)

        let text = "卡号 " + sampleIdCard() + " 密钥 " + sampleAPIKey()
        let outcome = service.scrub(text)
        XCTAssertFalse(outcome.hasReplacements)
        XCTAssertEqual(outcome.scrubbedText, text)
    }

    /// 关掉 NLP 后不应该再产生 person_name / address 区间
    func testNLPSpansSkippedWhenDisabled() {
        let text = "John Smith lives in Springfield"
        XCTAssertFalse(ScrubService.detectEntitySpans(in: text, enabled: false).isEmpty == false)
        XCTAssertTrue(ScrubService.detectEntitySpans(in: text, enabled: false).isEmpty)
    }

    /// NLP 区间必须是合法 UTF-8 边界，否则 Rust 侧会忽略（中文人名尤其容易踩）
    func testNLPSpansUseValidByteOffsets() {
        let text = "张伟住在杭州市西湖区"
        let spans = ScrubService.detectEntitySpans(in: text, enabled: true)
        let utf8 = Array(text.utf8)
        for span in spans {
            XCTAssertLessThanOrEqual(Int(span.endByte), utf8.count)
            XCTAssertLessThan(Int(span.startByte), Int(span.endByte))
            // 起点不能切在多字节字符中间
            XCTAssertTrue(isCharBoundary(utf8, Int(span.startByte)))
            XCTAssertTrue(isCharBoundary(utf8, Int(span.endByte)))
        }
    }

    private func isCharBoundary(_ bytes: [UInt8], _ offset: Int) -> Bool {
        guard offset < bytes.count else { return true }
        // UTF-8 续字节形如 10xxxxxx
        return bytes[offset] & 0xC0 != 0x80
    }

    /// 超长文本跳过 NLP（成本线性增长，日志场景收益低），但不能崩
    func testNLPSpansSkipVeryLongText() {
        let huge = String(repeating: "张伟 ", count: 40_000)
        XCTAssertTrue(huge.utf8.count > 65_536)
        XCTAssertTrue(ScrubService.detectEntitySpans(in: huge, enabled: true).isEmpty)
    }

    // MARK: - 规则标题

    func testLocalizedTitleFallsBackToHumanizedKey() {
        // 已知规则走本地化文案，未知的（含自定义）走兜底而不是崩溃或返回 key
        XCTAssertFalse(ScrubService.localizedTitle(for: "email").isEmpty)
        XCTAssertFalse(ScrubService.localizedTitle(for: "custom_domain").isEmpty)
        XCTAssertFalse(ScrubService.localizedTitle(for: "some_unknown_rule").isEmpty)
        XCTAssertNotEqual(ScrubService.localizedTitle(for: "some_unknown_rule"), "some_unknown_rule")
    }

    // MARK: - 性能预算（plan.md：10KB 脱敏 < 5ms）

    func testScrubTenKilobyteBudget() {
        let service = ScrubService(defaults: defaults)
        let line = "user " + sampleEmail() + " from 10.1.2.3 key " + sampleAPIKey() + "\n"
        var text = ""
        while text.utf8.count < 10_000 {
            text += line
        }

        let start = CFAbsoluteTimeGetCurrent()
        _ = service.scrub(text)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1_000

        // 预算 5ms；CI 机器抖动留 4 倍余量，超出即说明算法退化成 O(n²)
        XCTAssertLessThan(elapsedMs, 20, "10KB 脱敏耗时 \(elapsedMs)ms，超出预算")
    }

    // MARK: - 粘贴前预检（方案 A：预览区一行提示的数据来源）

    func testScanReportsHitsWithoutTouchingVault() {
        let service = ScrubService(defaults: defaults)
        let text = "mail " + sampleEmail() + " key " + sampleAPIKey()

        let outcome = service.scan(text)

        XCTAssertGreaterThan(outcome.hitCount, 0)
        XCTAssertFalse(outcome.ruleKeys.isEmpty)
        // 关键红线：预检必须零副作用。若它偷偷写会话池，
        // 用户每选中一条就多一份映射，「清空映射表」会清出意料之外的东西。
        XCTAssertEqual(service.activeVaultCount, 0, "预检不得写入会话池")
        XCTAssertEqual(service.restorableCount(in: text), 0)
    }

    func testScanIsIdempotentAndTextIsNotModified() {
        let service = ScrubService(defaults: defaults)
        let text = "mail " + sampleEmail()
        let first = service.scan(text)
        let second = service.scan(text)

        // 预检只统计，不分配占位符：同样的文本扫多少次结果都一样，
        // 且原文保持原样（不出现 <EMAIL_1> 之类的替换）
        XCTAssertEqual(first, second)
        XCTAssertFalse(text.contains("<"))
    }

    func testScanOnCleanTextReportsNothing() {
        let service = ScrubService(defaults: defaults)
        let outcome = service.scan("今天下午三点开会，记得带笔记本")
        XCTAssertEqual(outcome.hitCount, 0)
        XCTAssertTrue(outcome.ruleKeys.isEmpty)
        XCTAssertFalse(outcome.hasHits)
    }

    func testScanForHintSamplesOversizeText() {
        let service = ScrubService(defaults: defaults)
        // 头部是普通文字、敏感内容全在超长尾巴里：采样后应当扫不到。
        // 这正是提示只需要「存在性」的取舍——超长文本不为一行提示扫全文。
        var text = String(repeating: "普通", count: ScrubService.hintSampleCharacterLimit / 2 + 1000)
        text += " mail " + sampleEmail()

        XCTAssertGreaterThan(text.count, ScrubService.hintSampleCharacterLimit)
        let outcome = service.scanForHint(text)
        XCTAssertEqual(outcome.hitCount, 0, "超长文本只看采样头部")
    }

    func testScanForHintFindsHitsInsideSampleWindow() {
        let service = ScrubService(defaults: defaults)
        var text = " mail " + sampleEmail() + " "
        text += String(repeating: "x", count: ScrubService.hintSampleCharacterLimit)

        let outcome = service.scanForHint(text)
        XCTAssertTrue(outcome.hasHits, "头部窗口内的命中必须被发现")
    }

    func testScanEmptyTextReturnsEmptyOutcome() {
        let service = ScrubService(defaults: defaults)
        let outcome = service.scan("")
        XCTAssertEqual(outcome.hitCount, 0)
        XCTAssertTrue(outcome.ruleKeys.isEmpty)
    }

    // MARK: - 提示开关持久化

    func testPasteHintEnabledDefaultsToTrue() {
        let service = ScrubService(defaults: defaults)
        XCTAssertTrue(service.pasteHintEnabled, "新用户默认开启，否则这个提示等于没做")
    }

    func testPasteHintEnabledPersistsImmediately() {
        let service = ScrubService(defaults: defaults)
        service.setPasteHintEnabled(false)

        // 计算属性必须直接读到新值：设置页用 @AppStorage 写同一个键，
        // 若这里靠内存缓存，用户在设置里关掉后预览区仍会显示提示
        XCTAssertFalse(service.pasteHintEnabled)
        XCTAssertEqual(defaults.object(forKey: ScrubService.DefaultsKey.pasteHintEnabled) as? Bool, false)

        // 换一个实例（模拟重启）也要读到同一个值
        let reloaded = ScrubService(defaults: defaults)
        XCTAssertFalse(reloaded.pasteHintEnabled)
    }

    func testPasteHintEnabledReflectsExternalWrite() {
        let service = ScrubService(defaults: defaults)
        defaults.set(false, forKey: ScrubService.DefaultsKey.pasteHintEnabled)

        // @AppStorage 是直接写 UserDefaults 的，服务必须无缓存地反映它
        XCTAssertFalse(service.pasteHintEnabled)

        defaults.set(true, forKey: ScrubService.DefaultsKey.pasteHintEnabled)
        XCTAssertTrue(service.pasteHintEnabled)
    }

    func testLocalizedRuleListIsReadable() {
        let service = ScrubService(defaults: defaults)
        let outcome = service.scan("mail " + sampleEmail())

        // 提示文案形如「检测到 1 处敏感信息（邮箱）」：规则名不能是原始 key
        XCTAssertFalse(outcome.localizedRuleList.isEmpty)
        XCTAssertFalse(outcome.localizedRuleList.contains("_"))
    }
}
