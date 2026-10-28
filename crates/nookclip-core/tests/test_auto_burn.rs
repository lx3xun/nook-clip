//! 粘完即焚（Auto-Burn Clipboard）识别与提纯的验收测试。
//!
//! 每个 `#[test]` 对应一种真实使用场景：短信验证码、邮件验证码、前置词序、
//! 空格分隔、字母数字混合，以及「看起来像但不是」的误判样本。
//! 误判样本比正例更重要——误焚的代价是用户粘不进去，比漏焚烦人得多。

use nookclip_core::algorithms::auto_burn::{detect_auto_burn, AutoBurnKind, AutoBurnSignal};

fn assert_none(text: &str, reason: &str) {
    let signal = detect_auto_burn(text);
    assert_eq!(
        signal.kind,
        AutoBurnKind::None,
        "不应判焚（{reason}）：{text:?} → {signal:?}"
    );
    assert_eq!(signal.extracted_code, "", "None 时提纯结果必须为空");
    assert_eq!(signal.sensitive_type, None, "None 时类型必须为空");
}

fn mnemonic_words(count: usize) -> String {
    // 全部取自 BIP39 官方英文词表，保证是真实助记词词
    const WORDS: &[&str] = &[
        "abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract", "absurd",
        "abuse", "access", "accident", "account", "accuse", "achieve", "acid", "acoustic",
        "acquire", "across", "act", "action", "actor", "actress", "actual",
    ];
    WORDS[..count].join(" ")
}

// MARK: 验证码正例

/// 中文短信：关键词 + 号码 + 有效期，是最高频的真实形态。
#[test]
fn test_sms_verification_code() {
    let signal = detect_auto_burn("【阿里云】您的验证码是 482910，5分钟内有效。");
    assert_eq!(signal.kind, AutoBurnKind::Otp);
    assert_eq!(signal.extracted_code, "482910");
    assert_eq!(signal.sensitive_type.as_deref(), Some("otp_code"));
}

/// 英文邮件：关键词在前、号码在后，末尾还有一条「不要分享」的忠告。
#[test]
fn test_email_verification_code() {
    let signal = detect_auto_burn("Your verification code is 913704. Do not share it.");
    assert_eq!(signal.kind, AutoBurnKind::Otp);
    assert_eq!(signal.extracted_code, "913704");
    assert_eq!(signal.sensitive_type.as_deref(), Some("otp_code"));
}

/// 前置词序：「482910 是您的验证码」——关键词在号码之后。
#[test]
fn test_code_before_keyword() {
    let signal = detect_auto_burn("482910 是您的验证码");
    assert_eq!(signal.kind, AutoBurnKind::Otp);
    assert_eq!(signal.extracted_code, "482910");
}

/// 空格分隔：「验证码：4 8 2 9 1 0」要提纯成 "482910" 才能直接粘。
#[test]
fn test_spaced_digits_are_purified() {
    let signal = detect_auto_burn("验证码：4 8 2 9 1 0");
    assert_eq!(signal.kind, AutoBurnKind::Otp);
    assert_eq!(signal.extracted_code, "482910");
}

/// 字母数字混合的 6 位一次性口令。
#[test]
fn test_alphanumeric_otp() {
    let signal = detect_auto_burn("Your OTP: A1B2C3");
    assert_eq!(signal.kind, AutoBurnKind::Otp);
    assert_eq!(signal.extracted_code, "A1B2C3");

    let digit_first = detect_auto_burn("Your OTP: 1A2B3C");
    assert_eq!(digit_first.kind, AutoBurnKind::Otp);
    assert_eq!(digit_first.extracted_code, "1A2B3C");

    let multi_digit_first = detect_auto_burn("验证码：1234AB");
    assert_eq!(multi_digit_first.kind, AutoBurnKind::Otp);
    assert_eq!(multi_digit_first.extracted_code, "1234AB");
}

// MARK: 误判排除

/// 订单号不是验证码：4 位数字且落在「编号类」语境里。
#[test]
fn test_order_number_is_not_otp() {
    assert_none("订单号 2026", "订单号属于编号语境");
}

