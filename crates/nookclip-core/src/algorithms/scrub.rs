//! 全品类隐私脱敏与还原（Phase 1 / `specs/012-scrub-stack-pin` US1）。
//!
//! 与 `sensitive.rs` 的区别：`sensitive.rs` 是「整条掩码」的粗粒度判定
//! （用于历史库标记私密条目），本模块是**语义占位符**替换——把敏感片段换成
//! `<EMAIL_1>` / `<API_KEY_1>` 这类可逆标记，让用户能把代码、日志、配置安全地
//! 丢给 AI，再把 AI 回复里的占位符一键还原成真实值。
//!
//! 四条不变量（`contracts/phase1-contracts.md` §3）：
//! 1. 零明文落盘：映射表只活在进程堆内存（`VAULT`），绝不写 SQLite / 日志 / 文件；
//! 2. 同值同号：同一原始值在同一次调用或同一会话内恒映射到同一个占位符，
//!    不同值按出现顺序递增编号（`<EMAIL_1>` / `<EMAIL_2>`），保住代码逻辑关联；
//! 3. 无嵌套破损标签：所有命中区间先做非重叠归并（起始靠前优先、等起点取更长、
//!    再同长比优先级），归并后的区间绝不被二次扫描——不会产出 `<CONN_<IP_1>>`；
//! 4. 会话池有界：LRU 上限 200 条，闲置超时（默认 1800 秒）自动销毁。
//!
//! 三层识别来源：
//! - Rust 正则 + 校验位算法（Luhn / ISO 7064 MOD 11-2 / IBAN MOD-97-10）；
//! - 外部自然语言实体区间（macOS `NLTagger` 传人名 / 地址的 UTF-8 字节偏移）；
//! - 用户自定义规则（字面量或正则）。

use parking_lot::Mutex;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::LazyLock;
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// 1. 规则枚举与配置
// ---------------------------------------------------------------------------

/// 19 类内置脱敏规则标识（第 20 类为用户自定义 `custom_*`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BuiltinScrubRule {
    // 凭据与密钥
    ApiKeys,
    PrivateKey,
    ConnSecret,
    // 网络与设备标识
    IpAddress,
    MacAddress,
    HomeUsername,
    UserAtHost,
    CloudBucket,
    SerialNumber,
    // 个人隐私信息（PII）
    Email,
    Phone,
    IdCard,
    Ssn,
    Passport,
    BankCard,
    Iban,
    BirthDate,
    PersonName,
    Address,
}

impl BuiltinScrubRule {
    /// 全部内置规则（顺序即设置页展示顺序）
    pub const ALL: [BuiltinScrubRule; 19] = [
        BuiltinScrubRule::ApiKeys,
        BuiltinScrubRule::PrivateKey,
        BuiltinScrubRule::ConnSecret,
        BuiltinScrubRule::IpAddress,
        BuiltinScrubRule::MacAddress,
        BuiltinScrubRule::HomeUsername,
        BuiltinScrubRule::UserAtHost,
        BuiltinScrubRule::CloudBucket,
        BuiltinScrubRule::SerialNumber,
        BuiltinScrubRule::Email,
        BuiltinScrubRule::Phone,
        BuiltinScrubRule::IdCard,
        BuiltinScrubRule::Ssn,
        BuiltinScrubRule::Passport,
        BuiltinScrubRule::BankCard,
        BuiltinScrubRule::Iban,
        BuiltinScrubRule::BirthDate,
        BuiltinScrubRule::PersonName,
        BuiltinScrubRule::Address,
    ];

    /// 稳定的规则键（持久化 / FFI / 设置页共用，禁止改名）
    pub const fn rule_id(self) -> &'static str {
        match self {
            BuiltinScrubRule::ApiKeys => "api_keys",
            BuiltinScrubRule::PrivateKey => "private_key",
            BuiltinScrubRule::ConnSecret => "conn_secret",
            BuiltinScrubRule::IpAddress => "ip_address",
            BuiltinScrubRule::MacAddress => "mac_address",
            BuiltinScrubRule::HomeUsername => "home_username",
            BuiltinScrubRule::UserAtHost => "user_at_host",
            BuiltinScrubRule::CloudBucket => "cloud_bucket",
            BuiltinScrubRule::SerialNumber => "serial_number",
            BuiltinScrubRule::Email => "email",
            BuiltinScrubRule::Phone => "phone",
            BuiltinScrubRule::IdCard => "id_card",
            BuiltinScrubRule::Ssn => "ssn",
            BuiltinScrubRule::Passport => "passport",
            BuiltinScrubRule::BankCard => "bank_card",
            BuiltinScrubRule::Iban => "iban",
            BuiltinScrubRule::BirthDate => "birth_date",
            BuiltinScrubRule::PersonName => "person_name",
            BuiltinScrubRule::Address => "address",
        }
    }

    /// 占位符标签（生成 `<TAG_N>`）
    pub const fn placeholder_tag(self) -> &'static str {
        match self {
            BuiltinScrubRule::ApiKeys => "API_KEY",
            BuiltinScrubRule::PrivateKey => "PRIVATE_KEY",
            BuiltinScrubRule::ConnSecret => "SECRET",
            BuiltinScrubRule::IpAddress => "IP",
            BuiltinScrubRule::MacAddress => "MAC_ADDR",
            BuiltinScrubRule::HomeUsername => "USER",
            BuiltinScrubRule::UserAtHost => "USER_HOST",
            BuiltinScrubRule::CloudBucket => "CLOUD_BUCKET",
            BuiltinScrubRule::SerialNumber => "SERIAL",
            BuiltinScrubRule::Email => "EMAIL",
            BuiltinScrubRule::Phone => "PHONE",
            BuiltinScrubRule::IdCard => "ID_CARD",
            BuiltinScrubRule::Ssn => "SSN",
            BuiltinScrubRule::Passport => "PASSPORT",
            BuiltinScrubRule::BankCard => "BANK_CARD",
            BuiltinScrubRule::Iban => "IBAN",
            BuiltinScrubRule::BirthDate => "BIRTH_DATE",
            BuiltinScrubRule::PersonName => "NAME",
            BuiltinScrubRule::Address => "ADDRESS",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|r| r.rule_id() == id)
    }
}

