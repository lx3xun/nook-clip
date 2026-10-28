//! 文本差异对比算法（Inline Diff / `⌘D` 一键对比）
//!
//! 目标：把两段剪贴板文本（配置、代码两版、合同条款等）算成可渲染的
//! 「差异块（Hunk）→ 行（Line）→ 行内片段（Span）」三级结构，
//! 支持字词级红绿高亮与按块合并还原。
//!
//! 两级差异：
//! 1. **行级**：用最长公共子序列（LCS）对齐两侧行，得出新增/删除/未改动；
//! 2. **字词级**：对「成对的删除行 + 新增行」再做一次 token 级 LCS，
//!    把改动精确定位到「哪几个字/词」——这是超越传统整行红绿的关键。
//!
//! token 切分规则（中英文混排友好）：
//! - 英文单词 / 数字 / 下划线连续段 → 一个 token；
//! - 空白连续段 → 一个 token；
//! - 中文（含日文假名、韩文、CJK 符号与全角标点）→ 每个字单独一个 token；
//! - 其余标点符号 → 每个符号单独一个 token（便于 `,` → `;` 这类精确对比）。
//!
//! 合并语义：每个差异块可独立选择「保留新版（默认）/ 保留旧版 / 两者都保留」，
//! [`merge_diff_text`] 按选择拼回完整文本。所有块都选「保留新版」时，
//! 输出与 `new_text` **逐字节相等**；全选「保留旧版」时与 `old_text` 逐字节相等。
//! 这条不变量由单元测试保证，也是「一键复制合并版」的正确性底线。
//!
//! 超长护栏：[`DiffOptions::max_lines`] 限制参与对比的行数，
//! 超出部分不参与对比并置 `is_truncated`，避免主线程卡顿。

use std::collections::HashMap;

/// 行数上限默认值：超过此值只对比前 N 行（保护主线程与内存）。
pub const DEFAULT_MAX_LINES: usize = 1500;
/// 单行内 token 数上限默认值：超长的单行（如压缩后的 JSON）降级为整行差异。
pub const DEFAULT_MAX_INLINE_TOKENS: usize = 2000;
/// 行级 LCS 动态规划单元格上限（超过则整段视为「整体替换」）。
const MAX_DP_CELLS: usize = 4_000_000;
/// 行内 token 级 LCS 单元格上限。典型代码/条款行只有几十个 token，
/// 256×256 足够覆盖；超过则整行降级为新增/删除，避免超长行拖慢主线程。
const MAX_INLINE_DP_CELLS: usize = 65_536;

/// 差异片段类型
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiffTag {
    /// 两侧都有（未改动）
    Equal,
    /// 仅旧版有（会被删除）
    Delete,
    /// 仅新版有（新增）
    Insert,
}

/// 行内片段：一段连续同类型的文本
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffSpan {
    pub tag: DiffTag,
    /// 片段原文（拼接全部片段 = 该行原文）
    pub text: String,
    /// true = 行内**精确改动**的字词（高亮强调）；
    /// false = 未改动的上下文，或整行新增/删除（弱化显示）。
    pub emphasized: bool,
}

/// 一行差异的渲染数据
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffLine {
    pub tag: DiffTag,
    /// 旧版行号（1 起），0 表示该行不在旧版中
    pub old_line_no: u32,
    /// 新版行号（1 起），0 表示该行不在新版中
    pub new_line_no: u32,
    /// 行内片段序列，按顺序拼接即还原整行
    pub spans: Vec<DiffSpan>,
}

/// 差异块（Hunk）：连续的改动，或一段未改动的上下文
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffHunk {
    /// 块序号，从 0 起（合并时按此顺序取选择）
    pub id: u32,
    /// true = 有改动（可选择保留旧版/新版/双方）；false = 未改动的上下文块
    pub is_change: bool,
    /// 旧版起始行号（1 起），0 表示旧版没有对应行
    pub old_line_start: u32,
    /// 新版起始行号（1 起），0 表示新版没有对应行
    pub new_line_start: u32,
    /// 旧版该块的全部行文本（未改动块中与 new_lines 相同）
    pub old_lines: Vec<String>,
    /// 新版该块的全部行文本
    pub new_lines: Vec<String>,
    /// 逐行渲染数据。
    /// **契约**：改动块（`is_change = true`）填充此字段；
    /// 未改动上下文块留空，调用方直接用 `old_lines` 平铺渲染（可自行折叠长上下文）。
    pub lines: Vec<DiffLine>,
}

/// 单个差异块的合并选择
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HunkChoice {
    /// 保留新版（默认）
    KeepNew,
    /// 保留旧版
    KeepOld,
    /// 两者都保留（旧版在前）
    KeepBoth,
}

impl HunkChoice {
    /// 把 FFI 传入的 u8 编码转成合并选择：`0` = 新版，`1` = 旧版，`2` = 双方，
    /// 其余值按默认「保留新版」处理（容错，不 panic）。
    pub fn from_code(code: u8) -> Self {
        match code {
            1 => HunkChoice::KeepOld,
            2 => HunkChoice::KeepBoth,
            _ => HunkChoice::KeepNew,
        }
    }
}

/// 差异统计摘要（预览区顶部胶囊显示）
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffStats {
    /// 新增行数
    pub added_lines: u32,
    /// 删除行数
    pub removed_lines: u32,
    /// 有改动的块数
    pub changed_hunks: u32,
    /// 新增字词数（行内片段粒度）
    pub added_words: u32,
    /// 删除字词数（行内片段粒度）
    pub removed_words: u32,
    /// 相似度千分比（1000 = 完全相同，0 = 毫无重合）
    pub similarity_permille: u16,
    /// 两侧文本逐字节相同
    pub is_identical: bool,
    /// 因超出 `max_lines` 而截断，只对比了前 N 行
    pub is_truncated: bool,
}

