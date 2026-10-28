//! 粘完即焚（Auto-Burn Clipboard）——识别与提纯
//!
//! 解决的问题：验证码、助记词、API Key 这类内容，只要在剪贴板里待过一次，
//! 就会被剪贴板历史原样存下来，几周后还能被翻出来；用户要的不是「粘一次就进历史」，
//! 而是「粘完就烧掉，历史里不留痕」。
//!
//! 分工：本模块只做**纯判定**——这段文本该不该焚、焚之前要不要先提纯出一串验证码；
//! 零副作用、不碰剪贴板、不写盘。真正的「标记敏感 / 不入库 / 粘贴后清空剪贴板」
//! 全部留在客户端（macOS Swift / Windows Tauri），两端共用同一套规则，避免行为漂移。
//!
//! 三类判定（严格按顺序，先命中先返回）：
//! 1. [`AutoBurnKind::Otp`]：带验证码语境的可信验证码，顺带把纯码提纯出来
//!    （短信里常写成「验证码：4 8 2 9 1 0」，直接粘整段反而错）；
//! 2. [`AutoBurnKind::Secret`]：助记词 / 恢复短语，或 `sensitive.rs` 已能识别的密钥；
//! 3. [`AutoBurnKind::None`]：普通内容，客户端原样粘贴。
//!
//! 设计取向：**宁可漏判，不可误伤**。误判的代价是用户复制一段普通文本却粘不进去；
//! 漏判的代价只是一条历史记录，用户还能手动删。所以所有规则都先收紧再放行。

use std::collections::HashSet;
use std::sync::LazyLock;

/// 验证码判定的文本长度上限（按字符数）。
///
/// 超过 500 字的段落不可能是「一条验证码短信」，更可能是日志、邮件正文或文章。
/// 长文本里随便找个 6 位数字的概率极高，必须直接放弃猜测，否则误伤率会失控。
const OTP_MAX_TEXT_CHARS: usize = 500;

/// 关键词之后允许多远的验证码（字符数）。
/// 短信里常见「验证码是 482910」「code: 913704」，40 个字符足够跨过修饰语，
/// 又不会远到串行到下一段内容里。
const OTP_WINDOW_AFTER: usize = 40;

/// 关键词之前允许多远的验证码（字符数）。
/// 只给 20 个字符，是因为「482910 是您的验证码」这种前置词序里，
/// 号码和关键词之间通常只隔一两个语气词；窗口放大只会增加误伤。
const OTP_WINDOW_BEFORE: usize = 20;

/// 助记词判定的文本长度上限。
/// 助记词最长 24 个词，4096 字符已经极其宽松；再长的文本直接跳过，
/// 避免每次粘贴都对着几 MB 内容做逐词扫描。
const MNEMONIC_MAX_TEXT_CHARS: usize = 4096;

/// 中文验证码语境关键词。
///
/// 只收「明确指向一次性验证码」的说法：`密码` 单独出现不算
/// （「密码错误」这种提示每天都在复制，焚掉就太扰民了）。
const OTP_KEYWORDS_ZH: &[&str] = &[
    "验证码",
    "校验码",
    "动态码",
    "确认码",
    "动态密码",
    "一次性密码",
    "安全码",
];

/// 英文验证码语境关键词（大小写不敏感，且要求词边界）。
const OTP_KEYWORDS_EN: &[&str] = &[
    "code",
    "otp",
    "verification",
    "passcode",
    "one-time",
    "2fa",
    "two-factor",
];

/// 出现在号码**前面**就说明这不是验证码的词。
///
/// 「尾号 1234」「订单号 2026」里的数字是账号/订单的一部分，
/// 粘它没有任何价值，焚掉反而打断了用户复制订单号的动作。
const NUMBER_CONTEXT_STOPWORDS: &[&str] = &["尾号", "后四位", "编号", "订单号", "序号", "no."];

