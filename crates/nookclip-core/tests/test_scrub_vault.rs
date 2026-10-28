//! T003 — `algorithms::scrub` 脱敏 / 还原 / 会话池行为测试。
//!
//! 覆盖面：20 类规则命中、校验位算法（Luhn / ISO 7064 / IBAN MOD-97）、
//! 同值同号、标签不嵌套、命中区间归并与优先级、外部 NLP 区间边界安全、
//! 自定义规则（字面量 / 正则 / 非法正则）、会话池 TTL 与 LRU 上限、
//! 还原计数与幂等性。
//!
//! 说明：所有敏感样本都在运行时用 `concat!` / `format!` 现场拼装，
//! 让仓库里不出现可直接使用的密钥或真实证件号，也让样本更易审查。

use nookclip_core::algorithms::scrub::{
    active_vault_count, clear_vault, count_restorable_placeholders,
    count_restorable_placeholders_at, default_enabled_rule_keys, restore_text, restore_text_at,
    scan_text, scrub_text, scrub_text_at, CustomScrubRule, ExternalEntitySpan, ScrubConfig,
    DEFAULT_SESSION_TTL_SECONDS, MAX_VAULT_ENTRIES,
};
use std::sync::Mutex;

/// 全局会话池是进程级单例，测试必须串行执行。
static TEST_LOCK: Mutex<()> = Mutex::new(());

struct TestGuard {
    _lock: std::sync::MutexGuard<'static, ()>,
}

/// 每个测试开头调用：串行化 + 清空会话池，保证互不污染。
fn setup() -> TestGuard {
    let lock = TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    clear_vault();
    TestGuard { _lock: lock }
}

fn config() -> ScrubConfig {
    ScrubConfig::default()
}

fn s(parts: &[&str]) -> String {
    parts.concat()
}

// --- 现场拼装的样本 ---------------------------------------------------------

fn email() -> String {
    s(&["alice", "@", "example", ".", "com"])
}

fn email2() -> String {
    s(&["bob", "@", "corp", ".", "example", ".", "com"])
}

fn phone_cn() -> String {
    s(&["1", "38", "0013", "8000"])
}

fn api_key() -> String {
    s(&["sk", "-proj-", "T3BlbkFJ", "a1b2c3d4e5f6", "g7h8i9j0k1l2"])
}

fn aws_key() -> String {
    s(&["AKIA", "IOSFODNN7EXAMPLE"])
}

fn github_token() -> String {
    s(&["ghp", "_", "aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"])
}

fn private_key_block() -> String {
    let head = s(&["-----BEGIN ", "RSA PRIVATE KEY-----"]);
    let tail = s(&["-----END ", "RSA PRIVATE KEY-----"]);
    format!(
        "{}\n{}\n{}\n{}",
        head, "MIIEowIBAAKCAQEAq1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6", "q7r8s9t0u1v2w3x4y5z6", tail
    )
}

fn db_password() -> String {
    s(&["S3cr3t", "P@ss", "w0rd"])
}