/// 对比选项
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DiffOptions {
    /// 忽略空白差异：缩进、行内多空格与行尾空格都不算改动，
    /// 只比对文字本身（重新格式化过的代码/表格文本靠它滤掉排版噪音）。
    /// 注意它只影响「哪些行算相同」，不改变 `is_identical`（逐字节判断）。
    pub ignore_whitespace: bool,
    /// 忽略大小写差异
    pub ignore_case: bool,
    /// 参与对比的最大行数，0 表示用默认值
    pub max_lines: u32,
    /// 单行内 token 上限，0 表示用默认值
    pub max_inline_tokens: u32,
}

impl Default for DiffOptions {
    fn default() -> Self {
        Self {
            ignore_whitespace: false,
            ignore_case: false,
            max_lines: DEFAULT_MAX_LINES as u32,
            max_inline_tokens: DEFAULT_MAX_INLINE_TOKENS as u32,
        }
    }
}

impl DiffOptions {
    fn effective_max_lines(&self) -> usize {
        if self.max_lines == 0 {
            DEFAULT_MAX_LINES
        } else {
            self.max_lines as usize
        }
    }

    fn effective_max_inline_tokens(&self) -> usize {
        if self.max_inline_tokens == 0 {
            DEFAULT_MAX_INLINE_TOKENS
        } else {
            self.max_inline_tokens as usize
        }
    }
}

/// 对比结果
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextDiffResult {
    pub hunks: Vec<DiffHunk>,
    pub stats: DiffStats,
}

/// 内部：行级对齐操作
#[derive(Clone, Copy, Debug)]
enum RawOp {
    Equal(usize, usize),
    Delete(usize),
    Insert(usize),
}

/// 主入口：对比两段文本。
///
/// 返回的差异块按文档顺序排列，拼接所有块的 `new_lines`（默认合并）即完整新版文本。
pub fn diff_texts(old_text: &str, new_text: &str, options: DiffOptions) -> TextDiffResult {
    let is_identical = old_text == new_text;
    let max_lines = options.effective_max_lines();

    let mut old_lines: Vec<String> = old_text.split('\n').map(str::to_string).collect();
    let mut new_lines: Vec<String> = new_text.split('\n').map(str::to_string).collect();

    // 超长护栏：只保留前 max_lines 行（至少保留 1 行，避免空文档变成 0 行）
    let mut is_truncated = false;
    if old_lines.len() > max_lines {
        old_lines.truncate(max_lines);
        is_truncated = true;
    }
    if new_lines.len() > max_lines {
        new_lines.truncate(max_lines);
        is_truncated = true;
    }

    let ops = line_ops(&old_lines, &new_lines, &options);
    let matched_lines = ops
        .iter()
        .filter(|op| matches!(op, RawOp::Equal(_, _)))
        .count();

    let hunks = build_hunks(&ops, &old_lines, &new_lines, options);

    let mut added_lines = 0u32;
    let mut removed_lines = 0u32;
    let mut added_words = 0u32;
    let mut removed_words = 0u32;
    let mut changed_hunks = 0u32;
    for hunk in &hunks {
        if hunk.is_change {
            changed_hunks += 1;
        }
        for line in &hunk.lines {
            match line.tag {
                DiffTag::Delete => removed_lines += 1,
                DiffTag::Insert => added_lines += 1,
                DiffTag::Equal => {}
            }
            for span in &line.spans {
                if span.text.is_empty() {
                    continue;
                }
                match span.tag {
                    DiffTag::Delete => removed_words += 1,
                    DiffTag::Insert => added_words += 1,
                    DiffTag::Equal => {}
                }
            }
        }
    }

    let total = old_lines.len() + new_lines.len();
    let similarity_permille = if total == 0 {
        1000u16
    } else {
        let permille = (matched_lines as u64 * 2 * 1000) / total as u64;
        permille.min(1000) as u16
    };

    TextDiffResult {
        hunks,
        stats: DiffStats {
            added_lines,
            removed_lines,
            changed_hunks,
            added_words,
            removed_words,
            similarity_permille,
            is_identical,
            is_truncated,
        },
    }
}

/// 按每个块的合并选择拼出完整文本。
///
/// `choices` 与 `hunks` 按序号对应：`0` = 保留新版（默认），`1` = 保留旧版，
/// `2` = 两者都保留；缺省的块按「保留新版」处理。
pub fn merge_diff_text(hunks: &[DiffHunk], choices: &[u8]) -> String {
    let mut merged: Vec<&str> = Vec::new();
    for (index, hunk) in hunks.iter().enumerate() {
        let choice = choices
            .get(index)
            .copied()
            .map(HunkChoice::from_code)
            .unwrap_or(HunkChoice::KeepNew);
        // 未改动块两侧文本相同，统一取新版即可
        if !hunk.is_change {
            merged.extend(hunk.new_lines.iter().map(String::as_str));
            continue;
        }
        match choice {
            HunkChoice::KeepNew => merged.extend(hunk.new_lines.iter().map(String::as_str)),
            HunkChoice::KeepOld => merged.extend(hunk.old_lines.iter().map(String::as_str)),
            HunkChoice::KeepBoth => {
                merged.extend(hunk.old_lines.iter().map(String::as_str));
                merged.extend(hunk.new_lines.iter().map(String::as_str));
            }
        }
    }
    merged.join("\n")
}

// ---------------------------------------------------------------------------
// 行级对齐
// ---------------------------------------------------------------------------