/// 常见 BIP39 英文单词表（取词表里最高频的一段）。
///
/// 为什么要内置词表而不是「12 个英文单词就算」：普通英文句子随手就是 12 个词，
/// 只要有一点小写英文就会误焚。要求「至少 8 个词命中 BIP39 词表」后，
/// 助记词一命中一个准，普通句子几乎不可能凑够数量。
///
/// 收录范围：BIP39 官方英文词表（2048 词）的前段高频词，
/// 只放真实存在的词，宁可少收也不掺假词，否则会悄悄降低判定门槛。
const COMMON_BIP39_WORDS: &[&str] = &[
    "abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract", "absurd",
    "abuse", "access", "accident", "account", "accuse", "achieve", "acid", "acoustic", "acquire",
    "across", "act", "action", "actor", "actress", "actual", "adapt", "add", "addict", "address",
    "adjust", "admit", "adult", "advance", "advice", "aerobic", "affair", "afford", "afraid",
    "again", "age", "agent", "agree", "ahead", "aim", "air", "airport", "aisle", "alarm", "album",
    "alert", "alien", "all", "alley", "allow", "almost", "alone", "alpha", "already", "also",
    "alter", "always", "amateur", "amazing", "among", "amount", "amused", "analyst", "anchor",
    "ancient", "anger", "angle", "angry", "animal", "ankle", "announce", "annual", "another",
    "answer", "antenna", "antique", "anxiety", "any", "apart", "apology", "appear", "apple",
    "approve", "april", "arch", "arctic", "area", "arena", "argue", "arm", "armed", "armor",
    "army", "around", "arrange", "arrest", "arrive", "arrow", "art", "artefact", "artist",
    "artwork", "ask", "aspect", "assault", "asset", "assist", "assume", "asthma", "athlete",
    "atom", "attack", "attend", "attitude", "attract", "auction", "audit", "august", "aunt",
    "author", "auto", "autumn", "average", "avocado", "avoid", "awake", "aware", "away", "awesome",
    "awful", "awkward", "axis", "baby", "bachelor", "bacon", "badge", "bag", "balance", "balcony",
    "ball", "bamboo", "banana", "banner", "bar", "barely", "bargain", "barrel", "base", "basic",
    "basket", "battle", "beach", "bean", "beauty", "because", "become", "beef", "before", "begin",
    "behave", "behind", "believe", "below", "belt", "bench", "benefit", "best", "betray", "better",
    "between", "beyond", "bicycle", "bid", "bike", "bind", "biology", "bird", "birth", "bitter",
    "black", "blade", "blame", "blanket", "blast", "bleak", "bless", "blind", "blood", "blossom",
    "blouse", "blue", "blur", "blush", "board", "boat", "body", "boil", "bomb", "bone", "bonus",
    "book", "boost", "border", "boring", "borrow", "boss", "bottom", "bounce", "box", "boy",
    "bracket", "brain", "brand", "brass", "brave", "bread", "breeze", "brick", "bridge", "brief",
    "bright", "bring", "brisk", "broccoli", "broken", "bronze", "broom", "brother", "brown",
    "brush", "bubble", "buddy", "budget", "buffalo", "build", "bulb", "bulk", "bullet", "bundle",
    "bunker", "burden", "burger", "burst", "bus", "business", "busy", "butter", "buyer", "buzz",
    "cabbage", "cabin", "cable", "cactus", "cage", "cake", "call", "calm", "camera", "camp", "can",
    "canal", "cancel", "candy", "cannon", "canoe", "canvas", "canyon", "capable", "capital",
    "captain", "car", "carbon", "card", "cargo", "carpet", "carry", "cart", "case", "cash",
    "casino", "castle", "casual", "cat", "catalog", "catch", "category", "cattle", "caught",
    "cause", "caution", "cave", "ceiling", "celery", "cement", "census", "century", "cereal",
    "certain", "chair", "chalk", "champion", "change", "chaos", "chapter", "charge", "chase",
    "chat", "cheap", "check", "cheese", "chef", "cherry", "chest", "chicken", "chief", "child",
    "chimney", "choice", "choose", "chronic", "chuckle", "chunk", "churn", "cigar", "cinnamon",
    "circle", "citizen", "city", "civil", "claim", "clap", "clarify", "claw", "clay", "clean",
];