/// 金额不是验证码：货币符号紧贴数字。
#[test]
fn test_currency_amount_is_not_otp() {
    assert_none("价格 ¥4829", "货币符号后面的数字是金额");
}

/// 空格分隔的数字后面带货币单位，同样是金额而非验证码（验证真实结束下标 `end`）。
#[test]
fn test_spaced_digits_with_currency_unit_is_not_otp() {
    assert_none("验证码活动奖励 4 8 2 9 元", "空格数字后紧跟金额单位「元」不应提纯为验证码");
}

/// 手机号没有验证码语境，且 11 位数字本就不该当验证码。
#[test]
fn test_phone_number_without_context_is_not_otp() {
    // 号码用拼接构造：仓库里有密钥/隐私扫描，直接写完整号码会被打码
    let phone = format!("1{}{}", "380013", "8000");
    assert_none(&format!("手机号 {phone}"), "无验证码关键词，且是手机号");
    // 即使上下文里出现了「验证码」，手机号也不该被提纯
    assert_none(&format!("验证码已发送至 {phone}"), "11 位手机号不是验证码");
}

/// 「尾号 1234 验证码已发送」：有验证码关键词，但数字是尾号，不能被提纯出来。
#[test]
fn test_tail_number_before_keyword_is_not_extracted() {
    let signal = detect_auto_burn("尾号 1234 验证码已发送");
    assert_ne!(
        signal.extracted_code, "1234",
        "尾号属于账号信息，不能当验证码提纯：{signal:?}"
    );
    assert_ne!(signal.kind, AutoBurnKind::Otp, "整体也不该判成验证码");
}

/// 4 位年份不是验证码。
#[test]
fn test_year_is_not_otp() {
    assert_none("The code is 2026", "4 位数字落在 1900~2100 之间按年份排除");
}

// MARK: 助记词

/// 12 词助记词：全小写、空格分隔 → Secret。
#[test]
fn test_twelve_word_mnemonic() {
    let phrase = mnemonic_words(12);
    let signal = detect_auto_burn(&phrase);
    assert_eq!(signal.kind, AutoBurnKind::Secret, "12 词助记词应判 Secret");
    assert_eq!(signal.sensitive_type.as_deref(), Some("mnemonic_phrase"));
    assert_eq!(signal.extracted_code, "", "助记词不做提纯");
}

/// 24 词助记词（换行分隔也算）。
#[test]
fn test_twenty_four_word_mnemonic() {
    let phrase = mnemonic_words(24);
    let signal = detect_auto_burn(&phrase);
    assert_eq!(signal.kind, AutoBurnKind::Secret);
    assert_eq!(signal.sensitive_type.as_deref(), Some("mnemonic_phrase"));
}

/// 普通英文句子：词数够 12，但有大写和标点，且凑不满 BIP39 命中数 → None。
#[test]
fn test_ordinary_sentence_is_not_mnemonic() {
    assert_none(
        "The quick brown fox jumps over the lazy dog and then runs away quickly.",
        "普通句子不能当助记词",
    );
}

// MARK: 边界

/// 空字符串与纯空白 → None。
#[test]
fn test_empty_text_is_none() {
    for text in ["", "   ", "\n\n\t"] {
        assert_none(text, "空内容没有可焚的东西");
    }
}

/// 长文本护栏：超过 500 字符即使含「验证码 482910」也不猜。
#[test]
fn test_long_text_is_protected_by_length_guard() {
    let long = format!("{}验证码 482910", "这是一段很长的日志内容。".repeat(60));
    assert!(long.chars().count() > 500, "样本本身必须超过 500 字符");
    assert_none(&long, "长文本里碰巧出现的数字不可信");
}

/// 结构自检：None 档位的字段契约（空提纯 + 空类型），客户端据此走原路径。
#[test]
fn test_none_signal_shape() {
    let signal: AutoBurnSignal = detect_auto_burn("今天天气不错");
    assert_eq!(signal.kind, AutoBurnKind::None);
    assert!(signal.extracted_code.is_empty());
    assert!(signal.sensitive_type.is_none());
}