fn line_ops(old_lines: &[String], new_lines: &[String], options: &DiffOptions) -> Vec<RawOp> {
    // 两侧必须共用同一张映射表，否则不同文本可能被编成同一个整数而误判为「相同行」
    let mut interner: HashMap<String, u32> =
        HashMap::with_capacity(old_lines.len() + new_lines.len());
    let old_keys = line_keys(old_lines, options, &mut interner);
    let new_keys = line_keys(new_lines, options, &mut interner);
    let matches = lcs_matches_bounded(&old_keys, &new_keys);

    let mut ops = Vec::with_capacity(old_lines.len().max(new_lines.len()) + 1);
    let mut old_cursor = 0usize;
    let mut new_cursor = 0usize;
    for (old_match, new_match) in matches {
        // 匹配点之前的旧版行都是删除
        for index in old_cursor..old_match {
            ops.push(RawOp::Delete(index));
        }
        // 匹配点之前的新版行都是新增
        for index in new_cursor..new_match {
            ops.push(RawOp::Insert(index));
        }
        ops.push(RawOp::Equal(old_match, new_match));
        old_cursor = old_match + 1;
        new_cursor = new_match + 1;
    }
    for index in old_cursor..old_lines.len() {
        ops.push(RawOp::Delete(index));
    }
    for index in new_cursor..new_lines.len() {
        ops.push(RawOp::Insert(index));
    }
    ops
}