/// BIP39 词表的哈希索引：助记词判定在粘贴路径上跑，逐词线性扫 300 个词没必要。
static BIP39_LOOKUP: LazyLock<HashSet<&'static str>> =
    LazyLock::new(|| COMMON_BIP39_WORDS.iter().copied().collect());

/// 「粘完即焚」的判定档位。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutoBurnKind {
    /// 普通内容：不焚，客户端走原有粘贴路径
    None,
    /// 一次性验证码：提纯出纯码粘出去，历史不留原文
    Otp,
    /// 助记词 / 恢复短语 / 密钥：原样粘贴后立刻焚掉历史
    Secret,
}

/// 一次「要不要焚」的完整判定结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutoBurnSignal {
    /// 判定档位
    pub kind: AutoBurnKind,
    /// Otp 时为应写入剪贴板的提纯验证码（纯数字/字母数字，如 "482910"）；
    /// Secret 与 None 时为空字符串。
    pub extracted_code: String,
    /// 复用 `sensitive.rs` 的分类名（如 "openai_key" / "private_key"）；
    /// Otp 时固定为 "otp_code"，Secret 时为命中的规则名（助记词为 "mnemonic_phrase"），
    /// None 时为 None。客户端拿它查本地化文案，**不要随意改名**（跨端契约）。
    pub sensitive_type: Option<String>,
}

impl AutoBurnSignal {
    fn none() -> Self {
        Self {
            kind: AutoBurnKind::None,
            extracted_code: String::new(),
            sensitive_type: None,
        }
    }
}

/// 判定一段文本要不要「粘完即焚」，并给出粘贴用的提纯验证码。
///
/// 判定顺序固定为 Otp → Secret → None：
/// 验证码最需要提纯（原文往往夹着发送方前缀和有效期，整段粘出去是错的），
/// 所以只要够可信就先按 Otp 处理；剩下的再交给助记词/密钥规则兜底。
pub fn detect_auto_burn(text: &str) -> AutoBurnSignal {
    if text.trim().is_empty() {
        return AutoBurnSignal::none();
    }

    if let Some(code) = detect_otp_code(text) {
        return AutoBurnSignal {
            kind: AutoBurnKind::Otp,
            extracted_code: code,
            sensitive_type: Some("otp_code".to_string()),
        };
    }

    if let Some(name) = detect_secret(text) {
        return AutoBurnSignal {
            kind: AutoBurnKind::Secret,
            extracted_code: String::new(),
            sensitive_type: Some(name.to_string()),
        };
    }

    AutoBurnSignal::none()
}

// MARK: - 验证码（Otp）

/// 从整段文本里找出可信的验证码并提纯（去掉分隔空格）。
fn detect_otp_code(text: &str) -> Option<String> {
    // 长度护栏：长文本里「碰巧有个 6 位数字」太容易了，宁可不判
    if text.chars().count() > OTP_MAX_TEXT_CHARS {
        return None;
    }
    // 逐行判定：关键词和验证码必须在同一行，否则「验证码见上」+ 别行的订单号会被串起来
    for line in text.lines() {
        if let Some(code) = detect_otp_in_line(line) {
            return Some(code);
        }
    }
    None
}