/// 用户自定义脱敏规则。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CustomScrubRule {
    pub id: String,
    pub name: String,
    /// `false` = 固定关键词（字面量匹配），`true` = 正则表达式
    pub is_regex: bool,
    pub pattern: String,
    /// 占位符前缀名，如 `"COMPANY"` 生成 `<COMPANY_1>`
    pub placeholder_tag: String,
    pub enabled: bool,
}

/// 外部（如 macOS `NLTagger`）识别传入的自然语言实体区间。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalEntitySpan {
    /// UTF-8 字节起始偏移
    pub start_byte: u32,
    /// UTF-8 字节结束偏移（不含）
    pub end_byte: u32,
    /// `"person_name"` 或 `"address"`
    pub rule_key: String,
}

/// 脱敏引擎运行时配置（Swift 侧持久化在 UserDefaults 的 JSON 中）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScrubConfig {
    /// 启用的内置规则 key 列表（严格白名单：不在列表里的规则不脱敏，
    /// 空列表 = 全部停用；`Default` 给出 19 条全集）
    pub enabled_builtin_rules: Vec<String>,
    /// 用户自定义脱敏规则
    pub custom_rules: Vec<CustomScrubRule>,
    /// 会话映射表闲置过期秒数（默认 1800 秒）
    pub session_ttl_seconds: u64,
}

/// 会话映射表默认闲置超时：30 分钟
pub const DEFAULT_SESSION_TTL_SECONDS: u64 = 1_800;
/// 会话映射表 LRU 上限
pub const MAX_VAULT_ENTRIES: usize = 200;

impl Default for ScrubConfig {
    fn default() -> Self {
        Self {
            enabled_builtin_rules: default_enabled_rule_keys()
                .into_iter()
                .map(str::to_string)
                .collect(),
            custom_rules: Vec::new(),
            session_ttl_seconds: DEFAULT_SESSION_TTL_SECONDS,
        }
    }
}

impl ScrubConfig {
    /// 该规则是否启用。
    ///
    /// 语义是**严格白名单**：列表里没有的规则就是不启用，空列表 = 一条都不启用。
    /// 早期版本曾把空列表当作「默认全集」，但那样用户「关掉所有规则」后会
    /// 反而全开——开关的极端态与直觉相反，是个真实的可用性缺陷。默认值由
    /// `Default::default()` / FFI `FfiScrubConfig::default()` 显式给出全集，
    /// 所以「默认全开」的体验不受影响。
    fn is_enabled(&self, rule: BuiltinScrubRule) -> bool {
        self.enabled_builtin_rules
            .iter()
            .any(|k| k == rule.rule_id())
    }
}

/// 默认启用的内置规则键（与 `BuiltinScrubRule::ALL` 同序）。
pub fn default_enabled_rule_keys() -> Vec<&'static str> {
    BuiltinScrubRule::ALL.iter().map(|r| r.rule_id()).collect()
}

// ---------------------------------------------------------------------------
// 2. 执行结果模型
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScrubReplacementItem {
    pub placeholder: String,
    pub rule_key: String,
    /// 该占位符在脱敏文本中出现的次数
    pub count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScrubResult {
    pub scrubbed_text: String,
    pub has_replacements: bool,
    pub replacements: Vec<ScrubReplacementItem>,
    pub active_vault_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestoreResult {
    pub restored_text: String,
    pub restored_count: u32,
}

// ---------------------------------------------------------------------------
// 3. 会话还原池（仅进程内存）
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct VaultEntry {
    placeholder: String,
    tag: String,
    original: String,
    last_touched: u64,
}

/// 脱敏映射会话池：占位符 ↔ 真实值，只在进程堆内存存活。
#[derive(Debug)]
pub struct ScrubSessionVault {
    /// 插入序即 LRU 序（前端淘汰）
    entries: Vec<VaultEntry>,
    /// (标签, 原始值) → 占位符（同值同号）
    by_value: HashMap<(String, String), String>,
    /// 占位符 → 原始值（还原）
    by_placeholder: HashMap<String, String>,
    /// 每标签已分配的最大编号（淘汰后也不回收，避免撞号）
    counters: HashMap<String, u32>,
    last_activity: u64,
    /// 最近一次脱敏配置的会话 TTL（供还原与占位符计数沿用）
    ttl_seconds: u64,
}

impl Default for ScrubSessionVault {
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            by_value: HashMap::new(),
            by_placeholder: HashMap::new(),
            counters: HashMap::new(),
            last_activity: 0,
            ttl_seconds: DEFAULT_SESSION_TTL_SECONDS,
        }
    }
}

