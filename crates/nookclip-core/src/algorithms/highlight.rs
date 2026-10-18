/// 搜索命中区间（含 UTF-8 字节偏移与 Unicode 标量/字符偏移，方便 Rust/C/Swift/Kotlin 各端零转换使用）
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HighlightRange {
    pub start_byte: u32,
    pub end_byte: u32,
    pub start_char: u32,
    pub end_char: u32,
}

/// 计算 text 中所有关键词的大小写不敏感命中区间（升序、跨关键词合并重叠与相邻区间）。
/// 单关键词内自左向右不重叠扫描。
pub fn match_search_ranges(text: &str, keywords: &[String]) -> Vec<HighlightRange> {
    if text.is_empty() || keywords.is_empty() {
        return Vec::new();
    }

    // 将原文本展开为 (char_idx, byte_idx, char)
    // 为了精确处理 Unicode 大小写折叠（如单字符或 ASCII/拉丁字符）并保持原串区间边界，
    // 按原文本每个 char 的小写序列匹配。
    let text_chars: Vec<(usize, usize, char)> = text
        .char_indices()
        .enumerate()
        .map(|(char_i, (byte_i, ch))| (char_i, byte_i, ch))
        .collect();
    let total_chars = text_chars.len();
    if total_chars == 0 {
        return Vec::new();
    }

    // 小写序列整体一次生成，再按「每个原 char 的小写字符段」切分：
    // 绝大多数字符小写后仍是单字符，少数 Unicode 折叠会展开为多字符。
    // 匹配在小写序列上进行，命中时用 lower_span 反查原 char 区间，
    // 既保持 char 粒度语义，又把逐字符堆分配降为一次分配。
    let lower_text = text.to_lowercase();
    let mut lower_chars: Vec<char> = Vec::with_capacity(lower_text.len());
    let mut lower_span: Vec<(usize, usize)> = Vec::with_capacity(total_chars + 1);
    // 原文本与小写文本逐 char 同步推进：每个原字符消耗
    // ch.lowercase().count() 个小写字符。
    let mut lower_iter = lower_text.chars();
    for (_, _, ch) in &text_chars {
        let need = ch.to_lowercase().count();
        let start = lower_chars.len();
        for _ in 0..need {
            let Some(lc) = lower_iter.next() else { break };
            lower_chars.push(lc);
        }
        lower_span.push((start, lower_chars.len()));
    }
    let text_lower = &lower_chars;

    let mut found_char_ranges: Vec<(usize, usize)> = Vec::new();

    for keyword in keywords {
        if keyword.is_empty() {
            continue;
        }
        let kw_lower: Vec<char> = keyword.to_lowercase().chars().collect();
        let kw_len = kw_lower.len();
        // 只能用小写序列长度比较：Unicode 折叠可能让 1 个原字符展开成多个
        // 小写字符（如 İ → i + 组合点），按原 char 数比较会漏报完全匹配。
        if kw_len == 0 || kw_len > text_lower.len() {
            continue;
        }

        let mut cursor = 0;
        while cursor + kw_len <= text_lower.len() {
            let mut matched = true;
            for i in 0..kw_len {
                if text_lower[cursor + i] != kw_lower[i] {
                    matched = false;
                    break;
                }
            }
            if matched {
                // 把小写序列区间映射回原 char 区间。lower_span[i] = 第 i 个原字符
                // 占用的小写字符区间，天然按起点升序，用二分定位避免 O(N) 重扫。
                let start_c = lower_span.partition_point(|&(_, e)| e <= cursor);
                let end_cursor = cursor + kw_len;
                let end_c = if end_cursor >= text_lower.len() {
                    total_chars
                } else {
                    // 最后一个起点 < end_cursor 的段之后再切一刀
                    lower_span.partition_point(|&(s, _)| s < end_cursor)
                };
                found_char_ranges.push((start_c.min(total_chars), end_c.min(total_chars)));
                cursor += kw_len;
            } else {
                cursor += 1;
            }
        }
    }

    if found_char_ranges.is_empty() {
        return Vec::new();
    }

    found_char_ranges.sort_by_key(|&(start, _)| start);

    let mut merged: Vec<(usize, usize)> = Vec::with_capacity(found_char_ranges.len());
    for (start, end) in found_char_ranges {
        if let Some(last) = merged.last_mut() {
            if start <= last.1 {
                if end > last.1 {
                    last.1 = end;
                }
                continue;
            }
        }
        merged.push((start, end));
    }

    let text_byte_len = text.len();
    merged
        .into_iter()
        .map(|(start_c, end_c)| {
            let start_b = text_chars[start_c].1;
            let end_b = if end_c < total_chars {
                text_chars[end_c].1
            } else {
                text_byte_len
            };
            HighlightRange {
                start_byte: start_b as u32,
                end_byte: end_b as u32,
                start_char: start_c as u32,
                end_char: end_c as u32,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn extract<'a>(text: &'a str, ranges: &[HighlightRange]) -> Vec<&'a str> {
        ranges
            .iter()
            .map(|r| &text[r.start_byte as usize..r.end_byte as usize])
            .collect()
    }

    #[test]
    fn test_single_keyword_all_occurrences_and_case_insensitive() {
        let text = "abcABCab";
        let ranges = match_search_ranges(text, &["ab".to_string()]);
        assert_eq!(extract(text, &ranges), vec!["ab", "AB", "ab"]);
    }

    #[test]
    fn test_overlapping_and_adjacent_merged() {
        let text = "abcd";
        let r1 = match_search_ranges(text, &["abc".to_string(), "bcd".to_string()]);
        assert_eq!(extract(text, &r1), vec!["abcd"]);

        let r2 = match_search_ranges(text, &["ab".to_string(), "cd".to_string()]);
        assert_eq!(extract(text, &r2), vec!["abcd"]);
    }

    #[test]
    fn test_cjk_and_emoji_offsets() {
        let text = "前缀🎉中文字段Hello世界";
        let ranges = match_search_ranges(text, &["中文".to_string(), "hello".to_string()]);
        assert_eq!(extract(text, &ranges), vec!["中文", "Hello"]);
        assert_eq!(ranges[0].start_char, 3);
        assert_eq!(ranges[0].end_char, 5);
    }

    #[test]
    fn test_unicode_fold_expands_beyond_char_count() {
        // İ (U+0130) 小写展开为 i + U+0307：关键词小写长度(2) > 原文本字符数(1)，
        // 不能因此跳过匹配。
        let text = "İstanbul";
        let ranges = match_search_ranges(text, &["İ".to_string()]);
        assert_eq!(extract(text, &ranges), vec!["İ"]);
        assert_eq!(ranges[0].start_char, 0);
        assert_eq!(ranges[0].end_char, 1);
    }

    #[test]
    fn test_empty_cases() {
        assert!(match_search_ranges("abc", &["".to_string(), "z".to_string()]).is_empty());
        assert!(match_search_ranges("", &["a".to_string()]).is_empty());
    }
}