/// 单行内的验证码判定。
fn detect_otp_in_line(line: &str) -> Option<String> {
    let chars: Vec<char> = line.chars().collect();
    if chars.len() < 2 {
        return None;
    }
    // 大小写只对英文关键词有意义；中文原样保留
    let lower: Vec<char> = chars.iter().map(|c| c.to_ascii_lowercase()).collect();

    let mut hits = keyword_hits(&lower);
    if hits.is_empty() {
        return None;
    }
    // 关键词可能重复出现，按出现顺序处理，先命中的先返回
    hits.sort_unstable_by_key(|(start, _)| *start);

    for (kw_start, kw_end) in hits {
        // 优先看关键词之后（「验证码是 482910」是绝大多数短信的写法）
        let after_end = (kw_end + OTP_WINDOW_AFTER).min(chars.len());
        if let Some(code) = pick_candidate(&chars, kw_end, after_end, false) {
            return Some(code);
        }
        // 再看关键词之前（「482910 是您的验证码」）
        let before_start = kw_start.saturating_sub(OTP_WINDOW_BEFORE);
        if let Some(code) = pick_candidate(&chars, before_start, kw_start, true) {
            return Some(code);
        }
    }
    None
}

/// 在 `lower` 里找出所有验证码语境关键词的字符区间。
fn keyword_hits(lower: &[char]) -> Vec<(usize, usize)> {
    let mut hits = Vec::new();
    for kw in OTP_KEYWORDS_ZH.iter().chain(OTP_KEYWORDS_EN.iter()) {
        let kw_chars: Vec<char> = kw.chars().collect();
        if kw_chars.is_empty() || kw_chars.len() > lower.len() {
            continue;
        }
        // 英文关键词必须卡词边界，否则 "barcode" 里的 "code" 也会被当成验证码语境
        let needs_boundary = kw.chars().all(|c| c.is_ascii());
        let last_start = lower.len() - kw_chars.len();
        for i in 0..=last_start {
            if lower[i..i + kw_chars.len()] != kw_chars[..] {
                continue;
            }
            if needs_boundary {
                let left_ok = i == 0 || !lower[i - 1].is_ascii_alphanumeric();
                let right_ok = i + kw_chars.len() == lower.len()
                    || !lower[i + kw_chars.len()].is_ascii_alphanumeric();
                if !left_ok || !right_ok {
                    continue;
                }
            }
            hits.push((i, i + kw_chars.len()));
        }
    }
    hits
}

/// 在 `[from, to)` 区间里挑一个可信的候选码。
///
/// - `nearest_end = false`：取窗口里**最靠前**的候选（关键词之后的常见写法）；
/// - `nearest_end = true`：取窗口里**最靠后**的候选（关键词之前的常见写法，离关键词最近）。
///
/// 为什么按距离挑而不是「取最长的」：一条短信里同时出现「验证码 482910」和
/// 「有效期 300 秒」时，只有贴着关键词的那个才是真验证码。
fn pick_candidate(chars: &[char], from: usize, to: usize, nearest_end: bool) -> Option<String> {
    let candidates = collect_candidates(chars, from, to);
    let iter: Box<dyn Iterator<Item = &(usize, usize, String)>> = if nearest_end {
        Box::new(candidates.iter().rev())
    } else {
        Box::new(candidates.iter())
    };
    for (start, end, code) in iter {
        if candidate_is_plausible(chars, *start, *end, code) {
            return Some(code.clone());
        }
    }
    None
}

/// 扫描 `[from, to)` 区间，收集所有「像验证码」的候选（尚未做误判排除）。
///
/// 两种形态：
/// - 4~8 位纯数字，允许单位数字之间用空格分隔（`4 8 2 9 1 0`）；
/// - 6 位字母数字混合（`A1B2C3`，必须同时含数字和字母）。
fn collect_candidates(chars: &[char], from: usize, to: usize) -> Vec<(usize, usize, String)> {
    let mut out = Vec::new();
    let mut i = from;
    while i < to.min(chars.len()) {
        let c = chars[i];
        if c.is_ascii_alphanumeric() {
            // 从数字或字母数字串中间开始扫的（前一个字符也是字母数字）跳过，留给它自己的起点
            if i > 0 && chars[i - 1].is_ascii_alphanumeric() {
                i += 1;
                continue;
            }
            let mut j = i;
            while j < chars.len() && chars[j].is_ascii_alphanumeric() {
                j += 1;
            }
            let is_all_digits = chars[i..j].iter().all(|ch| ch.is_ascii_digit());
            if is_all_digits {
                let (digits, end) = collect_digit_run(chars, i);
                if (4..=8).contains(&digits.len()) {
                    out.push((i, end, digits));
                }
                i = end.max(i + 1);
                continue;
            }
            let token: String = chars[i..j].iter().collect();
            let has_digit = token.chars().any(|ch| ch.is_ascii_digit());
            let has_alpha = token.chars().any(|ch| ch.is_ascii_alphabetic());
            if token.len() == 6 && has_digit && has_alpha {
                out.push((i, j, token));
            }
            i = j.max(i + 1);
            continue;
        }
        i += 1;
    }
    out
}