impl ScrubSessionVault {
    pub fn new() -> Self {
        Self::default()
    }

    /// 清空全部映射（设置页「一键清空」/ 退出登录 / TTL 到期）。
    pub fn clear(&mut self) {
        self.entries.clear();
        self.by_value.clear();
        self.by_placeholder.clear();
        self.counters.clear();
        self.last_activity = 0;
        self.ttl_seconds = DEFAULT_SESSION_TTL_SECONDS;
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// 过期清理：单条闲置超时 + 整池闲置超时（`ttl == 0` 视为立即全清）。
    pub fn purge_expired(&mut self, now: u64, ttl_seconds: u64) {
        if self.entries.is_empty() && self.by_value.is_empty() {
            return;
        }
        if ttl_seconds == 0 {
            self.clear();
            return;
        }
        // 整池闲置超时：直接全清（与单条超时同源，语义更直观）
        if self.last_activity > 0 && now.saturating_sub(self.last_activity) >= ttl_seconds {
            self.clear();
            return;
        }
        if self.entries.is_empty() {
            return;
        }
        let mut kept: Vec<VaultEntry> = Vec::with_capacity(self.entries.len());
        for entry in self.entries.drain(..) {
            if now.saturating_sub(entry.last_touched) >= ttl_seconds {
                let key = (entry.tag.clone(), entry.original.clone());
                if self.by_value.get(&key) == Some(&entry.placeholder) {
                    self.by_value.remove(&key);
                }
                if self.by_placeholder.get(&entry.placeholder) == Some(&entry.original) {
                    self.by_placeholder.remove(&entry.placeholder);
                }
            } else {
                kept.push(entry);
            }
        }
        self.entries = kept;
    }

    /// 取或分配占位符：同值同号，不同值递增编号。
    fn intern(&mut self, tag: &str, original: &str, now: u64) -> String {
        let key = (tag.to_string(), original.to_string());

        // 1. 已有映射：复用并刷新 LRU 位置
        if let Some(existing) = self.by_value.get(&key).cloned() {
            if let Some(idx) = self.entries.iter().position(|e| e.placeholder == existing) {
                let mut entry = self.entries.remove(idx);
                entry.last_touched = now;
                self.entries.push(entry);
            } else {
                // 映射表与条目表不一致（理论上不会发生）：以映射表为准补条
                self.entries.push(VaultEntry {
                    placeholder: existing.clone(),
                    tag: tag.to_string(),
                    original: original.to_string(),
                    last_touched: now,
                });
            }
            self.last_activity = now;
            return existing;
        }

        // 2. 新值：分配下一个编号
        let counter = self.counters.entry(tag.to_string()).or_insert(0);
        *counter += 1;
        let placeholder = format!("<{}_{}>", tag, *counter);

        self.by_value.insert(key, placeholder.clone());
        self.by_placeholder
            .insert(placeholder.clone(), original.to_string());
        self.entries.push(VaultEntry {
            placeholder: placeholder.clone(),
            tag: tag.to_string(),
            original: original.to_string(),
            last_touched: now,
        });
        self.last_activity = now;

        // 3. LRU 淘汰
        while self.entries.len() > MAX_VAULT_ENTRIES {
            let evicted = self.entries.remove(0);
            let key = (evicted.tag.clone(), evicted.original.clone());
            if self.by_value.get(&key) == Some(&evicted.placeholder) {
                self.by_value.remove(&key);
            }
            if self.by_placeholder.get(&evicted.placeholder) == Some(&evicted.original) {
                self.by_placeholder.remove(&evicted.placeholder);
            }
        }

        placeholder
    }

    /// 按占位符还原真实值；命中即刷新该条 LRU 时间。
    fn lookup_and_touch(&mut self, placeholder: &str, now: u64) -> Option<String> {
        let original = self.by_placeholder.get(placeholder).cloned()?;
        if let Some(idx) = self.entries.iter().position(|e| e.placeholder == placeholder) {
            let mut entry = self.entries.remove(idx);
            entry.last_touched = now;
            self.entries.push(entry);
        }
        self.last_activity = now;
        Some(original)
    }

    fn contains(&self, placeholder: &str) -> bool {
        self.by_placeholder.contains_key(placeholder)
    }
}

/// 全局会话池：`LazyLock<Mutex<_>>`，纯内存，绝不落盘。
static VAULT: LazyLock<Mutex<ScrubSessionVault>> =
    LazyLock::new(|| Mutex::new(ScrubSessionVault::new()));

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// 4. 规则编译表
// ---------------------------------------------------------------------------

type Validator = fn(&str) -> bool;
type ContextFilter = fn(&str, usize, usize) -> bool;

struct CompiledRule {
    rule: BuiltinScrubRule,
    priority: u8,
    regexes: Vec<Regex>,
    /// 替换区间取哪个捕获组（`None` = 整段匹配）
    capture_group: Option<usize>,
    validator: Option<Validator>,
    /// 上下文过滤：返回 `true` 才保留该命中
    context_filter: Option<ContextFilter>,
}

static RULES: LazyLock<Vec<CompiledRule>> = LazyLock::new(build_rules);

fn build_rules() -> Vec<CompiledRule> {
    fn rxs(patterns: &[&str]) -> Vec<Regex> {
        patterns
            .iter()
            .filter_map(|p| Regex::new(p).ok())
            .collect()
    }

    vec![
        CompiledRule {
            rule: BuiltinScrubRule::PrivateKey,
            priority: 100,
            regexes: rxs(&[r"(?s)-----BEGIN[ A-Z]*PRIVATE KEY-----.*?-----END[ A-Z]*PRIVATE KEY-----"]),
            capture_group: None,
            validator: None,
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::ConnSecret,
            priority: 95,
            regexes: rxs(&[
                r"(?i)\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|amqps?|mssql|clickhouse|kafka)://[^\s:/@]+:[^\s@/]+@[^\s]+",
            ]),
            capture_group: None,
            validator: None,
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::ApiKeys,
            priority: 90,
            regexes: rxs(&[
                r"\bsk-(?:ant-)?(?:proj-)?[A-Za-z0-9_\-]{20,}\b",
                r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b",
                r"\bgh[pousr]_[A-Za-z0-9]{36,}\b",
                r"\bglpat-[A-Za-z0-9_\-]{20,}\b",
                r"\bxox[abposr]-[A-Za-z0-9\-]{10,}\b",
                r"\bAIza[0-9A-Za-z_\-]{35}\b",
                r"\brk_live_[A-Za-z0-9]{20,}\b",
                r"\bsk_live_[A-Za-z0-9]{20,}\b",
                r"\bSG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}\b",
                r"\bnpm_[A-Za-z0-9]{36}\b",
                r"\bhf_[A-Za-z0-9]{30,}\b",
            ]),
            capture_group: None,
            validator: None,
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::Iban,
            priority: 88,
            regexes: rxs(&[r"\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\b"]),
            capture_group: None,
            validator: Some(iban_valid),
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::IdCard,
            priority: 86,
            regexes: rxs(&[r"[0-9]{17}[0-9Xx]"]),
            capture_group: None,
            validator: Some(id_card_valid),
            context_filter: Some(not_embedded_in_digits),
        },
        CompiledRule {
            rule: BuiltinScrubRule::BankCard,
            priority: 84,
            regexes: rxs(&[r"[0-9][0-9 \-]{11,25}[0-9]"]),
            capture_group: None,
            validator: Some(bank_card_valid),
            context_filter: Some(not_embedded_in_digits),
        },
        CompiledRule {
            rule: BuiltinScrubRule::Ssn,
            priority: 82,
            regexes: rxs(&[r"\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b"]),
            capture_group: None,
            validator: Some(ssn_valid),
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::Passport,
            priority: 80,
            regexes: rxs(&[
                r"(?i)(?:\bpassport(?:\s*(?:no\.?|number|#))?|护照(?:号|号码)?)[\s]*[:：#]?[\s]*([A-Z]{1,2}[0-9]{6,9})\b",
            ]),
            capture_group: Some(1),
            validator: None,
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::Email,
            priority: 78,
            regexes: rxs(&[
                r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}",
            ]),
            capture_group: None,
            validator: None,
            context_filter: Some(not_embedded_in_alnum),
        },
        CompiledRule {
            rule: BuiltinScrubRule::UserAtHost,
            priority: 76,
            regexes: rxs(&[
                r"\b[a-z_][a-z0-9_.\-]{0,31}@[A-Za-z0-9](?:[A-Za-z0-9.\-]*[A-Za-z0-9])?",
            ]),
            capture_group: None,
            validator: None,
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::Phone,
            priority: 74,
            regexes: rxs(&[
                r"1[3-9][0-9]{9}",
                r"\+[0-9]{1,3}[ \-]?[0-9]{6,14}",
                r"0[0-9]{2,3}-[0-9]{7,8}",
            ]),
            capture_group: None,
            validator: None,
            context_filter: Some(not_embedded_in_digits),
        },
        CompiledRule {
            rule: BuiltinScrubRule::MacAddress,
            priority: 72,
            regexes: rxs(&[r"(?i)\b[0-9a-f]{2}(?:[:-][0-9a-f]{2}){5}\b"]),
            capture_group: None,
            validator: None,
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::IpAddress,
            priority: 70,
            regexes: rxs(&[r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"]),
            capture_group: None,
            validator: Some(ipv4_valid),
            context_filter: Some(ip_context_ok),
        },
        CompiledRule {
            rule: BuiltinScrubRule::CloudBucket,
            priority: 68,
            regexes: rxs(&[
                r"(?i)\b(?:s3|gs|oss|cos|r2|wasbs?)://[A-Za-z0-9._\-]+",
                r"arn:aws:s3:::[A-Za-z0-9._\-]+",
            ]),
            capture_group: None,
            validator: None,
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::HomeUsername,
            priority: 66,
            regexes: rxs(&[r"/(?:Users|home)/([A-Za-z0-9._\-]+)"]),
            capture_group: Some(1),
            validator: None,
            context_filter: Some(home_username_ok),
        },
        CompiledRule {
            rule: BuiltinScrubRule::SerialNumber,
            priority: 64,
            regexes: rxs(&[
                r"(?i)\b(?:serial(?:\s*(?:number|no\.?|num))?|s/n|sn)[\s]*[:=#][\s]*([A-Z0-9][A-Z0-9\-]{5,23})",
            ]),
            capture_group: Some(1),
            validator: None,
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::BirthDate,
            priority: 60,
            regexes: rxs(&[
                r"(?:19|20)[0-9]{2}[-/.](?:0[1-9]|1[0-2])[-/.](?:0[1-9]|[12][0-9]|3[01])",
                r"(?:19|20)[0-9]{2}年(?:0?[1-9]|1[0-2])月(?:0?[1-9]|[12][0-9]|3[01])日",
            ]),
            capture_group: None,
            validator: Some(date_valid),
            context_filter: Some(date_context_ok),
        },
        // 人名 / 地址没有可靠正则，只吃外部 NLP 区间
        CompiledRule {
            rule: BuiltinScrubRule::PersonName,
            priority: 58,
            regexes: Vec::new(),
            capture_group: None,
            validator: None,
            context_filter: None,
        },
        CompiledRule {
            rule: BuiltinScrubRule::Address,
            priority: 56,
            regexes: Vec::new(),
            capture_group: None,
            validator: None,
            context_filter: None,
        },
    ]
}

// ---------------------------------------------------------------------------
// 5. 校验算法
// ---------------------------------------------------------------------------

fn only_digits(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_digit()).collect()
}

/// Luhn 校验（银行卡）
fn luhn_valid(s: &str) -> bool {
    let digits = only_digits(s);
    if digits.len() < 13 || digits.len() > 19 {
        return false;
    }
    let mut sum = 0u32;
    let mut double = false;
    for ch in digits.chars().rev() {
        let mut d = match ch.to_digit(10) {
            Some(d) => d,
            None => return false,
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

fn bank_card_valid(s: &str) -> bool {
    luhn_valid(s)
}

/// 身份证 18 位出生日期 + ISO 7064 MOD 11-2 校验
fn id_card_valid(s: &str) -> bool {
    let bytes: Vec<char> = s.chars().collect();
    if bytes.len() != 18 {
        return false;
    }
    // 校验第 7~14 位出生日期（YYYYMMDD）是否合法
    let year: u32 = match s.get(6..10).and_then(|v| v.parse().ok()) {
        Some(y) if (1900..=2099).contains(&y) => y,
        _ => return false,
    };
    let month: u32 = match s.get(10..12).and_then(|v| v.parse().ok()) {
        Some(m) if (1..=12).contains(&m) => m,
        _ => return false,
    };
    let day: u32 = match s.get(12..14).and_then(|v| v.parse().ok()) {
        Some(d) if d >= 1 => d,
        _ => return false,
    };
    let is_leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
    let max_day = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap => 29,
        2 => 28,
        _ => return false,
    };
    if day > max_day {
        return false;
    }

    let weights = [7u32, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
    let check_chars = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];
    let mut sum = 0u32;
    for (i, w) in weights.iter().enumerate() {
        match bytes[i].to_digit(10) {
            Some(d) => sum += d * w,
            None => return false,
        }
    }
    let idx = (sum % 11) as usize;
    if idx >= check_chars.len() {
        return false;
    }
    bytes[17].to_ascii_uppercase() == check_chars[idx]
}

/// IBAN MOD-97-10 校验
fn iban_valid(s: &str) -> bool {
    let compact: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    if compact.len() < 15 || compact.len() > 34 {
        return false;
    }
    if !compact.chars().take(2).all(|c| c.is_ascii_uppercase()) {
        return false;
    }
    let rearranged = format!("{}{}", &compact[4..], &compact[..4]);
    let mut remainder: u32 = 0;
    for ch in rearranged.chars() {
        if let Some(d) = ch.to_digit(10) {
            remainder = (remainder * 10 + d) % 97;
        } else if ch.is_ascii_uppercase() {
            let v = ch as u32 - 'A' as u32 + 10;
            remainder = (remainder * 100 + v) % 97;
        } else {
            return false;
        }
    }
    remainder == 1
}

/// 美国 SSN：拒绝 000 / 666 / 9xx 区号段与全 0 段
fn ssn_valid(s: &str) -> bool {
    let parts: Vec<&str> = s.split('-').collect();
    if parts.len() != 3 {
        return false;
    }
    let area: u32 = parts[0].parse().unwrap_or(0);
    let group: u32 = parts[1].parse().unwrap_or(0);
    let serial: u32 = parts[2].parse().unwrap_or(0);
    if area == 0 || area == 666 || area >= 900 {
        return false;
    }
    group != 0 && serial != 0
}

/// IPv4：四段 0~255，排除回环 / 未指定 / 广播段
fn ipv4_valid(s: &str) -> bool {
    let octets: Vec<u32> = s.split('.').filter_map(|p| p.parse().ok()).collect();
    if octets.len() != 4 || octets.iter().any(|o| *o > 255) {
        return false;
    }
    // 127.0.0.0/8 回环、0.0.0.0 未指定、255.255.255.255 广播
    if octets[0] == 127 || octets.iter().all(|o| *o == 0) {
        return false;
    }
    if octets.iter().all(|o| *o == 255) {
        return false;
    }
    true
}

/// 日期合法性（拒绝 2024-02-31 这类伪日期）
fn date_valid(s: &str) -> bool {
    use chrono::NaiveDate;
    let normalized = s.replace('年', "-").replace('月', "-").replace('日', "");
    let normalized = normalized.replace('/', "-").replace('.', "-");
    for fmt in ["%Y-%m-%d", "%Y-%m"] {
        if NaiveDate::parse_from_str(&normalized, fmt).is_ok() {
            return true;
        }
    }
    false
}

// ---------------------------------------------------------------------------
// 6. 上下文过滤
// ---------------------------------------------------------------------------

fn prev_char(text: &str, start: usize) -> Option<char> {
    text.get(..start).and_then(|p| p.chars().next_back())
}

fn next_char(text: &str, end: usize) -> Option<char> {
    text.get(end..).and_then(|s| s.chars().next())
}

/// 命中片段不能只是更长数字串的一部分（避免银行卡号里的 11 位手机号）
fn not_embedded_in_digits(text: &str, start: usize, end: usize) -> bool {
    !prev_char(text, start).map(|c| c.is_ascii_digit()).unwrap_or(false)
        && !next_char(text, end)
            .map(|c| c.is_ascii_digit())
            .unwrap_or(false)
}

/// 邮箱不能嵌在更长的标识符里（如 `abcdev@x.com` 前面还有字母）
fn not_embedded_in_alnum(text: &str, start: usize, end: usize) -> bool {
    !prev_char(text, start)
        .map(|c| c.is_alphanumeric())
        .unwrap_or(false)
        && !next_char(text, end)
            .map(|c| c.is_alphanumeric())
            .unwrap_or(false)
}

/// IP：排除 `v1.2.3.4` 这类版本号（前缀字母 v/V）
fn ip_context_ok(text: &str, start: usize, _end: usize) -> bool {
    if let Some(c) = prev_char(text, start) {
        if c == 'v' || c == 'V' {
            return false;
        }
        // 前面紧贴字母数字 → 属于更长标识符
        if c.is_alphanumeric() || c == '_' {
            return false;
        }
    }
    true
}

/// 首页用户名：`Shared` / `Public` / `Guest` 等公共目录不是个人标识
fn home_username_ok(text: &str, start: usize, end: usize) -> bool {
    let Some(name) = text.get(start..end) else {
        return false;
    };
    !matches!(
        name.to_ascii_lowercase().as_str(),
        "shared" | "public" | "guest" | "default" | "all users"
    )
}

/// 日期：拒绝 ISO 时间戳里的日期部分（`2024-01-15T10:30:00` / `2024-01-15 10:30`）
fn date_context_ok(text: &str, _start: usize, end: usize) -> bool {
    if let Some(c) = next_char(text, end) {
        if c == 'T' || c == 't' {
            return false;
        }
        if c == ' ' {
            // 后面是 HH:MM 则视为时间戳
            if let Some(rest) = text.get(end + 1..) {
                let head: String = rest.chars().take(5).collect();
                let parts: Vec<&str> = head.split(':').collect();
                if parts.len() == 2
                    && parts[0].chars().all(|c| c.is_ascii_digit())
                    && parts[1].chars().all(|c| c.is_ascii_digit())
                    && !parts[0].is_empty()
                {
                    return false;
                }
            }
        }
    }
    true
}

// ---------------------------------------------------------------------------
// 7. 脱敏主流程
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct Candidate {
    start: usize,
    end: usize,
    tag: String,
    rule_key: String,
    priority: u8,
}

/// 非重叠归并策略：起始靠前优先 → 同起点取更长 → 同长比优先级。
fn resolve_overlaps(mut candidates: Vec<Candidate>) -> Vec<Candidate> {
    candidates.sort_by(|a, b| {
        a.start
            .cmp(&b.start)
            .then(b.end.cmp(&a.end))
            .then(b.priority.cmp(&a.priority))
    });
    let mut resolved: Vec<Candidate> = Vec::with_capacity(candidates.len());
    let mut cursor = 0usize;
    for cand in candidates {
        if cand.start >= cursor {
            cursor = cand.end;
            resolved.push(cand);
        }
    }
    resolved
}

/// 归一化自定义规则占位符标签：大写、非字母数字转下划线，空则 `CUSTOM`。
fn normalize_tag(tag: &str) -> String {
    let normalized: String = tag
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .collect();
    let trimmed = normalized.trim_matches('_').to_string();
    if trimmed.is_empty() {
        "CUSTOM".to_string()
    } else {
        trimmed
    }
}

fn collect_builtin_candidates(text: &str, config: &ScrubConfig, out: &mut Vec<Candidate>) {
    for rule in RULES.iter() {
        if !config.is_enabled(rule.rule) {
            continue;
        }
        for regex in &rule.regexes {
            for caps in regex.captures_iter(text) {
                let group = rule.capture_group.unwrap_or(0);
                let Some(m) = caps.get(group) else { continue };
                let (start, end) = (m.start(), m.end());
                if start >= end {
                    continue;
                }
                let Some(matched) = text.get(start..end) else {
                    continue;
                };
                if let Some(filter) = rule.context_filter {
                    if !filter(text, start, end) {
                        continue;
                    }
                }
                if let Some(validator) = rule.validator {
                    if !validator(matched) {
                        continue;
                    }
                }
                out.push(Candidate {
                    start,
                    end,
                    tag: rule.rule.placeholder_tag().to_string(),
                    rule_key: rule.rule.rule_id().to_string(),
                    priority: rule.priority,
                });
            }
        }
    }
}

fn collect_external_candidates(
    text: &str,
    config: &ScrubConfig,
    spans: &[ExternalEntitySpan],
    out: &mut Vec<Candidate>,
) {
    for span in spans {
        let Some(rule) = BuiltinScrubRule::from_id(&span.rule_key) else {
            continue;
        };
        if !matches!(
            rule,
            BuiltinScrubRule::PersonName | BuiltinScrubRule::Address
        ) {
            // 外部区间只接受 NLP 类，其他规则一律走内置正则，避免注入任意替换
            continue;
        }
        if !config.is_enabled(rule) {
            continue;
        }
        let (start, end) = (span.start_byte as usize, span.end_byte as usize);
        if start >= end || end > text.len() {
            continue;
        }
        // 边界必须落在 char boundary，否则切分会 panic
        if !text.is_char_boundary(start) || !text.is_char_boundary(end) {
            continue;
        }
        let matched = text[start..end].trim();
        if matched.is_empty() {
            continue;
        }
        out.push(Candidate {
            start,
            end,
            tag: rule.placeholder_tag().to_string(),
            rule_key: rule.rule_id().to_string(),
            priority: RULES
                .iter()
                .find(|r| r.rule == rule)
                .map(|r| r.priority)
                .unwrap_or(50),
        });
    }
}

fn collect_custom_candidates(text: &str, config: &ScrubConfig, out: &mut Vec<Candidate>) {
    for custom in &config.custom_rules {
        if !custom.enabled || custom.pattern.is_empty() {
            continue;
        }
        let tag = normalize_tag(&custom.placeholder_tag);
        let rule_key = if custom.id.is_empty() {
            format!("custom_{}", tag.to_ascii_lowercase())
        } else {
            format!("custom_{}", custom.id)
        };
        if custom.is_regex {
            // 非法正则静默跳过：用户可能正在输入半截表达式
            let Ok(regex) = Regex::new(&custom.pattern) else {
                continue;
            };
            for m in regex.find_iter(text) {
                if m.start() < m.end() {
                    out.push(Candidate {
                        start: m.start(),
                        end: m.end(),
                        tag: tag.clone(),
                        rule_key: rule_key.clone(),
                        priority: 92,
                    });
                }
            }
        } else {
            for (idx, _) in text.match_indices(custom.pattern.as_str()) {
                let start = idx;
                let end = idx + custom.pattern.len();
                if start < end {
                    out.push(Candidate {
                        start,
                        end,
                        tag: tag.clone(),
                        rule_key: rule_key.clone(),
                        priority: 92,
                    });
                }
            }
        }
    }
}

/// 脱敏主流程（使用系统当前时间）。
pub fn scrub_text(
    text: &str,
    config: &ScrubConfig,
    external_spans: &[ExternalEntitySpan],
) -> ScrubResult {
    scrub_text_at(text, config, external_spans, now_unix())
}

/// 脱敏主流程（可注入时间，供确定性测试与会话池过期验证）。
pub fn scrub_text_at(
    text: &str,
    config: &ScrubConfig,
    external_spans: &[ExternalEntitySpan],
    now: u64,
) -> ScrubResult {
    let mut vault = VAULT.lock();
    vault.ttl_seconds = config.session_ttl_seconds;
    vault.purge_expired(now, config.session_ttl_seconds);
    let mut candidates: Vec<Candidate> = Vec::new();
    collect_builtin_candidates(text, config, &mut candidates);
    collect_external_candidates(text, config, external_spans, &mut candidates);
    collect_custom_candidates(text, config, &mut candidates);

    let resolved = resolve_overlaps(candidates);
    if resolved.is_empty() {
        return ScrubResult {
            scrubbed_text: text.to_string(),
            has_replacements: false,
            replacements: Vec::new(),
            active_vault_count: vault.len() as u32,
        };
    }

    let mut out = String::with_capacity(text.len());
    let mut cursor = 0usize;
    let mut tallies: HashMap<String, (String, u32)> = HashMap::new();

    for cand in resolved {
        if cand.start > cursor {
            out.push_str(&text[cursor..cand.start]);
        }
        let original = &text[cand.start..cand.end];
        let placeholder = vault.intern(&cand.tag, original, now);
        let entry = tallies
            .entry(placeholder.clone())
            .or_insert_with(|| (cand.rule_key.clone(), 0));
        entry.1 += 1;
        out.push_str(&placeholder);
        cursor = cand.end;
    }
    if cursor < text.len() {
        out.push_str(&text[cursor..]);
    }

    let mut replacements: Vec<ScrubReplacementItem> = tallies
        .into_iter()
        .map(|(placeholder, (rule_key, count))| ScrubReplacementItem {
            placeholder,
            rule_key,
            count,
        })
        .collect();
    replacements.sort_by(|a, b| a.placeholder.cmp(&b.placeholder));

    let active_vault_count = vault.len() as u32;
    ScrubResult {
        has_replacements: !replacements.is_empty(),
        scrubbed_text: out,
        replacements,
        active_vault_count,
    }
}

// ---------------------------------------------------------------------------
// 8. 还原
// ---------------------------------------------------------------------------

static PLACEHOLDER_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"<([A-Z0-9][A-Z0-9_]*_[0-9]{1,4})>").expect("placeholder regex must compile")
});