fn id_card_valid() -> String {
    // 110105 + 19491231 + 002（17 位基数），校验位按 ISO 7064 MOD 11-2 现场计算
    let base = s(&["110105", "194912", "31", "002"]);
    let weights = [7u32, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
    let check_chars: Vec<char> = "10X98765432".chars().collect();
    let sum: u32 = base
        .chars()
        .enumerate()
        .map(|(i, c)| c.to_digit(10).unwrap_or(0) * weights[i])
        .sum();
    format!("{}{}", base, check_chars[(sum % 11) as usize])
}

fn bank_card_valid() -> String {
    // 4111 1111 1111 111x：前缀固定，末位按 Luhn 现场计算
    let base = s(&["4111", "1111", "1111", "111"]);
    for d in 0..10u32 {
        let candidate = format!("{}{}", base, d);
        if luhn_ok(&candidate) {
            return candidate;
        }
    }
    unreachable!("there is always a Luhn check digit")
}

fn luhn_ok(card: &str) -> bool {
    let mut sum = 0u32;
    let mut double = false;
    for c in card.chars().rev() {
        let Some(mut d) = c.to_digit(10) else {
            return false;
        };
        if double {
            d *= 2;
            if d > 9 {
                d -= 9;
            }
        }
        sum += d;
        double = !double;
    }
    sum % 10 == 0
}

fn iban_valid() -> String {
    // GB + 校验位 + BBAN；校验位按 ISO 13616 MOD-97-10 现场计算
    let country = "GB";
    let bban = s(&["WEST", "1234", "5698", "7654", "32"]);
    let mut numeric = String::new();
    for c in bban.chars() {
        if let Some(d) = c.to_digit(10) {
            numeric.push_str(&d.to_string());
        } else {
            numeric.push_str(&(c as u32 - 'A' as u32 + 10).to_string());
        }
    }
    for c in country.chars() {
        numeric.push_str(&(c as u32 - 'A' as u32 + 10).to_string());
    }
    numeric.push_str("00");
    let mut rem = 0u32;
    for c in numeric.chars() {
        rem = (rem * 10 + c.to_digit(10).unwrap()) % 97;
    }
    let check = 98 - rem;
    format!("{}{:02}{}", country, check, bban)
}

fn username() -> String {
    s(&["kai", "chen"])
}

// ---------------------------------------------------------------------------
// 基础行为
// ---------------------------------------------------------------------------

#[test]
fn tests_run_serialized_and_vault_starts_empty() {
    let _guard = setup();
    assert_eq!(active_vault_count(), 0);
    assert_eq!(default_enabled_rule_keys().len(), 19);
}

#[test]
fn scrub_and_restore_roundtrip_preserves_text() {
    let _guard = setup();
    let mail = email();
    let text = format!("联系 {} 确认上线时间", mail);
    let result = scrub_text(&text, &config(), &[]);
    assert!(result.has_replacements);
    assert_eq!(result.scrubbed_text, "联系 <EMAIL_1> 确认上线时间");

    let restored = restore_text(&result.scrubbed_text);
    assert_eq!(restored.restored_text, text);
    assert_eq!(restored.restored_count, 1);
}

#[test]
fn plain_text_is_untouched() {
    let _guard = setup();
    let text = "这是一段完全普通的说明文字，没有任何敏感信息。";
    let result = scrub_text(text, &config(), &[]);
    assert!(!result.has_replacements);
    assert_eq!(result.scrubbed_text, text);
    assert!(result.replacements.is_empty());
}

// ---------------------------------------------------------------------------
// 同值同号
// ---------------------------------------------------------------------------

#[test]
fn same_value_same_number_different_value_increments() {
    let _guard = setup();
    let (a, b) = (email(), email2());
    let text = format!("{} 和 {} 还有 {}", a, a, b);
    let result = scrub_text(&text, &config(), &[]);
    assert_eq!(result.scrubbed_text, "<EMAIL_1> 和 <EMAIL_1> 还有 <EMAIL_2>");

    let email_items: Vec<_> = result
        .replacements
        .iter()
        .filter(|r| r.rule_key == "email")
        .collect();
    assert_eq!(email_items.len(), 2);
    let first = email_items
        .iter()
        .find(|r| r.placeholder == "<EMAIL_1>")
        .expect("<EMAIL_1> must exist");
    assert_eq!(first.count, 2);
}

#[test]
fn same_value_numbering_persists_across_calls_in_session() {
    let _guard = setup();
    let (a, b) = (email(), email2());

    let first = scrub_text(&a, &config(), &[]);
    assert_eq!(first.scrubbed_text, "<EMAIL_1>");

    // 第二次调用：同一值继续用 <EMAIL_1>，新值用 <EMAIL_2>
    let second = scrub_text(&format!("{} and {}", a, b), &config(), &[]);
    assert_eq!(second.scrubbed_text, "<EMAIL_1> and <EMAIL_2>");

    // 还原能把两次的值都还原出来
    let restored = restore_text(&second.scrubbed_text);
    assert_eq!(restored.restored_text, format!("{} and {}", a, b));
    assert_eq!(restored.restored_count, 2);
}

// ---------------------------------------------------------------------------
// 校验位算法
// ---------------------------------------------------------------------------

#[test]
fn valid_id_card_is_scrubbed() {
    let _guard = setup();
    let id = id_card_valid();
    let text = format!("身份证 {} 请核对", id);
    let result = scrub_text(&text, &config(), &[]);
    assert!(
        result.scrubbed_text.contains("<ID_CARD_1>"),
        "got: {}",
        result.scrubbed_text
    );
}

#[test]
fn invalid_id_card_checksum_is_not_scrubbed() {
    let _guard = setup();
    let mut id = id_card_valid();
    // 翻转校验位，必然非法
    let flipped = if id.ends_with('1') { "2" } else { "1" };
    id.replace_range(17..18, flipped);
    let result = scrub_text(&format!("身份证 {} 请核对", id), &config(), &[]);
    assert!(
        !result.scrubbed_text.contains("<ID_CARD_"),
        "checksum-invalid id must be kept, got: {}",
        result.scrubbed_text
    );
}

#[test]
fn valid_bank_card_luhn_is_scrubbed() {
    let _guard = setup();
    let card = bank_card_valid();
    let result = scrub_text(&format!("卡号 {} 请勿外传", card), &config(), &[]);
    assert!(
        result.scrubbed_text.contains("<BANK_CARD_1>"),
        "got: {}",
        result.scrubbed_text
    );
}

#[test]
fn invalid_bank_card_luhn_is_not_scrubbed() {
    let _guard = setup();
    let mut card = bank_card_valid();
    let last = card.pop().unwrap();
    let flipped = if last == '9' { '8' } else { '9' };
    card.push(flipped);
    let result = scrub_text(&format!("卡号 {} 请勿外传", card), &config(), &[]);
    assert!(
        !result.scrubbed_text.contains("<BANK_CARD_"),
        "Luhn-invalid card must be kept, got: {}",
        result.scrubbed_text
    );
}

#[test]
fn valid_iban_is_scrubbed() {
    let _guard = setup();
    let iban = iban_valid();
    let result = scrub_text(&format!("账户 {} 已到账", iban), &config(), &[]);
    assert!(
        result.scrubbed_text.contains("<IBAN_1>"),
        "got: {}",
        result.scrubbed_text
    );
}

#[test]
fn invalid_iban_is_not_scrubbed() {
    let _guard = setup();
    let mut iban = iban_valid();
    let check: u32 = iban[2..4].parse().unwrap();
    let broken = format!("{}{:02}{}", &iban[..2], (check % 98) + 1, &iban[4..]);
    iban = broken;
    let result = scrub_text(&format!("账户 {} 已到账", iban), &config(), &[]);
    assert!(
        !result.scrubbed_text.contains("<IBAN_"),
        "MOD-97-invalid IBAN must be kept, got: {}",
        result.scrubbed_text
    );
}

// ---------------------------------------------------------------------------
// 凭据类
// ---------------------------------------------------------------------------

#[test]
fn api_keys_are_scrubbed() {
    let _guard = setup();
    let (o, a, g) = (api_key(), aws_key(), github_token());
    let text = format!("OPENAI={}\nAWS={}\nGH={}\n", o, a, g);
    let result = scrub_text(&text, &config(), &[]);
    assert!(
        result.scrubbed_text.contains("<API_KEY_1>"),
        "got: {}",
        result.scrubbed_text
    );
    assert!(result.scrubbed_text.contains("<API_KEY_2>"));
    assert!(result.scrubbed_text.contains("<API_KEY_3>"));
    assert!(!result.scrubbed_text.contains(&o));
    assert!(!result.scrubbed_text.contains(&a));
    assert!(!result.scrubbed_text.contains(&g));
}

#[test]
fn private_key_block_is_scrubbed_as_one_unit() {
    let _guard = setup();
    let block = private_key_block();
    let result = scrub_text(&block, &config(), &[]);
    assert_eq!(
        result.scrubbed_text, "<PRIVATE_KEY_1>",
        "whole PEM block must become one placeholder"
    );
    assert!(!result.scrubbed_text.contains("MIIEowIBAAKCAQEA"));
}

#[test]
fn connection_string_password_is_scrubbed_without_nesting() {
    let _guard = setup();
    let pwd = db_password();
    let text = format!(
        "DATABASE_URL=postgres://admin:{}@db.internal.example.com:5432/prod",
        pwd
    );
    let result = scrub_text(&text, &config(), &[]);
    assert!(
        result.scrubbed_text.contains("<SECRET_1>"),
        "got: {}",
        result.scrubbed_text
    );
    // 关键不变量：绝不产生嵌套破损标签
    assert!(!result.scrubbed_text.contains("<SECRET_<"));
    assert!(!result.scrubbed_text.contains(&pwd));
}

// ---------------------------------------------------------------------------
// 网络与设备
// ---------------------------------------------------------------------------

#[test]
fn ip_address_scrubbed_but_loopback_and_version_kept() {
    let _guard = setup();
    let text = "server 192.168.31.77 ok, local 127.0.0.1 ok, ver v1.2.3.4 ok";
    let result = scrub_text(text, &config(), &[]);
    assert!(
        result.scrubbed_text.contains("<IP_1>"),
        "got: {}",
        result.scrubbed_text
    );
    assert!(
        result.scrubbed_text.contains("127.0.0.1"),
        "loopback must be kept"
    );
    assert!(
        result.scrubbed_text.contains("v1.2.3.4"),
        "version must be kept"
    );
}

#[test]
fn mac_address_is_scrubbed() {
    let _guard = setup();
    let text = "网卡 3c:22:fb:8a:1d:04 已绑定";
    let result = scrub_text(text, &config(), &[]);
    assert!(
        result.scrubbed_text.contains("<MAC_ADDR_1>"),
        "got: {}",
        result.scrubbed_text
    );
}

#[test]
fn home_username_keeps_path_prefix() {
    let _guard = setup();
    let user = username();
    let text = format!("cat /Users/{}/.ssh/id_rsa", user);
    let result = scrub_text(&text, &config(), &[]);
    assert_eq!(
        result.scrubbed_text, "cat /Users/<USER_1>/.ssh/id_rsa",
        "path prefix must be preserved"
    );
}

#[test]
fn shared_home_directory_is_not_an_identity() {
    let _guard = setup();
    let result = scrub_text("open /Users/Shared/data", &config(), &[]);
    assert!(
        !result.scrubbed_text.contains("<USER_"),
        "public dir must be kept, got: {}",
        result.scrubbed_text
    );
}

#[test]
fn cloud_bucket_is_scrubbed() {
    let _guard = setup();
    let result = scrub_text("上传到 s3://acme-prod-logs/2024", &config(), &[]);
    assert!(
        result.scrubbed_text.contains("<CLOUD_BUCKET_1>"),
        "got: {}",
        result.scrubbed_text
    );
}

#[test]
fn serial_number_is_scrubbed() {
    let _guard = setup();
    let result = scrub_text("SN: C02XK1ABJGH5 报修", &config(), &[]);
    assert!(
        result.scrubbed_text.contains("<SERIAL_1>"),
        "got: {}",
        result.scrubbed_text
    );
}

// ---------------------------------------------------------------------------
// PII
// ---------------------------------------------------------------------------

#[test]
fn phone_ssn_and_birth_date_are_scrubbed() {
    let _guard = setup();
    let phone = phone_cn();
    let ssn = s(&["123", "-45", "-6789"]);
    let text = format!("电话 {}，SSN {}，生日 1949-12-31。", phone, ssn);
    let result = scrub_text(&text, &config(), &[]);
    assert!(
        result.scrubbed_text.contains("<PHONE_1>"),
        "got: {}",
        result.scrubbed_text
    );
    assert!(
        result.scrubbed_text.contains("<SSN_1>"),
        "got: {}",
        result.scrubbed_text
    );
    assert!(
        result.scrubbed_text.contains("<BIRTH_DATE_1>"),
        "got: {}",
        result.scrubbed_text
    );
}

#[test]
fn invalid_ssn_area_is_not_scrubbed() {
    let _guard = setup();
    let bad = s(&["666", "-12", "-3456"]);
    let result = scrub_text(&format!("SSN {} 无效", bad), &config(), &[]);
    assert!(
        !result.scrubbed_text.contains("<SSN_"),
        "invalid SSN area must be kept, got: {}",
        result.scrubbed_text
    );
}

#[test]
fn iso_timestamp_date_part_is_not_treated_as_birth_date() {
    let _guard = setup();
    let result = scrub_text("created 2024-01-15T10:30:00Z by system", &config(), &[]);
    assert!(
        !result.scrubbed_text.contains("<BIRTH_DATE_"),
        "ISO timestamp must be kept, got: {}",
        result.scrubbed_text
    );
}

#[test]
fn already_masked_token_is_not_double_scrubbed() {
    let _guard = setup();
    // 已存在的占位符形态必须原样保留，否则会出现嵌套标签
    let text = "template <EMAIL_1> stays";
    let result = scrub_text(text, &config(), &[]);
    assert_eq!(result.scrubbed_text, text);
}

// ---------------------------------------------------------------------------
// 外部 NLP 区间
// ---------------------------------------------------------------------------

#[test]
fn external_entity_spans_are_scrubbed() {
    let _guard = setup();
    let name = "张伟";
    let address = "杭州西湖区";
    let text = format!("{}明天来{}", name, address);
    let spans = vec![
        ExternalEntitySpan {
            start_byte: 0,
            end_byte: name.len() as u32,
            rule_key: "person_name".to_string(),
        },
        ExternalEntitySpan {
            start_byte: (name.len() + "明天来".len()) as u32,
            end_byte: (name.len() + "明天来".len() + address.len()) as u32,
            rule_key: "address".to_string(),
        },
    ];
    let result = scrub_text(&text, &config(), &spans);
    assert_eq!(result.scrubbed_text, "<NAME_1>明天来<ADDRESS_1>");
}

#[test]
fn non_char_boundary_external_span_is_safely_ignored() {
    let _guard = setup();
    let text = "张伟";
    // 1 落在三字节 UTF-8 字符中间：必须忽略而不是 panic
    let spans = vec![ExternalEntitySpan {
        start_byte: 1,
        end_byte: 3,
        rule_key: "person_name".to_string(),
    }];
    let result = scrub_text(text, &config(), &spans);
    assert_eq!(result.scrubbed_text, text);
}

#[test]
fn external_span_cannot_inject_arbitrary_rule() {
    let _guard = setup();
    let text = "hello world";
    // 外部只允许 person_name / address，不能借道注入 email 之类
    let spans = vec![ExternalEntitySpan {
        start_byte: 0,
        end_byte: 5,
        rule_key: "email".to_string(),
    }];
    let result = scrub_text(text, &config(), &spans);
    assert_eq!(result.scrubbed_text, text);
}

#[test]
fn disabled_rule_is_skipped() {
    let _guard = setup();
    let mut cfg = config();
    cfg.enabled_builtin_rules = vec!["email".to_string()];
    let text = format!("{} 和 192.168.1.9", email());
    let result = scrub_text(&text, &cfg, &[]);
    assert!(result.scrubbed_text.contains("<EMAIL_1>"));
    assert!(result.scrubbed_text.contains("192.168.1.9"), "ip disabled");
}

/// 空启用列表 = 一条都不脱敏（严格白名单）。
///
/// 这条曾经是相反的语义（空 = 默认全集），导致用户「关掉所有规则」后
/// 反而全开——隐私开关的极端态与直觉相反，是真缺陷。
#[test]
fn empty_enabled_list_disables_everything() {
    let _guard = setup();
    let mut cfg = config();
    cfg.enabled_builtin_rules = Vec::new();
    let text = format!("{} 电话 {} 卡号 {}", email(), phone_cn(), bank_card_valid());
    let result = scrub_text(&text, &cfg, &[]);
    assert!(!result.has_replacements, "空列表不应命中任何规则");
    assert_eq!(result.scrubbed_text, text, "原文必须原样返回");
}

/// `ScrubConfig::default()` 必须是全集启用，保证「默认全开」的体验
#[test]
fn default_config_enables_all_builtin_rules() {
    let cfg = ScrubConfig::default();
    let expected: Vec<String> = default_enabled_rule_keys()
        .into_iter()
        .map(str::to_string)
        .collect();
    assert_eq!(cfg.enabled_builtin_rules, expected);
    assert_eq!(cfg.enabled_builtin_rules.len(), 19);
}

// ---------------------------------------------------------------------------
// 自定义规则
// ---------------------------------------------------------------------------

fn custom_rule(pattern: &str, tag: &str, is_regex: bool) -> CustomScrubRule {
    CustomScrubRule {
        id: "custom-1".to_string(),
        name: "测试规则".to_string(),
        is_regex,
        pattern: pattern.to_string(),
        placeholder_tag: tag.to_string(),
        enabled: true,
    }
}

#[test]
fn custom_literal_rule_is_scrubbed() {
    let _guard = setup();
    let mut cfg = config();
    cfg.custom_rules = vec![custom_rule("杭州星辰科技", "company", false)];
    let result = scrub_text("杭州星辰科技有限公司", &cfg, &[]);
    assert_eq!(result.scrubbed_text, "<COMPANY_1>有限公司");
}

#[test]
fn custom_regex_rule_is_scrubbed() {
    let _guard = setup();
    let mut cfg = config();
    cfg.custom_rules = vec![custom_rule(r"TICKET-\d{5}", "TICKET", true)];
    let result = scrub_text("见 TICKET-04219 与 TICKET-04220", &cfg, &[]);
    assert_eq!(result.scrubbed_text, "见 <TICKET_1> 与 <TICKET_2>");
}

#[test]
fn invalid_custom_regex_is_silently_ignored() {
    let _guard = setup();
    let mut cfg = config();
    // 未闭合分组：用户可能正在输入半截表达式
    cfg.custom_rules = vec![custom_rule("([未闭合", "BROKEN", true)];
    let text = format!("普通文本 {}", email());
    let result = scrub_text(&text, &cfg, &[]);
    assert!(result.scrubbed_text.contains("<EMAIL_1>"));
}

#[test]
fn disabled_custom_rule_is_skipped() {
    let _guard = setup();
    let mut cfg = config();
    let mut rule = custom_rule("星辰", "company", false);
    rule.enabled = false;
    cfg.custom_rules = vec![rule];
    let result = scrub_text("星辰科技", &cfg, &[]);
    assert_eq!(result.scrubbed_text, "星辰科技");
}

#[test]
fn empty_placeholder_tag_falls_back_to_custom() {
    let _guard = setup();
    let mut cfg = config();
    cfg.custom_rules = vec![custom_rule("机密", "  ", false)];
    let result = scrub_text("这是机密文件", &cfg, &[]);
    assert_eq!(result.scrubbed_text, "这是<CUSTOM_1>文件");
}

// ---------------------------------------------------------------------------
// 区间归并
// ---------------------------------------------------------------------------

#[test]
fn overlapping_hits_do_not_produce_broken_tags() {
    let _guard = setup();
    // 邮箱里的 `alice@example` 也是 user@host 形态：必须只保留一个命中
    let mail = email();
    let result = scrub_text(&mail, &config(), &[]);
    assert_eq!(result.scrubbed_text, "<EMAIL_1>");
    assert_eq!(result.scrubbed_text.matches('<').count(), 1);
    assert_eq!(result.scrubbed_text.matches('>').count(), 1);
}

#[test]
fn no_placeholder_ever_contains_another_placeholder() {
    let _guard = setup();
    let text = format!(
        "user=deploy@10.0.3.44\ndb=mysql://root:{}@10.0.3.44:3306/app\nmail: {}\n",
        db_password(),
        email()
    );
    let result = scrub_text(&text, &config(), &[]);
    // 任何 `<` 之后到 `>` 之间只应有大写字母 / 数字 / 下划线
    let mut inside = false;
    for ch in result.scrubbed_text.chars() {
        match ch {
            '<' => {
                assert!(
                    !inside,
                    "nested placeholder found: {}",
                    result.scrubbed_text
                );
                inside = true;
            }
            '>' => {
                assert!(inside, "stray '>' in {}", result.scrubbed_text);
                inside = false;
            }
            c if inside => assert!(
                c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_',
                "illegal char {:?} in placeholder: {}",
                c,
                result.scrubbed_text
            ),
            _ => {}
        }
    }
    assert!(!inside, "unclosed placeholder: {}", result.scrubbed_text);
}

// ---------------------------------------------------------------------------
// 会话池
// ---------------------------------------------------------------------------

#[test]
fn vault_count_tracks_distinct_values() {
    let _guard = setup();
    let text = format!("{} {} 192.168.1.9", email(), email2());
    scrub_text(&text, &config(), &[]);
    assert_eq!(active_vault_count(), 3);
}

#[test]
fn clear_vault_removes_all_mappings() {
    let _guard = setup();
    let result = scrub_text(&email(), &config(), &[]);
    assert_eq!(active_vault_count(), 1);

    clear_vault();
    assert_eq!(active_vault_count(), 0);

    // 池已清空：占位符无法还原，原文占位符保留
    let restored = restore_text(&result.scrubbed_text);
    assert_eq!(restored.restored_text, "<EMAIL_1>");
    assert_eq!(restored.restored_count, 0);
}

#[test]
fn restore_is_idempotent_for_unmatched_placeholders() {
    let _guard = setup();
    let restored = restore_text("<EMAIL_99> and <FOO_1>");
    assert_eq!(restored.restored_text, "<EMAIL_99> and <FOO_1>");
    assert_eq!(restored.restored_count, 0);
}

#[test]
fn count_restorable_only_counts_live_placeholders() {
    let _guard = setup();
    let scrubbed = scrub_text(&format!("{} and {}", email(), email2()), &config(), &[]).scrubbed_text;
    assert_eq!(count_restorable_placeholders(&scrubbed), 2);

    // 混入未登记的占位符不计数
    let mixed = format!("{} <EMAIL_99>", scrubbed);
    assert_eq!(count_restorable_placeholders(&mixed), 2);
}

#[test]
fn vault_is_bounded_by_lru_limit() {
    let _guard = setup();
    for i in 0..(MAX_VAULT_ENTRIES + 40) {
        scrub_text(&format!("user{}@{}.{}", i, "example", "com"), &config(), &[]);
    }
    assert_eq!(
        active_vault_count() as usize,
        MAX_VAULT_ENTRIES,
        "vault must stay bounded"
    );
}

#[test]
fn aged_entries_expire_via_ttl() {
    let _guard = setup();
    // t=1000 脱敏，TTL 默认 1800
    let result = scrub_text_at(&email(), &config(), &[], 1000);
    assert_eq!(result.scrubbed_text, "<EMAIL_1>");

    // 空闲已到期：惰性清理后池为空，占位符不再可还原
    let later = 1000 + DEFAULT_SESSION_TTL_SECONDS;
    let restored = restore_text_at(&result.scrubbed_text, later);
    assert_eq!(restored.restored_text, "<EMAIL_1>");
    assert_eq!(restored.restored_count, 0);
    assert_eq!(active_vault_count(), 0);
}

#[test]
fn zero_ttl_disables_persistence_across_calls() {
    let _guard = setup();
    let mut cfg = config();
    cfg.session_ttl_seconds = 0;

    let first = scrub_text(&email(), &cfg, &[]);
    assert_eq!(first.scrubbed_text, "<EMAIL_1>");

    // ttl=0：下一次调用先清空，同值重新编号为 <EMAIL_1>（而非 <EMAIL_2>）
    let second = scrub_text(&email2(), &cfg, &[]);
    assert_eq!(second.scrubbed_text, "<EMAIL_1>");
}

#[test]
fn restore_result_reports_count_for_repeated_placeholders() {
    let _guard = setup();
    let mail = email();
    let text = format!("{} {} {}", mail, mail, mail);
    let scrubbed = scrub_text(&text, &config(), &[]).scrubbed_text;
    assert_eq!(scrubbed, "<EMAIL_1> <EMAIL_1> <EMAIL_1>");

    let restored = restore_text(&scrubbed);
    assert_eq!(restored.restored_text, text);
    assert_eq!(restored.restored_count, 3);
}

// ---------------------------------------------------------------------------
// 预检扫描（预览区提示用 · 零副作用）
// ---------------------------------------------------------------------------

#[test]
fn scan_counts_hits_without_touching_vault() {
    let _guard = setup();
    let text = format!("{} and {}", email(), email2());

    let scan = scan_text(&text, &config(), &[]);
    assert_eq!(scan.hit_count, 2);
    assert_eq!(scan.rule_keys, vec!["email".to_string()]);
    // 关键不变量：扫描不分配占位符，会话池必须保持为空
    assert_eq!(active_vault_count(), 0);

    // 扫描后按 ⌃⇧⏎ 不该出现「可还原」提示
    assert_eq!(count_restorable_placeholders("<EMAIL_1>"), 0);
}

#[test]
fn scan_returns_empty_for_plain_text() {
    let _guard = setup();
    let scan = scan_text("just a normal sentence with nothing secret", &config(), &[]);
    assert_eq!(scan.hit_count, 0);
    assert!(scan.rule_keys.is_empty());
    assert_eq!(active_vault_count(), 0);
}

#[test]
fn scan_respects_disabled_rules() {
    let _guard = setup();
    // 用 IP 做样本：邮箱关掉后仍会被 user_at_host 规则兜住（`a@b.c` 形态），
    // 拿它测「关闭生效」会测到另一条规则上，得不到干净的对照
    let text = "10.0.3.44";

    let mut cfg = config();
    cfg.enabled_builtin_rules = default_enabled_rule_keys()
        .into_iter()
        .filter(|k| *k != "ip_address")
        .map(str::to_string)
        .collect();
    let scan = scan_text(text, &cfg, &[]);
    assert_eq!(scan.hit_count, 0, "关闭 IP 规则后不应命中");

    let scan_on = scan_text(text, &config(), &[]);
    assert_eq!(scan_on.hit_count, 1);
    assert_eq!(scan_on.rule_keys, vec!["ip_address".to_string()]);
}

#[test]
fn scan_dedups_rule_keys_in_first_seen_order() {
    let _guard = setup();
    let text = format!("{} {} 10.0.3.44", email(), email2());
    let scan = scan_text(&text, &config(), &[]);
    assert_eq!(scan.hit_count, 3);
    assert_eq!(
        scan.rule_keys,
        vec!["email".to_string(), "ip_address".to_string()]
    );
}

// ---------------------------------------------------------------------------
// 性能与端到端
// ---------------------------------------------------------------------------

#[test]
fn ten_kilobyte_scrub_under_budget() {
    let _guard = setup();
    let mut text = String::new();
    let line = format!("contact {} or 192.168.1.9 for details. ", email());
    while text.len() < 10_240 {
        text.push_str(&line);
    }
    let started = std::time::Instant::now();
    let result = scrub_text(&text, &config(), &[]);
    let elapsed = started.elapsed();
    assert!(result.has_replacements);
    assert!(
        elapsed.as_millis() < 50,
        "10KB scrub took {:?} (budget 5ms, allowing CI slack)",
        elapsed
    );
}

#[test]
fn real_world_log_sample_roundtrip() {
    let _guard = setup();
    let (mail, user, token) = (email(), username(), api_key());
    let text = format!(
        "2024-06-15T10:30:00Z ERROR deploy failed for {}\n  host=10.0.3.44 user=kai path=/Users/{}/app\n  token={}\n",
        mail, user, token
    );
    let scrubbed = scrub_text(&text, &config(), &[]);
    assert!(scrubbed.scrubbed_text.contains("<EMAIL_1>"));
    assert!(scrubbed.scrubbed_text.contains("<IP_1>"));
    assert!(scrubbed.scrubbed_text.contains("<USER_1>"));
    assert!(scrubbed.scrubbed_text.contains("<API_KEY_1>"));
    assert!(!scrubbed.scrubbed_text.contains(&mail));
    assert!(!scrubbed.scrubbed_text.contains(&token));

    let restored = restore_text(&scrubbed.scrubbed_text);
    assert_eq!(restored.restored_text, text);
}

#[test]
fn passport_and_numeric_custom_tag_and_lru_and_ttl_work() {
    let _guard = setup();
    // 1. Passport 命中与还原
    let passport_text = "Passport: E12345678 / 护照号：G87654321 请核对";
    let res = scrub_text(passport_text, &config(), &[]);
    assert!(res.scrubbed_text.contains("<PASSPORT_1>"), "got: {}", res.scrubbed_text);
    assert_eq!(restore_text(&res.scrubbed_text).restored_text, passport_text);

    // 2. 数字开头的自定义标签 (如 2FA) 能正常脱敏并还原
    let mut cfg = config();
    cfg.custom_rules.push(CustomScrubRule {
        id: "r1".to_string(),
        name: "2FA".to_string(),
        is_regex: false,
        pattern: "OTP-998877".to_string(),
        placeholder_tag: "2FA".to_string(),
        enabled: true,
    });
    cfg.session_ttl_seconds = 300;
    let custom_res = scrub_text_at("code: OTP-998877", &cfg, &[], 1000);
    assert_eq!(custom_res.scrubbed_text, "code: <2FA_1>");
    assert_eq!(count_restorable_placeholders_at(&custom_res.scrubbed_text, 1100), 1);
    assert_eq!(
        restore_text_at(&custom_res.scrubbed_text, 1100).restored_text,
        "code: OTP-998877"
    );
    // 超过自定义 300s TTL（小于默认 1800s）后应过期不可还原
    assert_eq!(count_restorable_placeholders_at(&custom_res.scrubbed_text, 1500), 0);
}

#[test]
fn id_card_with_invalid_birth_date_is_rejected() {
    let _guard = setup();
    // 11010519991345001X: 13月45日，计算末位校验码使其恰好通过 ISO 7064，但因生日非法必须被拒绝
    let prefix = "11010519991345001";
    let weights = [7u32, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
    let check_chars = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];
    let sum: u32 = prefix
        .chars()
        .zip(weights.iter())
        .map(|(c, w)| c.to_digit(10).unwrap() * w)
        .sum();
    let fake_id = format!("{}{}", prefix, check_chars[(sum % 11) as usize]);
    let res = scrub_text(&format!("order {}", fake_id), &config(), &[]);
    assert!(!res.scrubbed_text.contains("<ID_CARD_"), "got: {}", res.scrubbed_text);
}

#[test]
fn user_at_host_does_not_falsely_match_package_specifiers() {
    let _guard = setup();
    let package_cases = [
        "npx rea-agents@latest setup",
        "npm i rea-agents@latest",
        "npm i react@18.2.0",
        "pnpm add lodash@4.17.21",
        "yarn add @types/node@latest",
        "bun add vue@next",
        "deno add @std/assert@1.0.0",
        "react@18.2.0",
        "tailwindcss@latest",
        "docker pull redis@sha256:1234567890abcdef",
    ];

    for cmd in package_cases {
        let scan = scan_text(cmd, &config(), &[]);
        assert_eq!(
            scan.hit_count, 0,
            "{} 不应被脱敏命中，实际命中: {:?}",
            cmd, scan.rule_keys
        );
        let scrub = scrub_text(cmd, &config(), &[]);
        assert_eq!(scrub.scrubbed_text, cmd);
    }
}

#[test]
fn user_at_host_correctly_matches_real_ssh_and_hostnames() {
    let _guard = setup();

    // 1. IP 地址主机
    let ip_target = "root@192.168.1.1";
    let res_ip = scrub_text(ip_target, &config(), &[]);
    assert_eq!(res_ip.scrubbed_text, "<USER_HOST_1>");

    // 2. 具有合法 TLD 域名的主机（邮箱规则关闭时由 user_at_host 兜底）
    clear_vault();
    let mut no_email_cfg = config();
    no_email_cfg.enabled_builtin_rules.retain(|k| k != "email");
    let domain_target = "deploy@bastion.internal";
    let res_domain = scrub_text(domain_target, &no_email_cfg, &[]);
    assert_eq!(res_domain.scrubbed_text, "<USER_HOST_1>");

    // 3. 本地回环 localhost
    clear_vault();
    let local_target = "admin@localhost";
    let res_local = scrub_text(local_target, &config(), &[]);
    assert_eq!(res_local.scrubbed_text, "<USER_HOST_1>");

    // 4. 处于远程命令（如 ssh）中的单段主机名
    clear_vault();
    let ssh_cmd = "ssh pi@raspberrypi";
    let res_ssh = scrub_text(ssh_cmd, &config(), &[]);
    assert_eq!(res_ssh.scrubbed_text, "ssh <USER_HOST_1>");

    // 5. 带有远程路径的 scp 目标
    clear_vault();
    let scp_cmd = "scp app.tar.gz admin@nas:/volume1/backup";
    let res_scp = scrub_text(scp_cmd, &config(), &[]);
    assert_eq!(res_scp.scrubbed_text, "scp app.tar.gz <USER_HOST_1>:/volume1/backup");
}