/// 从 `start` 起收集一串数字，返回（去空格后的数字串, 结束位置）。
///
/// 空格分隔只支持「单个数字 + 空格 + 单个数字」的写法（`4 8 2 9 1 0`）。
/// 连续两位以上数字之间不跨空格合并，否则「验证码 1234 参考 5678」会被拼成
/// 一个 8 位数，粘出去就是错的。
fn collect_digit_run(chars: &[char], start: usize) -> (String, usize) {
    let mut digits = String::new();
    let mut i = start;
    while i < chars.len() && chars[i].is_ascii_digit() {
        digits.push(chars[i]);
        i += 1;
    }
    let mut end = i;

    // 只有首位是孤立数字时才尝试吃「空格 + 孤立数字」的序列
    if digits.len() == 1 {
        let mut j = end;
        let mut merged = digits.clone();
        while j + 1 < chars.len()
            && (chars[j] == ' ' || chars[j] == '\u{00A0}')
            && chars[j + 1].is_ascii_digit()
        {
            // 右侧必须也是孤立数字（再右边不是数字），否则说明是两串独立的数字
            let next_is_isolated = j + 2 >= chars.len() || !chars[j + 2].is_ascii_alphanumeric();
            if !next_is_isolated {
                break;
            }
            merged.push(chars[j + 1]);
            j += 2;
            end = j;
        }
        if merged.len() > 1 {
            return (merged, end);
        }
    }
    (digits, end)
}

/// 误判排除：这个候选码虽然形态像，但其实不是验证码吗？
fn candidate_is_plausible(chars: &[char], start: usize, end: usize, code: &str) -> bool {
    if end > chars.len() {
        return false;
    }

    // 小数点：`4829.10` 是金额/版本号，不是验证码
    if end + 1 < chars.len() && chars[end] == '.' && chars[end + 1].is_ascii_digit() {
        return false;
    }

    // 货币符号紧贴数字前面：`¥4829` / `$1200`
    if start > 0 && matches!(chars[start - 1], '¥' | '$' | '€' | '£') {
        return false;
    }

    // 数字后面紧跟金额/百分比单位：`4829 元`、`1200 万元`、`35 %`
    let tail: String = chars[end..].iter().take(4).collect();
    let tail_trimmed = tail.trim_start();
    for unit in ["元", "美元", "万元", "%"] {
        if tail_trimmed.starts_with(unit) {
            return false;
        }
    }

    // 纯数字才有下面这些数字语义问题
    if code.chars().all(|c| c.is_ascii_digit()) {
        // 中国大陆手机号：11 位、以 1 开头。长度护栏已基本挡住，这里显式再兜一层
        if code.len() == 11 && code.starts_with('1') {
            return false;
        }
        // 4 位年份：`The code is 2026` 里的 2026 是年份，不是验证码
        if code.len() == 4 {
            if let Ok(value) = code.parse::<u32>() {
                if (1900..=2100).contains(&value) {
                    return false;
                }
            }
        }
    }

    // 前面紧邻「尾号 / 订单号 / No.」等编号语境：这是账号的一部分，不是验证码
    if has_number_context_prefix(chars, start) {
        return false;
    }

    true
}