// ---------------------------------------------------------------------------
// 8.5 只扫描不替换（粘贴前的「这条要不要脱敏」预检）
// ---------------------------------------------------------------------------

/// 预检结果：一次扫描的统计，**不写会话池**。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScrubScanResult {
    /// 命中的敏感片段数（区间归并后）
    pub hit_count: u32,
    /// 命中的规则 key（去重，按首次出现顺序）
    pub rule_keys: Vec<String>,
}

/// 扫描文本里有多少处敏感片段，但**不分配占位符、不触碰会话池**。
///
/// 与 `scrub_text` 的区别是「零副作用」：预览区要在用户每次选中条目时调用它，
/// 若走 `scrub_text`，光是点一下列表就会往映射表里塞满占位符，用户按 `⌃⇧⏎`
/// 时就会看见一堆从未粘贴过的「可还原」提示——既污染 UI，也白白占用 LRU 名额。
pub fn scan_text(text: &str, config: &ScrubConfig, external_spans: &[ExternalEntitySpan]) -> ScrubScanResult {
    if text.is_empty() {
        return ScrubScanResult {
            hit_count: 0,
            rule_keys: Vec::new(),
        };
    }

    let mut candidates: Vec<Candidate> = Vec::new();
    collect_builtin_candidates(text, config, &mut candidates);
    collect_external_candidates(text, config, external_spans, &mut candidates);
    collect_custom_candidates(text, config, &mut candidates);

    let resolved = resolve_overlaps(candidates);
    let mut rule_keys: Vec<String> = Vec::with_capacity(resolved.len());
    for cand in &resolved {
        if !rule_keys.contains(&cand.rule_key) {
            rule_keys.push(cand.rule_key.clone());
        }
    }
    ScrubScanResult {
        hit_count: resolved.len() as u32,
        rule_keys,
    }
}