/// 把一行里的空白折叠成单个空格并去掉首尾空白。
///
/// 这是「忽略空白」的真正含义：缩进、行内多空格、行尾空格都不算差异，
/// 只比对文字本身。只 trim 末尾是不够的——把代码重新格式化（2 空格变 4 空格）
/// 恰恰是用户想「只看逻辑改动」时最常见的噪音，而那类差异全在行首。
fn normalize_whitespace(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut pending_space = false;
    for ch in line.chars() {
        if ch.is_whitespace() {
            pending_space = !out.is_empty();
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(ch);
    }
    out
}

/// 把行文本归一化为可比较的 key（可选忽略空白/大小写），并映射为紧凑整数。
/// `interner` 由两侧共用，保证相同文本得到相同编号、不同文本得到不同编号。
fn line_keys(
    lines: &[String],
    options: &DiffOptions,
    interner: &mut HashMap<String, u32>,
) -> Vec<u32> {
    let mut keys = Vec::with_capacity(lines.len());
    for line in lines {
        let key = if options.ignore_whitespace {
            normalize_whitespace(line)
        } else {
            line.clone()
        };
        let key = if options.ignore_case {
            key.to_lowercase()
        } else {
            key
        };
        let next_id = interner.len() as u32;
        let id = *interner.entry(key).or_insert(next_id);
        keys.push(id);
    }
    keys
}

/// 带规模护栏的 LCS：先裁掉公共前后缀，再对中段做动态规划；
/// 中段过大时退化为「整段替换」，保证内存与时间可控。
fn lcs_matches_bounded(a: &[u32], b: &[u32]) -> Vec<(usize, usize)> {
    if a.is_empty() || b.is_empty() {
        return Vec::new();
    }

    // 公共前缀
    let mut prefix = 0usize;
    while prefix < a.len() && prefix < b.len() && a[prefix] == b[prefix] {
        prefix += 1;
    }
    // 公共后缀（不与前缀重叠）
    let mut suffix = 0usize;
    while suffix < a.len() - prefix
        && suffix < b.len() - prefix
        && a[a.len() - 1 - suffix] == b[b.len() - 1 - suffix]
    {
        suffix += 1;
    }

    let mid_a = &a[prefix..a.len() - suffix];
    let mid_b = &b[prefix..b.len() - suffix];

    let mut matches: Vec<(usize, usize)> = Vec::with_capacity(prefix + suffix + 8);
    for index in 0..prefix {
        matches.push((index, index));
    }

    if !mid_a.is_empty() && !mid_b.is_empty() {
        if mid_a.len().saturating_mul(mid_b.len()) > MAX_DP_CELLS {
            // 中段过大：不做细粒度对齐，交给 ops 生成一整块「删除 + 新增」
        } else {
            for (mid_old, mid_new) in lcs_matches(mid_a, mid_b) {
                matches.push((prefix + mid_old, prefix + mid_new));
            }
        }
    }

    for offset in (0..suffix).rev() {
        matches.push((
            a.len() - suffix + (suffix - 1 - offset),
            b.len() - suffix + (suffix - 1 - offset),
        ));
    }
    matches
}

/// 经典 LCS 动态规划（返回升序匹配下标对）。
/// 规模由调用方保证（行级 ≤ `max_lines`，token 级 ≤ `max_inline_tokens`）。
fn lcs_matches(a: &[u32], b: &[u32]) -> Vec<(usize, usize)> {
    let n = a.len();
    let m = b.len();
    if n == 0 || m == 0 {
        return Vec::new();
    }
    let width = m + 1;
    // dp[i][j] = LCS(a[i..], b[j..])；最大值为 min(n, m) ≤ max_lines，u16 足够
    let mut dp = vec![0u16; (n + 1) * width];
    for i in (0..n).rev() {
        let row = i * width;
        let next_row = (i + 1) * width;
        for j in (0..m).rev() {
            dp[row + j] = if a[i] == b[j] {
                dp[next_row + j + 1].saturating_add(1)
            } else {
                dp[next_row + j].max(dp[row + j + 1])
            };
        }
    }

    let mut matches = Vec::with_capacity(n.min(m));
    let (mut i, mut j) = (0usize, 0usize);
    while i < n && j < m {
        if a[i] == b[j] {
            matches.push((i, j));
            i += 1;
            j += 1;
        } else if dp[(i + 1) * width + j] >= dp[i * width + j + 1] {
            i += 1;
        } else {
            j += 1;
        }
    }
    matches
}

// ---------------------------------------------------------------------------
// 分块
// ---------------------------------------------------------------------------

fn build_hunks(
    ops: &[RawOp],
    old_lines: &[String],
    new_lines: &[String],
    options: DiffOptions,
) -> Vec<DiffHunk> {
    let mut hunks: Vec<DiffHunk> = Vec::new();
    let mut cursor = 0usize;
    while cursor < ops.len() {
        let is_equal_run = matches!(ops[cursor], RawOp::Equal(_, _));
        let mut end = cursor + 1;
        while end < ops.len() && matches!(ops[end], RawOp::Equal(_, _)) == is_equal_run {
            end += 1;
        }
        let run = &ops[cursor..end];
        if is_equal_run {
            let old_start = match run[0] {
                RawOp::Equal(old_index, _) => old_index,
                _ => 0,
            };
            let new_start = match run[0] {
                RawOp::Equal(_, new_index) => new_index,
                _ => 0,
            };
            let old_slice = old_lines[old_start..old_start + run.len()].to_vec();
            let new_slice = new_lines[new_start..new_start + run.len()].to_vec();
            hunks.push(DiffHunk {
                id: hunks.len() as u32,
                is_change: false,
                old_line_start: old_start as u32 + 1,
                new_line_start: new_start as u32 + 1,
                old_lines: old_slice,
                new_lines: new_slice,
                lines: Vec::new(),
            });
        } else {
            let mut old_indices = Vec::new();
            let mut new_indices = Vec::new();
            for op in run {
                match *op {
                    RawOp::Delete(index) => old_indices.push(index),
                    RawOp::Insert(index) => new_indices.push(index),
                    RawOp::Equal(_, _) => {}
                }
            }
            let mut lines: Vec<DiffLine> =
                Vec::with_capacity(old_indices.len() + new_indices.len());
            let paired = old_indices.len().min(new_indices.len());
            // 成对行做字词级对比，得到两侧的行内片段
            let mut old_pair_spans: Vec<Vec<DiffSpan>> = Vec::with_capacity(paired);
            let mut new_pair_spans: Vec<Vec<DiffSpan>> = Vec::with_capacity(paired);
            for pair in 0..paired {
                let old_line = &old_lines[old_indices[pair]];
                let new_line = &new_lines[new_indices[pair]];
                let (old_spans, new_spans) =
                    inline_spans(old_line, new_line, options.effective_max_inline_tokens());
                old_pair_spans.push(old_spans);
                new_pair_spans.push(new_spans);
            }
            // 与常见对比工具一致：先集中展示删除行，再集中展示新增行
            for (pair, old_index) in old_indices.iter().enumerate() {
                let spans = if pair < paired {
                    old_pair_spans[pair].clone()
                } else {
                    whole_line(&old_lines[*old_index], DiffTag::Delete)
                };
                lines.push(DiffLine {
                    tag: DiffTag::Delete,
                    old_line_no: *old_index as u32 + 1,
                    new_line_no: 0,
                    spans,
                });
            }
            for (pair, new_index) in new_indices.iter().enumerate() {
                let spans = if pair < paired {
                    new_pair_spans[pair].clone()
                } else {
                    whole_line(&new_lines[*new_index], DiffTag::Insert)
                };
                lines.push(DiffLine {
                    tag: DiffTag::Insert,
                    old_line_no: 0,
                    new_line_no: *new_index as u32 + 1,
                    spans,
                });
            }

            hunks.push(DiffHunk {
                id: hunks.len() as u32,
                is_change: true,
                old_line_start: old_indices.first().map(|i| *i as u32 + 1).unwrap_or(0),
                new_line_start: new_indices.first().map(|i| *i as u32 + 1).unwrap_or(0),
                old_lines: old_indices.iter().map(|i| old_lines[*i].clone()).collect(),
                new_lines: new_indices.iter().map(|i| new_lines[*i].clone()).collect(),
                lines,
            });
        }
        cursor = end;
    }
    hunks
}

// ---------------------------------------------------------------------------
// 字词级（token 级）对比
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum CharKind {
    /// 英文单词 / 数字 / 下划线连续段
    Word,
    /// 空白连续段
    Space,
    /// 中日韩文字：每个字单独成 token
    Cjk,
    /// 标点与符号：每个符号单独成 token
    Punct,
}

impl CharKind {
    /// 只有 Word 与 Space 会合并成连续段
    fn is_runs(self) -> bool {
        matches!(self, CharKind::Word | CharKind::Space)
    }
}

fn char_kind(ch: char) -> CharKind {
    if ch.is_whitespace() {
        CharKind::Space
    } else if is_cjk(ch) {
        CharKind::Cjk
    } else if ch.is_alphanumeric() || ch == '_' {
        CharKind::Word
    } else {
        CharKind::Punct
    }
}

/// 是否为中日韩文字/标点（按字符切分，保证中文改一个标点也能定位到）
fn is_cjk(ch: char) -> bool {
    matches!(
        ch as u32,
        0x1100..=0x11FF      // 韩文字母
        | 0x2E80..=0x2EFF    // CJK 部首补充
        | 0x3000..=0x303F    // CJK 符号与标点
        | 0x3040..=0x30FF    // 平假名、片假名
        | 0x3130..=0x318F    // 韩文兼容字母
        | 0x3400..=0x4DBF    // CJK 扩展 A
        | 0x4E00..=0x9FFF    // CJK 统一汉字
        | 0xAC00..=0xD7AF    // 韩文音节
        | 0xF900..=0xFAFF    // CJK 兼容汉字
        | 0xFF00..=0xFF60    // 全角字符
        | 0x20000..=0x2FA1F  // CJK 扩展 B~F
    )
}

/// 把文本切成 token 的字节区间（不复制字符串）
fn tokenize_inline(text: &str) -> Vec<(usize, usize)> {
    let mut tokens: Vec<(usize, usize)> = Vec::new();
    let mut iter = text.char_indices().peekable();
    while let Some((start, ch)) = iter.next() {
        let kind = char_kind(ch);
        let mut end = start + ch.len_utf8();
        if kind.is_runs() {
            while let Some(&(next_start, next_ch)) = iter.peek() {
                if char_kind(next_ch) == kind {
                    iter.next();
                    end = next_start + next_ch.len_utf8();
                } else {
                    break;
                }
            }
        }
        if kind == CharKind::Word {
            push_word_subtokens(text, start, end, &mut tokens);
        } else {
            tokens.push((start, end));
        }
    }
    tokens
}

/// 把一段英文单词再按「大小写驼峰 / 下划线」边界切开，分别压入 `tokens`。
///
/// 目的：`maxRetryCount` 与 `maxRetryTotal` 只差后缀时，只强调 `Count` / `Total`，
/// 而不是把整个标识符标成改动。切分规则：
/// - `_` 单独成 token（`max_retry_count` → `max` `_` `retry` `_` `count`）；
/// - 小写/数字 → 大写 处断开（`maxRetry` → `max` `Retry`）；
/// - 大写连跑 + 其后的「大写+小写」处断开（`HTTPServer` → `HTTP` `Server`）；
/// - 字母与数字之间不断开（`d1`、`v2` 保持整体），避免把版本号/变量名切碎。
fn push_word_subtokens(text: &str, start: usize, end: usize, tokens: &mut Vec<(usize, usize)>) {
    let word = &text[start..end];
    // 快路径：没有任何触发切分的字符（绝大多数 token 走这里）
    if !word.contains('_') && !word.char_indices().skip(1).any(|(_, ch)| ch.is_uppercase()) {
        tokens.push((start, end));
        return;
    }

    let chars: Vec<(usize, char)> = word.char_indices().collect();
    let mut token_start = 0usize; // 相对 word 的字节偏移
    for index in 1..chars.len() {
        let (offset, ch) = chars[index];
        let prev = chars[index - 1].1;
        let next_is_lower = chars.get(index + 1).is_some_and(|(_, c)| c.is_lowercase());
        let boundary = ch == '_'
            || prev == '_'
            || (ch.is_uppercase() && (prev.is_lowercase() || prev.is_numeric()))
            || (ch.is_uppercase() && prev.is_uppercase() && next_is_lower);
        if boundary {
            tokens.push((start + token_start, start + offset));
            token_start = offset;
        }
    }
    tokens.push((start + token_start, end));
}

fn whole_line(text: &str, tag: DiffTag) -> Vec<DiffSpan> {
    if text.is_empty() {
        return Vec::new();
    }
    vec![DiffSpan {
        tag,
        text: text.to_string(),
        emphasized: false,
    }]
}

fn push_span(spans: &mut Vec<DiffSpan>, tag: DiffTag, text: String, emphasized: bool) {
    if text.is_empty() {
        return;
    }
    if let Some(last) = spans.last_mut() {
        if last.tag == tag && last.emphasized == emphasized {
            last.text.push_str(&text);
            return;
        }
    }
    spans.push(DiffSpan {
        tag,
        text,
        emphasized,
    });
}

/// 对一对「旧行 / 新行」做 token 级对比，返回两侧各自的片段序列。
fn inline_spans(
    old_line: &str,
    new_line: &str,
    max_tokens: usize,
) -> (Vec<DiffSpan>, Vec<DiffSpan>) {
    let old_ranges = tokenize_inline(old_line);
    let new_ranges = tokenize_inline(new_line);
    // 超长单行（如压缩 JSON）：不做 token 级，降级为整行新增/删除
    if old_ranges.len() > max_tokens
        || new_ranges.len() > max_tokens
        || old_ranges.len().saturating_mul(new_ranges.len()) > MAX_INLINE_DP_CELLS
    {
        return (
            whole_line(old_line, DiffTag::Delete),
            whole_line(new_line, DiffTag::Insert),
        );
    }

    let old_tokens: Vec<&str> = old_ranges
        .iter()
        .map(|&(start, end)| &old_line[start..end])
        .collect();
    let new_tokens: Vec<&str> = new_ranges
        .iter()
        .map(|&(start, end)| &new_line[start..end])
        .collect();

    // 两侧共用映射表：同一 token 同号，不同 token 不同号
    let mut interner: HashMap<&str, u32> =
        HashMap::with_capacity(old_tokens.len() + new_tokens.len());
    let old_keys = intern_tokens(&old_tokens, &mut interner);
    let new_keys = intern_tokens(&new_tokens, &mut interner);
    let matches = lcs_matches(&old_keys, &new_keys);

    let mut old_spans: Vec<DiffSpan> = Vec::with_capacity(matches.len() * 2 + 1);
    let mut new_spans: Vec<DiffSpan> = Vec::with_capacity(matches.len() * 2 + 1);
    let mut old_cursor = 0usize;
    let mut new_cursor = 0usize;
    for (old_match, new_match) in matches {
        if old_match > old_cursor {
            push_span(
                &mut old_spans,
                DiffTag::Delete,
                old_tokens[old_cursor..old_match].concat(),
                true,
            );
        }
        if new_match > new_cursor {
            push_span(
                &mut new_spans,
                DiffTag::Insert,
                new_tokens[new_cursor..new_match].concat(),
                true,
            );
        }
        push_span(
            &mut old_spans,
            DiffTag::Equal,
            old_tokens[old_match].to_string(),
            false,
        );
        push_span(
            &mut new_spans,
            DiffTag::Equal,
            new_tokens[new_match].to_string(),
            false,
        );
        old_cursor = old_match + 1;
        new_cursor = new_match + 1;
    }
    if old_cursor < old_tokens.len() {
        push_span(
            &mut old_spans,
            DiffTag::Delete,
            old_tokens[old_cursor..].concat(),
            true,
        );
    }
    if new_cursor < new_tokens.len() {
        push_span(
            &mut new_spans,
            DiffTag::Insert,
            new_tokens[new_cursor..].concat(),
            true,
        );
    }
    (old_spans, new_spans)
}

fn intern_tokens<'a>(tokens: &[&'a str], interner: &mut HashMap<&'a str, u32>) -> Vec<u32> {
    let mut keys = Vec::with_capacity(tokens.len());
    for token in tokens {
        let next_id = interner.len() as u32;
        let id = *interner.entry(*token).or_insert(next_id);
        keys.push(id);
    }
    keys
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render_spans(spans: &[DiffSpan]) -> String {
        spans.iter().map(|s| s.text.as_str()).collect()
    }

    fn emphasized_texts(spans: &[DiffSpan], tag: DiffTag) -> Vec<String> {
        spans
            .iter()
            .filter(|s| s.tag == tag && s.emphasized)
            .map(|s| s.text.clone())
            .collect()
    }

    fn all_lines(hunks: &[DiffHunk]) -> Vec<&DiffLine> {
        hunks.iter().flat_map(|h| h.lines.iter()).collect()
    }

    #[test]
    fn test_identical_texts_no_change() {
        let result = diff_texts("hello\nworld", "hello\nworld", DiffOptions::default());
        assert!(result.stats.is_identical);
        assert_eq!(result.stats.changed_hunks, 0);
        assert_eq!(result.stats.similarity_permille, 1000);
        assert_eq!(result.hunks.len(), 1);
        assert!(!result.hunks[0].is_change);
        assert!(result.hunks[0].lines.is_empty());
    }

    #[test]
    fn test_added_line() {
        let result = diff_texts("a\nb", "a\nb\nc", DiffOptions::default());
        assert!(!result.stats.is_identical);
        assert_eq!(result.stats.added_lines, 1);
        assert_eq!(result.stats.removed_lines, 0);
        assert_eq!(result.stats.changed_hunks, 1);
        let change = result.hunks.iter().find(|h| h.is_change).unwrap();
        assert_eq!(change.new_lines, vec!["c".to_string()]);
        assert!(change.old_lines.is_empty());
        assert_eq!(change.lines.len(), 1);
        assert_eq!(change.lines[0].tag, DiffTag::Insert);
    }

    #[test]
    fn test_removed_line() {
        let result = diff_texts("a\nb\nc", "a\nc", DiffOptions::default());
        assert_eq!(result.stats.removed_lines, 1);
        assert_eq!(result.stats.added_lines, 0);
    }

    #[test]
    fn test_modified_line_marks_only_changed_word() {
        let result = diff_texts("let x = 1;", "let x = 2;", DiffOptions::default());
        let lines = all_lines(&result.hunks);
        assert_eq!(lines.len(), 2);
        // 删除行：只有被换掉的 "1" 被强调，"let x = " 与 ";" 保持普通
        let delete_line = lines.iter().find(|l| l.tag == DiffTag::Delete).unwrap();
        assert_eq!(render_spans(&delete_line.spans), "let x = 1;");
        assert_eq!(
            emphasized_texts(&delete_line.spans, DiffTag::Delete),
            vec!["1".to_string()]
        );
        let insert_line = lines.iter().find(|l| l.tag == DiffTag::Insert).unwrap();
        assert_eq!(render_spans(&insert_line.spans), "let x = 2;");
        assert_eq!(
            emphasized_texts(&insert_line.spans, DiffTag::Insert),
            vec!["2".to_string()]
        );
    }

    #[test]
    fn test_chinese_char_level_emphasis() {
        let result = diff_texts("今天天气很好", "今天天气不好", DiffOptions::default());
        let lines = all_lines(&result.hunks);
        let delete_line = lines.iter().find(|l| l.tag == DiffTag::Delete).unwrap();
        assert_eq!(render_spans(&delete_line.spans), "今天天气很好");
        assert_eq!(
            emphasized_texts(&delete_line.spans, DiffTag::Delete),
            vec!["很".to_string()]
        );
        let insert_line = lines.iter().find(|l| l.tag == DiffTag::Insert).unwrap();
        assert_eq!(
            emphasized_texts(&insert_line.spans, DiffTag::Insert),
            vec!["不".to_string()]
        );
    }

    #[test]
    fn test_chinese_punctuation_change() {
        let result = diff_texts(
            "合同金额：100元。",
            "合同金额：100元，",
            DiffOptions::default(),
        );
        let lines = all_lines(&result.hunks);
        let delete_line = lines.iter().find(|l| l.tag == DiffTag::Delete).unwrap();
        assert_eq!(
            emphasized_texts(&delete_line.spans, DiffTag::Delete),
            vec!["。".to_string()]
        );
    }

    #[test]
    fn test_merge_keep_new_reproduces_new_text() {
        let old = "# 配置\nport: 8080\nhost: localhost\n# tail";
        let new = "# 配置\nport: 9090\nhost: localhost\n# tail\n# extra";
        let result = diff_texts(old, new, DiffOptions::default());
        let merged = merge_diff_text(&result.hunks, &[]);
        assert_eq!(merged, new);
    }

    #[test]
    fn test_merge_keep_old_reproduces_old_text() {
        let old = "a\nb\nc\nd";
        let new = "a\nB\nc\nD\ne";
        let result = diff_texts(old, new, DiffOptions::default());
        let choices: Vec<u8> = result.hunks.iter().map(|_| 1u8).collect();
        let merged = merge_diff_text(&result.hunks, &choices);
        assert_eq!(merged, old);
    }

    #[test]
    fn test_merge_keep_both_concatenates() {
        let result = diff_texts("a\nb", "a\nc", DiffOptions::default());
        let choices: Vec<u8> = result.hunks.iter().map(|_| 2u8).collect();
        let merged = merge_diff_text(&result.hunks, &choices);
        assert_eq!(merged, "a\nb\nc");
    }

    #[test]
    fn test_merge_mixed_choices() {
        let old = "1\n2\n3\n4\n5";
        let new = "1\nX\n3\nY\n5";
        let result = diff_texts(old, new, DiffOptions::default());
        // 第 0 块是上下文 "1"，第 1 块是 2→X，第 2 块上下文 "3"，第 3 块 4→Y，第 4 块上下文 "5"
        let mut choices = vec![0u8; result.hunks.len()];
        let change_indexes: Vec<usize> = result
            .hunks
            .iter()
            .enumerate()
            .filter(|(_, h)| h.is_change)
            .map(|(i, _)| i)
            .collect();
        choices[change_indexes[0]] = 1; // 第一个改动保留旧版
        let merged = merge_diff_text(&result.hunks, &choices);
        assert_eq!(merged, "1\n2\n3\nY\n5");
    }

    #[test]
    fn test_empty_old_text() {
        let result = diff_texts("", "hello", DiffOptions::default());
        assert_eq!(result.stats.added_lines, 1);
        assert_eq!(merge_diff_text(&result.hunks, &[]), "hello");
    }

    #[test]
    fn test_empty_new_text() {
        let result = diff_texts("hello", "", DiffOptions::default());
        assert_eq!(result.stats.removed_lines, 1);
        assert_eq!(merge_diff_text(&result.hunks, &[]), "");
    }

    #[test]
    fn test_both_empty() {
        let result = diff_texts("", "", DiffOptions::default());
        assert!(result.stats.is_identical);
        assert_eq!(merge_diff_text(&result.hunks, &[]), "");
    }

    #[test]
    fn test_trailing_newline_roundtrip() {
        let old = "a\nb\n";
        let new = "a\nc\n";
        let result = diff_texts(old, new, DiffOptions::default());
        assert_eq!(merge_diff_text(&result.hunks, &[]), new);
        let choices: Vec<u8> = result.hunks.iter().map(|_| 1u8).collect();
        assert_eq!(merge_diff_text(&result.hunks, &choices), old);
    }

    #[test]
    fn test_crlf_roundtrip() {
        let old = "a\r\nb\r\n";
        let new = "a\r\nc\r\n";
        let result = diff_texts(old, new, DiffOptions::default());
        assert_eq!(merge_diff_text(&result.hunks, &[]), new);
    }

    #[test]
    fn test_no_trailing_newline_preserved() {
        let old = "a\nb";
        let new = "a\nb\nc";
        let result = diff_texts(old, new, DiffOptions::default());
        assert_eq!(merge_diff_text(&result.hunks, &[]), new);
    }

    #[test]
    fn test_truncation_flag() {
        let old = "1\n2\n3\n4\n5";
        let new = "1\n2\n3\n4\nX";
        let options = DiffOptions {
            max_lines: 3,
            ..DiffOptions::default()
        };
        let result = diff_texts(old, new, options);
        assert!(result.stats.is_truncated);
    }

    #[test]
    fn test_ignore_whitespace() {
        let old = "a\nb   ";
        let new = "a\nb";
        let plain = diff_texts(old, new, DiffOptions::default());
        assert_eq!(plain.stats.changed_hunks, 1);

        let options = DiffOptions {
            ignore_whitespace: true,
            ..DiffOptions::default()
        };
        let ignored = diff_texts(old, new, options);
        assert_eq!(ignored.stats.changed_hunks, 0);
        // 不影响逐字节一致性判断
        assert!(!ignored.stats.is_identical);
    }

    #[test]
    fn test_ignore_case() {
        let options = DiffOptions {
            ignore_case: true,
            ..DiffOptions::default()
        };
        let result = diff_texts("Hello", "hello", options);
        assert_eq!(result.stats.changed_hunks, 0);
        let strict = diff_texts("Hello", "hello", DiffOptions::default());
        assert_eq!(strict.stats.changed_hunks, 1);
    }

    #[test]
    fn test_more_new_lines_than_old() {
        let old = "a\nb\nc";
        let new = "a\nb1\nb2\nb3\nc";
        let result = diff_texts(old, new, DiffOptions::default());
        let change = result.hunks.iter().find(|h| h.is_change).unwrap();
        assert_eq!(change.old_lines, vec!["b".to_string()]);
        assert_eq!(
            change.new_lines,
            vec!["b1".to_string(), "b2".to_string(), "b3".to_string()]
        );
        // 未成对的多余行按整行新增处理（不强调行内字词）
        assert_eq!(merge_diff_text(&result.hunks, &[]), new);
    }

    #[test]
    fn test_more_old_lines_than_new() {
        let old = "a\nb1\nb2\nb3\nc";
        let new = "a\nb\nc";
        let result = diff_texts(old, new, DiffOptions::default());
        assert_eq!(merge_diff_text(&result.hunks, &[]), new);
        let choices: Vec<u8> = result.hunks.iter().map(|_| 1u8).collect();
        assert_eq!(merge_diff_text(&result.hunks, &choices), old);
    }

    #[test]
    fn test_completely_different_texts() {
        let result = diff_texts("aaa\nbbb", "xxx\nyyy", DiffOptions::default());
        assert_eq!(result.stats.similarity_permille, 0);
        assert_eq!(result.stats.added_lines, 2);
        assert_eq!(result.stats.removed_lines, 2);
    }

    #[test]
    fn test_hunk_ids_are_sequential() {
        let result = diff_texts("a\nb\nc\nd\ne", "a\nB\nc\nD\ne", DiffOptions::default());
        for (index, hunk) in result.hunks.iter().enumerate() {
            assert_eq!(hunk.id, index as u32);
        }
    }

    #[test]
    fn test_line_numbers_are_one_based() {
        let result = diff_texts("a\nb", "a\nc", DiffOptions::default());
        let change = result.hunks.iter().find(|h| h.is_change).unwrap();
        assert_eq!(change.old_line_start, 2);
        assert_eq!(change.new_line_start, 2);
        let delete_line = change
            .lines
            .iter()
            .find(|l| l.tag == DiffTag::Delete)
            .unwrap();
        assert_eq!(delete_line.old_line_no, 2);
        assert_eq!(delete_line.new_line_no, 0);
        let insert_line = change
            .lines
            .iter()
            .find(|l| l.tag == DiffTag::Insert)
            .unwrap();
        assert_eq!(insert_line.old_line_no, 0);
        assert_eq!(insert_line.new_line_no, 2);
    }

    #[test]
    fn test_span_concat_restores_line() {
        let old = "let a = { x: 1, y: 2 };";
        let new = "let a = { x: 10, y: 2, z: 3 };";
        let result = diff_texts(old, new, DiffOptions::default());
        let lines = all_lines(&result.hunks);
        for line in lines {
            let rebuilt = render_spans(&line.spans);
            if line.tag == DiffTag::Delete {
                assert_eq!(rebuilt, old);
            } else if line.tag == DiffTag::Insert {
                assert_eq!(rebuilt, new);
            }
        }
    }

    #[test]
    fn test_json_pretty_vs_compact_is_line_diff() {
        let pretty = "{\n  \"a\": 1,\n  \"b\": 2\n}";
        let compact = "{\"a\":1,\"b\":2}";
        let result = diff_texts(pretty, compact, DiffOptions::default());
        assert!(result.stats.changed_hunks > 0);
        assert_eq!(merge_diff_text(&result.hunks, &[]), compact);
    }

    #[test]
    fn test_very_long_single_line_falls_back() {
        // 每个字母后带空格 → 自身就是 11 个 token，远超 max_inline_tokens = 3
        let old = "a b c d e f g h i j k";
        let new = "l m n o p q r s t u v";
        let options = DiffOptions {
            max_inline_tokens: 3,
            ..DiffOptions::default()
        };
        let result = diff_texts(old, new, options);
        let lines = all_lines(&result.hunks);
        // 降级为整行：不应有 emphasized 片段
        assert!(lines
            .iter()
            .flat_map(|l| l.spans.iter())
            .all(|s| !s.emphasized));
        assert_eq!(merge_diff_text(&result.hunks, &[]), new);
    }

    #[test]
    fn test_whitespace_only_change_is_emphasized() {
        let result = diff_texts("a b", "a  b", DiffOptions::default());
        let lines = all_lines(&result.hunks);
        let insert_line = lines.iter().find(|l| l.tag == DiffTag::Insert).unwrap();
        // 新版多出来的两个连续空格整段被标为精确改动
        assert_eq!(
            emphasized_texts(&insert_line.spans, DiffTag::Insert),
            vec!["  ".to_string()]
        );
        let delete_line = lines.iter().find(|l| l.tag == DiffTag::Delete).unwrap();
        assert_eq!(
            emphasized_texts(&delete_line.spans, DiffTag::Delete),
            vec![" ".to_string()]
        );
    }

    #[test]
    fn test_hunk_choice_from_code_fallback() {
        assert_eq!(HunkChoice::from_code(0), HunkChoice::KeepNew);
        assert_eq!(HunkChoice::from_code(1), HunkChoice::KeepOld);
        assert_eq!(HunkChoice::from_code(2), HunkChoice::KeepBoth);
        assert_eq!(HunkChoice::from_code(99), HunkChoice::KeepNew);
    }

    #[test]
    fn test_tokenizer_splits_words_and_cjk() {
        let tokens = tokenize_inline("abc中文, d1");
        let texts: Vec<&str> = tokens.iter().map(|&(s, e)| &"abc中文, d1"[s..e]).collect();
        assert_eq!(texts, vec!["abc", "中", "文", ",", " ", "d1"]);
    }

    #[test]
    fn test_tokenizer_splits_camel_case() {
        let text = "maxRetryCount";
        let texts: Vec<&str> = tokenize_inline(text)
            .iter()
            .map(|&(s, e)| &text[s..e])
            .collect();
        assert_eq!(texts, vec!["max", "Retry", "Count"]);
    }

    #[test]
    fn test_tokenizer_splits_consecutive_uppercase() {
        let text = "HTTPServerURL";
        let texts: Vec<&str> = tokenize_inline(text)
            .iter()
            .map(|&(s, e)| &text[s..e])
            .collect();
        assert_eq!(texts, vec!["HTTP", "Server", "URL"]);
    }

    #[test]
    fn test_tokenizer_keeps_snake_case_separator() {
        let text = "max_retry_count";
        let texts: Vec<&str> = tokenize_inline(text)
            .iter()
            .map(|&(s, e)| &text[s..e])
            .collect();
        assert_eq!(texts, vec!["max", "_", "retry", "_", "count"]);
    }

    #[test]
    fn test_tokenizer_keeps_letter_digit_together() {
        // d1 / v2 这类短标识符不应被切碎，否则强调会很吵
        let text = "d1 v2 base64";
        let texts: Vec<&str> = tokenize_inline(text)
            .iter()
            .map(|&(s, e)| &text[s..e])
            .collect();
        assert_eq!(texts, vec!["d1", " ", "v2", " ", "base64"]);
    }

    #[test]
    fn test_camel_case_rename_emphasizes_only_suffix() {
        let result = diff_texts("maxRetryCount", "maxRetryTotal", DiffOptions::default());
        let lines = all_lines(&result.hunks);
        let delete_line = lines.iter().find(|l| l.tag == DiffTag::Delete).unwrap();
        assert_eq!(
            emphasized_texts(&delete_line.spans, DiffTag::Delete),
            vec!["Count".to_string()]
        );
        let insert_line = lines.iter().find(|l| l.tag == DiffTag::Insert).unwrap();
        assert_eq!(
            emphasized_texts(&insert_line.spans, DiffTag::Insert),
            vec!["Total".to_string()]
        );
        // 片段拼接必须仍能还原整行
        assert_eq!(render_spans(&delete_line.spans), "maxRetryCount");
        assert_eq!(render_spans(&insert_line.spans), "maxRetryTotal");
    }

    #[test]
    fn test_word_subtokens_cover_whole_word_without_gaps() {
        for word in [
            "maxRetryCount",
            "max_retry_count",
            "HTTPServerURL",
            "d1",
            "_x_",
            "ABC",
        ] {
            let tokens = tokenize_inline(word);
            let reconstructed: String = tokens.iter().map(|&(s, e)| &word[s..e]).collect();
            assert_eq!(reconstructed, word, "token 必须无缝覆盖原文：{word}");
            assert!(
                tokens.iter().all(|&(s, e)| s < e),
                "不应产生空 token：{word}"
            );
        }
    }

    #[test]
    fn test_large_text_guard_does_not_hang() {
        // 1500 行完全不同的文本：走 DP 上限保护，必须快速返回
        let old: String = (0..1500)
            .map(|i| format!("old line {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let new: String = (0..1500)
            .map(|i| format!("new line {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let result = diff_texts(&old, &new, DiffOptions::default());
        assert_eq!(merge_diff_text(&result.hunks, &[]), new);
    }
}