/// 数字前面是否是「编号类」语境词。
fn has_number_context_prefix(chars: &[char], start: usize) -> bool {
    // 先跳过「编号 1234」「编号：1234」「编号(1234)」里的分隔符
    let mut p = start;
    while p > 0
        && (chars[p - 1].is_whitespace()
            || matches!(chars[p - 1], ':' | '：' | '=' | '#' | '(' | '（'))
    {
        p -= 1;
    }
    if p == 0 {
        return false;
    }
    // 只看前面 6 个字符：「后四位」「订单号」这类词最长 4 字，留点余量
    let from = p.saturating_sub(6);
    let prefix: String = chars[from..p].iter().collect();
    let prefix_lower = prefix.to_lowercase();
    if NUMBER_CONTEXT_STOPWORDS
        .iter()
        .any(|kw| prefix_lower.ends_with(kw))
    {
        return true;
    }
    // 单独一个 "No"（不带点号）也当编号语境
    let token: String = prefix_lower
        .chars()
        .rev()
        .take_while(|c| c.is_ascii_alphanumeric())
        .collect::<String>()
        .chars()
        .rev()
        .collect();
    token == "no"
}

// MARK: - 助记词 / 密钥（Secret）

/// 判定 Secret 档位，返回命中的规则名。
///
/// 顺序：先跑 `sensitive.rs` 的密钥规则（那是精确正则，命中即是真密钥），
/// 再判断助记词。两者都给 Secret，只是 `sensitive_type` 不同，客户端文案可以区分。
fn detect_secret(text: &str) -> Option<&'static str> {
    if let Some(name) = crate::algorithms::sensitive::detect_sensitive_data(text) {
        return Some(name);
    }
    if text.chars().count() > MNEMONIC_MAX_TEXT_CHARS {
        return None;
    }
    if looks_like_mnemonic_phrase(text) {
        return Some("mnemonic_phrase");
    }
    None
}

/// 是否像 BIP39 助记词 / 恢复短语。
fn looks_like_mnemonic_phrase(text: &str) -> bool {
    let mut run: Vec<&str> = Vec::new();
    for raw in text.split_whitespace() {
        // 只剥句末标点：助记词被复制时经常带着结尾的句号/逗号，
        // 但大小写、数字、词内其它标点一律不宽容——真助记词永远是纯小写单词。
        let word = raw.trim_matches(|c: char| matches!(c, '.' | ',' | ';' | ':' | '!' | '?'));
        let is_word =
            word.len() >= 3 && word.len() <= 8 && word.chars().all(|c| c.is_ascii_lowercase());
        if !is_word {
            // 遇到任何不像助记词词的片段（大写、数字、标点、中文），连续序列就断了
            run.clear();
            continue;
        }
        run.push(word);
        if mnemonic_run_matches(&run) {
            return true;
        }
    }
    false
}