/// 还原（使用系统当前时间）。
pub fn restore_text(text: &str) -> RestoreResult {
    restore_text_at(text, now_unix())
}

/// 还原（可注入时间）。
pub fn restore_text_at(text: &str, now: u64) -> RestoreResult {
    let mut vault = VAULT.lock();
    let ttl = vault.ttl_seconds;
    vault.purge_expired(now, ttl);
    if !text.contains('<') {
        return RestoreResult {
            restored_text: text.to_string(),
            restored_count: 0,
        };
    }

    let mut out = String::with_capacity(text.len());
    let mut cursor = 0usize;
    let mut restored = 0u32;

    for caps in PLACEHOLDER_REGEX.captures_iter(text) {
        let Some(full) = caps.get(0) else { continue };
        if full.start() < cursor {
            continue;
        }
        out.push_str(&text[cursor..full.start()]);
        // 关键：映射表的键是含尖括号的完整占位符（`<EMAIL_1>`），
        // 与 `intern` 写入时一致，否则永远查不到。
        match vault.lookup_and_touch(full.as_str(), now) {
            Some(original) => {
                out.push_str(&original);
                restored += 1;
            }
            None => out.push_str(full.as_str()),
        }
        cursor = full.end();
    }
    if cursor < text.len() {
        out.push_str(&text[cursor..]);
    }

    RestoreResult {
        restored_text: out,
        restored_count: restored,
    }
}

/// 文本中当前可还原（会话池仍存活）的占位符个数。
pub fn count_restorable_placeholders(text: &str) -> u32 {
    count_restorable_placeholders_at(text, now_unix())
}

pub fn count_restorable_placeholders_at(text: &str, now: u64) -> u32 {
    let mut vault = VAULT.lock();
    let ttl = vault.ttl_seconds;
    vault.purge_expired(now, ttl);
    if !text.contains('<') {
        return 0;
    }
    PLACEHOLDER_REGEX
        .captures_iter(text)
        .filter(|caps| {
            caps.get(0)
                .map(|m| vault.contains(m.as_str()))
                .unwrap_or(false)
        })
        .count() as u32
}

// ---------------------------------------------------------------------------
// 9. 会话池管理
// ---------------------------------------------------------------------------

/// 清空进程内存中的脱敏还原会话映射池。
pub fn clear_vault() {
    VAULT.lock().clear();
}

/// 当前会话池活跃条目数。
pub fn active_vault_count() -> u32 {
    VAULT.lock().len() as u32
}