/// 连续单词序列里是否存在长度合法、且 BIP39 命中数达标的窗口。
fn mnemonic_run_matches(run: &[&str]) -> bool {
    const VALID_LENGTHS: &[usize] = &[24, 21, 18, 15, 12];
    // 至少 8 个词落进 BIP39 词表才认：普通小写英文句子也能凑出 12 个词，
    // 但凑不出 8 个 BIP39 词，这条阈值就是用来把「句子」和「助记词」分开的。
    const MIN_BIP39_HITS: usize = 8;

    for &len in VALID_LENGTHS {
        if run.len() < len {
            continue;
        }
        let window = &run[run.len() - len..];
        let hits = window.iter().filter(|w| BIP39_LOOKUP.contains(**w)).count();
        if hits >= MIN_BIP39_HITS {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn otp(text: &str) -> Option<String> {
        let signal = detect_auto_burn(text);
        if signal.kind == AutoBurnKind::Otp {
            Some(signal.extracted_code)
        } else {
            None
        }
    }

    #[test]
    fn test_empty_text_is_none() {
        for text in ["", "   ", "\n\n\t"] {
            assert_eq!(
                detect_auto_burn(text).kind,
                AutoBurnKind::None,
                "空内容不该判焚"
            );
        }
    }

    #[test]
    fn test_keyword_without_number_is_none() {
        assert_eq!(
            detect_auto_burn("验证码已发送，请注意查收").kind,
            AutoBurnKind::None
        );
        assert_eq!(
            detect_auto_burn("Your code has been sent").kind,
            AutoBurnKind::None
        );
    }

    #[test]
    fn test_barcode_is_not_code_context() {
        // "barcode" 里的 code 不算关键词，否则商品条码会被当验证码
        assert_eq!(detect_auto_burn("barcode 482910").kind, AutoBurnKind::None);
    }

    #[test]
    fn test_year_is_not_otp() {
        assert_eq!(otp("The code is 2026"), None);
        assert_eq!(otp("验证码 1999"), None);
    }

    #[test]
    fn test_currency_and_percentage_are_not_otp() {
        assert_eq!(otp("验证码 ¥4829"), None);
        assert_eq!(otp("验证码 4829 元"), None);
        assert_eq!(otp("code 4829 %"), None);
    }

    #[test]
    fn test_decimal_is_not_otp() {
        assert_eq!(otp("验证码 4829.10"), None);
    }

    #[test]
    fn test_number_context_prefix_is_not_otp() {
        // 编号类语境里的数字属于账号，不是验证码
        assert_eq!(otp("订单号 2026 的验证码"), None);
        assert_eq!(otp("验证码已发送到尾号 1234"), None);
    }

    #[test]
    fn test_long_text_is_not_otp() {
        let long = format!("{}验证码 482910", "填".repeat(500));
        assert_eq!(
            detect_auto_burn(&long).kind,
            AutoBurnKind::None,
            "超 500 字不做验证码猜测"
        );
    }

    #[test]
    fn test_mnemonic_matches_and_ordinary_sentence_does_not() {
        let phrase =
            "abandon ability able about above absent absorb abstract absurd abuse access accident";
        let signal = detect_auto_burn(phrase);
        assert_eq!(signal.kind, AutoBurnKind::Secret);
        assert_eq!(signal.sensitive_type.as_deref(), Some("mnemonic_phrase"));
        assert_eq!(signal.extracted_code, "");

        let sentence = "The quick brown fox jumps over the lazy dog and then runs away quickly.";
        assert_eq!(detect_auto_burn(sentence).kind, AutoBurnKind::None);
    }

    #[test]
    fn test_spaced_digits_are_purified() {
        assert_eq!(otp("验证码：4 8 2 9 1 0"), Some("482910".to_string()));
    }

    #[test]
    fn test_eight_digit_otp_within_window() {
        // 8 位一次性口令（常见于银行/企业二次验证）也在 4~8 位区间内
        assert_eq!(
            otp("验证码 12345678，请勿泄露"),
            Some("12345678".to_string())
        );
    }

    #[test]
    fn test_code_on_another_line_is_not_paired() {
        // 关键词与号码必须同一行：「验证码见下」+ 别行的订单号不能串成一个码
        assert_eq!(
            detect_auto_burn("您的验证码见下方邮件\n订单号 2026").kind,
            AutoBurnKind::None
        );
    }

    #[test]
    fn test_only_nearest_number_to_keyword_wins() {
        // 窗口里同时有「有效期 300 秒」和真码时，紧贴关键词的那个优先
        assert_eq!(
            otp("验证码 482910 有效期 300 秒"),
            Some("482910".to_string())
        );
    }

    #[test]
    fn test_sensitive_rule_falls_into_secret() {
        // 拼接构造样本，避免仓库里出现「看起来像真密钥」的字面量被密钥扫描误报
        let sample = format!("{}{}", "sk-", "proj-abcdefghijklmnopqrstuvwxyz012345");
        let signal = detect_auto_burn(&sample);
        assert_eq!(signal.kind, AutoBurnKind::Secret);
        assert_eq!(signal.sensitive_type.as_deref(), Some("openai_key"));
    }
}
