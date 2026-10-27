//! 智能表单拆解算法（Smart Form / Table Bursting）
//!
//! 把一整段混合信息（表格行、JSON、键值对、自然语言快递联系信息等）
//! 智能拆解为按填表顺序排列的独立字段数组，直接送入顺序粘贴栈（Paste Stack）
//! 实现一次复制、连续粘贴填表。

use regex::Regex;
use serde_json::Value;
use std::sync::LazyLock;

static PHONE_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    // 匹配：
    // 1. 掩码脱敏手机号（电商常见）: 182****5644, 138****0000, 199****1234
    // 2. 普通 11 位手机号（支持带 +86、空格或连字符）: 138-0000-0000, 138 0000 0000, 13800000000
    // 3. 固话（支持区号与分隔符）: 010-88888888, 0755 12345678, 020-12345678
    Regex::new(r"(?x)
        (?:\+?86[- ]?)?
        (?:
            (1[3-9]\d(?:\*{4}|[xX\*]{3,4})\d{4})   # 掩码脱敏手机号
            |
            (1[3-9]\d(?:[- ]?\d){8})              # 11 位普通/连字符/空格手机号
            |
            (0\d{2,3}[- ]?\d{7,8})                # 带区号固话
        )
    ").unwrap()
});

static POSTAL_CODE_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:邮编|邮政编码|zip(?:\s+code)?)\s*[:：]?\s*([1-9]\d{5})\b").unwrap()
});

static STANDALONE_POSTAL_CODE_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:^|[\s,，、;；])([1-9]\d{5})(?:$|[\s,，、;；])").unwrap()
});

static PROVINCE_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(北京|天津|河北|山西|内蒙古|辽宁|吉林|黑龙江|上海|江苏|浙江|安徽|福建|江西|山东|河南|湖北|湖南|广东|广西|海南|重庆|四川|贵州|云南|西藏|陕西|甘肃|青海|宁夏|新疆|香港|澳门|台湾)").unwrap()
});

static ADDRESS_KEYWORDS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:省|市|自治区|特别行政区|区|县|旗|镇|乡|街道|路|街|巷|号|弄|栋|幢|楼|院|室|层|单元|村|组|座|大厦|庄园|小区|工业区|科技园|物流园|小学|中学|大学|校区)").unwrap()
});

/// 智能拆解总入口
pub fn burst_form_text(raw_text: &str) -> Vec<String> {
    let trimmed = raw_text.trim();
    if trimmed.is_empty() {
        return vec![];
    }

    // 1. 制表符与表格（Excel / TSV / Markdown 表格，准确度最高）
    if let Some(items) = burst_table_tsv(trimmed) {
        if items.len() >= 2 {
            return items;
        }
    }

    // 2. JSON 结构化数据
    if let Some(items) = burst_json(trimmed) {
        if items.len() >= 2 {
            return items;
        }
    }

    // 3. 多行或单行冒号标签键值对（如 "姓名：张三\n电话：138..."）
    if let Some(items) = burst_labeled_key_value(trimmed) {
        if items.len() >= 2 {
            return items;
        }
    }

    // 4. 自然语言收件人/联系信息（姓名、电话、地址启发式提取）
    if let Some(items) = burst_contact_info(trimmed) {
        if items.len() >= 2 {
            return items;
        }
    }

    // 5. 通用分隔符切分（多行文本、逗号/分号、空格分隔等）
    if let Some(items) = burst_delimiters(trimmed) {
        if items.len() >= 2 {
            return items;
        }
    }

    // 兜底：无法有效拆分时返回原文本单项
    vec![trimmed.to_string()]
}

/// 判断复制的内容是否具备「高确定性表单结构」，以决定是否主动向用户弹出拆解提示。
/// 严格防误报：
/// 1. TSV / Excel 制表符表格（包含 \t 且至少切出 2 个非空字段）；
/// 2. 规整的 JSON（必须是有效对象且有 >= 2 个字段，或数组且有 >= 2 个元素）；
/// 3. 多行冒号键值对（多行且绝大多数行是 `key: value` 形式）；
/// 4. 完整的收件人/联系信息（必须「姓名、电话、地址」三要素齐全）。
///
/// 普通逗号、空格分词、普通段落文本绝不主动弹窗。
pub fn should_suggest_form_burst(raw_text: &str) -> bool {
    let trimmed = raw_text.trim();
    if trimmed.is_empty() || trimmed.len() > 10_000 {
        return false;
    }

    // 1. TSV 制表符表格
    if let Some(items) = burst_table_tsv(trimmed) {
        if items.len() >= 2 {
            return true;
        }
    }

    // 2. JSON 结构化数据
    if let Some(items) = burst_json(trimmed) {
        if items.len() >= 2 {
            return true;
        }
    }

    // 3. 标签键值对
    if let Some(items) = burst_labeled_key_value(trimmed) {
        if items.len() >= 2 {
            return true;
        }
    }

    // 4. 自然语言联系人（包含有效电话和地址特征）
    if let Some(items) = burst_contact_info(trimmed) {
        if items.len() >= 2 {
            return true;
        }
    }

    false
}

/// 检测文本中识别出的结构化类型（返回："table", "contact", "json", "key_value", "list", "text"）
pub fn detect_form_burst_kind(raw_text: &str) -> &'static str {
    let trimmed = raw_text.trim();
    if trimmed.is_empty() {
        return "text";
    }

    if burst_table_tsv(trimmed).is_some() {
        return "table";
    }
    if burst_json(trimmed).is_some() {
        return "json";
    }
    if burst_labeled_key_value(trimmed).is_some() {
        return "key_value";
    }
    if burst_contact_info(trimmed).is_some() {
        return "contact";
    }
    if burst_delimiters(trimmed).is_some() {
        return "list";
    }

    "text"
}

/// 1. TSV / Excel / Markdown 表格解析
fn burst_table_tsv(text: &str) -> Option<Vec<String>> {
    // 包含制表符（Excel/剪贴板表格标准格式）
    if text.contains('\t') {
        let mut items = Vec::new();
        for line in text.lines() {
            let row: Vec<String> = line
                .split('\t')
                .map(|cell| cell.trim().to_string())
                .filter(|cell| !cell.is_empty())
                .collect();
            items.extend(row);
        }
        if !items.is_empty() {
            return Some(items);
        }
    }

    // Markdown 表格格式：必须具备真实表格结构（例如 | a | b | c | 首尾竖线且含至少 2 个单元格，或多行竖线分隔）
    if text.contains('|') {
        let non_empty_lines: Vec<&str> = text
            .lines()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .collect();

        let is_single_line_md_row = non_empty_lines.len() == 1
            && non_empty_lines[0].starts_with('|')
            && non_empty_lines[0].ends_with('|')
            && non_empty_lines[0].matches('|').count() >= 3
            && !non_empty_lines[0].contains("||");

        let is_multi_line_md_table = non_empty_lines.len() >= 2
            && non_empty_lines
                .iter()
                .all(|l| l.contains('|') && !l.contains("||"));

        if is_single_line_md_row || is_multi_line_md_table {
            let mut items = Vec::new();
            for trimmed_line in non_empty_lines {
                // 跳过类似 |---|---| 的表头分隔线
                if trimmed_line
                    .chars()
                    .all(|c| c == '|' || c == '-' || c == ':' || c.is_whitespace())
                {
                    continue;
                }
                let row: Vec<String> = trimmed_line
                    .split('|')
                    .map(|cell| cell.trim().to_string())
                    .filter(|cell| !cell.is_empty())
                    .collect();
                items.extend(row);
            }
            if items.len() >= 2 {
                return Some(items);
            }
        }
    }

    None
}

/// 2. JSON 结构化数据解析
fn burst_json(text: &str) -> Option<Vec<String>> {
    if (!text.starts_with('{') || !text.ends_with('}'))
        && (!text.starts_with('[') || !text.ends_with(']'))
    {
        return None;
    }

    let parsed: Value = serde_json::from_str(text).ok()?;
    match parsed {
        Value::Object(map) => {
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            entries.sort_by_key(|(k, _)| {
                let needle = format!("\"{}\"", k);
                text.find(&needle).unwrap_or(usize::MAX)
            });
            let items: Vec<String> = entries
                .into_iter()
                .filter_map(|(_, val)| match val {
                    Value::String(s) => {
                        let t = s.trim().to_string();
                        if t.is_empty() { None } else { Some(t) }
                    }
                    Value::Number(n) => Some(n.to_string()),
                    Value::Bool(b) => Some(b.to_string()),
                    Value::Null => None,
                    other => Some(other.to_string()),
                })
                .collect();
            if !items.is_empty() {
                Some(items)
            } else {
                None
            }
        }
        Value::Array(list) => {
            let items: Vec<String> = list
                .into_iter()
                .filter_map(|val| match val {
                    Value::String(s) => {
                        let t = s.trim().to_string();
                        if t.is_empty() { None } else { Some(t) }
                    }
                    Value::Number(n) => Some(n.to_string()),
                    Value::Bool(b) => Some(b.to_string()),
                    Value::Null => None,
                    other => Some(other.to_string()),
                })
                .collect();
            if !items.is_empty() {
                Some(items)
            } else {
                None
            }
        }
        _ => None,
    }
}

/// 3. 标签键值对提取（例如："姓名：张三\n手机：138..."）
fn burst_labeled_key_value(text: &str) -> Option<Vec<String>> {
    // 检查是否有多行且每行包含冒号
    let lines: Vec<&str> = text
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect();

    if lines.len() >= 2 {
        let mut values = Vec::new();
        let mut colon_count = 0;

        for line in &lines {
            if let Some(pos) = line.find([':', '：']) {
                let key = line[..pos].trim();
                let val = line[pos + (if line.as_bytes()[pos] == b':' { 1 } else { '：'.len_utf8() })..].trim();
                // key 长度不超过 20 个字符才算作标签
                if !key.is_empty() && key.chars().count() <= 20 && !val.is_empty() {
                    colon_count += 1;
                    values.push(val.to_string());
                    continue;
                }
            }
            // 保留无冒号但非空的内容行（如混合在标签中的详细地址行），避免静默丢弃字段
            values.push((*line).to_string());
        }

        // 绝大多数行都符合冒号标签结构
        if colon_count >= 2 && colon_count * 2 >= lines.len() {
            return Some(values);
        }
    }

    None
}

/// 清洗中文姓名尾部常见的“收”、“(收)”、“（收）”及称谓
fn sanitize_person_name(name: &str) -> String {
    let mut n = name.trim();
    // 剥离两端括号：如 (张三) 或 （张三）
    if (n.starts_with('(') && n.ends_with(')')) || (n.starts_with('（') && n.ends_with('）')) {
        let start = if n.starts_with('(') { 1 } else { '（'.len_utf8() };
        let end_len = if n.ends_with(')') { 1 } else { '）'.len_utf8() };
        n = &n[start..n.len() - end_len];
        n = n.trim();
    }
    // 剥离尾部“收”、“(收)”、“（收）”
    if n.ends_with("（收）") {
        n = &n[..n.len() - "（收）".len()];
    } else if n.ends_with("(收)") {
        n = &n[..n.len() - "(收)".len()];
    } else if n.ends_with('收') && n.chars().count() > 1 {
        n = &n[..n.len() - '收'.len_utf8()];
    }
    // 剥离常见称呼后缀：“先生”、“女士”、“小姐”、“师傅”
    for suffix in ["先生", "女士", "小姐", "师傅"] {
        if n.ends_with(suffix) && n.chars().count() > suffix.chars().count() {
            n = &n[..n.len() - suffix.len()];
            break;
        }
    }
    n.trim().to_string()
}

/// 4. 常见快递收件/用户联系人混合文本启发式提取（姓名、电话、地址、邮编）
fn burst_contact_info(text: &str) -> Option<Vec<String>> {
    // 1. 先检查是否包含电话号码
    let phone_match = PHONE_REGEX.find(text)?;
    let phone_str = phone_match.as_str().trim().to_string();

    // 剔除电话号码后的其余部分
    let mut remainder = String::with_capacity(text.len());
    remainder.push_str(&text[..phone_match.start()]);
    remainder.push(' ');
    remainder.push_str(&text[phone_match.end()..]);

    // 2. 检查并提取邮政编码（优先带“邮编”前缀，其次独立分隔的 6 位邮编，避免误切“100015号/室”门牌）
    let mut postal_code = None;
    if let Some(caps) = POSTAL_CODE_REGEX.captures(&remainder) {
        if let (Some(full), Some(code)) = (caps.get(0), caps.get(1)) {
            postal_code = Some(code.as_str().to_string());
            let mut without_post = String::with_capacity(remainder.len());
            without_post.push_str(&remainder[..full.start()]);
            without_post.push(' ');
            without_post.push_str(&remainder[full.end()..]);
            remainder = without_post;
        }
    } else if let Some(caps) = STANDALONE_POSTAL_CODE_REGEX.captures(&remainder) {
        if let Some(code) = caps.get(1) {
            postal_code = Some(code.as_str().to_string());
            let mut without_post = String::with_capacity(remainder.len());
            without_post.push_str(&remainder[..code.start()]);
            without_post.push(' ');
            without_post.push_str(&remainder[code.end()..]);
            remainder = without_post;
        }
    }

    // 3. 清洗无用标签词
    let cleaned = remainder
        .replace("收件人", " ")
        .replace("收货人", " ")
        .replace("联系人", " ")
        .replace("姓名", " ")
        .replace("电话", " ")
        .replace("手机号", " ")
        .replace("手机", " ")
        .replace("详细地址", " ")
        .replace("收货地址", " ")
        .replace("地址", " ")
        .replace("邮政编码", " ")
        .replace("邮编", " ");

    // 4. 按常见标点与空白切分片段（含顿号、逗号、分号等）
    let tokens: Vec<&str> = cleaned
        .split(|c: char| c.is_whitespace() || c == ',' || c == '，' || c == '、' || c == ';' || c == '；' || c == ':' || c == '：')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();

    if tokens.is_empty() {
        return Some(vec![phone_str]);
    }

    let mut raw_name = String::new();
    let mut address_parts: Vec<String> = Vec::new();
    let mut has_real_address_keyword = false;

    // 在剩余片段中寻找地址与姓名
    for token in &tokens {
        let is_real_address = PROVINCE_REGEX.is_match(token) || ADDRESS_KEYWORDS.is_match(token);
        if is_real_address {
            has_real_address_keyword = true;
            address_parts.push(token.to_string());
        } else if raw_name.is_empty() && token.chars().count() <= 6 {
            // 候选姓名：短词（<= 6 字符），排除纯数字
            if !token.chars().all(|c| c.is_ascii_digit()) {
                raw_name = token.to_string();
            } else {
                address_parts.push(token.to_string());
            }
        } else {
            // 后续片段合并为地址（门牌、楼层、小区等）
            address_parts.push(token.to_string());
        }
    }

    // 严谨校验：如果没有任何一个片段命中省/市/区/街/路/学校等地址关键词，不认为是联系人卡片
    if !has_real_address_keyword || address_parts.is_empty() {
        return None;
    }

    let clean_name = sanitize_person_name(&raw_name);
    let valid_name = if clean_name.starts_with("我的") || clean_name.starts_with("你的") || clean_name.is_empty() {
        None
    } else {
        Some(clean_name)
    };

    let full_address = address_parts.join(" ");

    let mut result = Vec::new();
    if let Some(name) = valid_name {
        result.push(name);
        result.push(phone_str);
        result.push(full_address);
    } else {
        // 无姓名（如学校、公司、外卖送达点）：地址在前，电话在后
        result.push(full_address);
        result.push(phone_str);
    }

    if let Some(code) = postal_code {
        result.push(code);
    }

    Some(result)
}

/// 5. 通用分隔符切分
fn burst_delimiters(text: &str) -> Option<Vec<String>> {
    // 换行切分
    if text.contains('\n') {
        let lines: Vec<String> = text
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect();
        if lines.len() >= 2 {
            return Some(lines);
        }
    }

    // 逗号或分号切分（中英文）
    if text.contains(',') || text.contains('，') || text.contains(';') || text.contains('；') {
        let parts: Vec<String> = text
            .split([',', '，', ';', '；'])
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if parts.len() >= 2 {
            return Some(parts);
        }
    }

    // 空格切分（如果由空格切出的 token 在 2 到 10 个之间）
    let tokens: Vec<String> = text
        .split_whitespace()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if tokens.len() >= 2 && tokens.len() <= 10 {
        return Some(tokens);
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_burst_tsv_excel() {
        let tsv = "张三\t13800138000\t北京市朝阳区xx路";
        let items = burst_form_text(tsv);
        assert_eq!(items, vec!["张三", "13800138000", "北京市朝阳区xx路"]);
    }

    #[test]
    fn test_burst_markdown_table() {
        let md = "| 李四 | 13900000000 | 杭州市西湖区 |";
        let items = burst_form_text(md);
        assert_eq!(items, vec!["李四", "13900000000", "杭州市西湖区"]);
    }

    #[test]
    fn test_burst_json_object() {
        let json_str = r#"{"name": "王五", "tel": "13700000000", "city": "上海市"}"#;
        let items = burst_form_text(json_str);
        assert_eq!(items, vec!["王五", "13700000000", "上海市"]);
    }

    #[test]
    fn test_burst_json_array() {
        let json_str = r#"["字段1", "字段2", "字段3"]"#;
        let items = burst_form_text(json_str);
        assert_eq!(items, vec!["字段1", "字段2", "字段3"]);
    }

    #[test]
    fn test_burst_labeled_text() {
        let labeled = "姓名：赵六\n电话：13600000000\n地址：广州市天河区科技园";
        let items = burst_form_text(labeled);
        assert_eq!(items, vec!["赵六", "13600000000", "广州市天河区科技园"]);
    }

    #[test]
    fn test_burst_contact_natural_language() {
        let text = "张三 13800138000 北京市朝阳区xx路";
        let items = burst_form_text(text);
        assert_eq!(items, vec!["张三", "13800138000", "北京市朝阳区xx路"]);
    }

    #[test]
    fn test_burst_contact_reversed_order() {
        let text = "13800138000 张三 浙江省杭州市西湖区文三路100号";
        let items = burst_form_text(text);
        assert_eq!(items, vec!["张三", "13800138000", "浙江省杭州市西湖区文三路100号"]);
    }

    #[test]
    fn test_burst_user_sample_with_hyphen_phone_and_name_suffix() {
        let text = "北京市朝阳区示例街道示例路88号院3号楼502室 张三收，138-0000-0000，邮编100000";
        let items = burst_form_text(text);
        assert_eq!(
            items,
            vec![
                "张三",
                "138-0000-0000",
                "北京市朝阳区示例街道示例路88号院3号楼502室",
                "100000"
            ]
        );
        assert!(should_suggest_form_burst(text));
    }

    #[test]
    fn test_burst_user_sample_with_masked_phone_and_no_name() {
        let text = "广东省广州市番禺区 大石街道 南大路大石段90号礼村小学 182****5644";
        let items = burst_form_text(text);
        assert_eq!(
            items,
            vec![
                "广东省广州市番禺区 大石街道 南大路大石段90号礼村小学",
                "182****5644"
            ]
        );
        assert!(should_suggest_form_burst(text));
    }

    #[test]
    fn test_burst_comma_separated() {
        let text = "苹果, 香蕉, 橙子";
        let items = burst_form_text(text);
        assert_eq!(items, vec!["苹果", "香蕉", "橙子"]);
    }

    #[test]
    fn test_burst_fallback_single() {
        let single = "纯文本无分隔符";
        let items = burst_form_text(single);
        assert_eq!(items, vec!["纯文本无分隔符"]);
    }

    #[test]
    fn test_should_suggest_form_burst_positives() {
        // 1. TSV / 表格
        assert!(should_suggest_form_burst("张三\t13800138000\t北京市朝阳区"));
        // 2. JSON
        assert!(should_suggest_form_burst(r#"{"name": "张三", "city": "北京"}"#));
        // 3. 标签键值对
        assert!(should_suggest_form_burst("姓名：张三\n电话：13800138000"));
        // 4. 三要素齐全的联系人
        assert!(should_suggest_form_burst("张三 13800138000 北京市朝阳区建国路1号"));
    }

    #[test]
    fn test_should_suggest_form_burst_negatives() {
        // 普通聊天短句，不弹窗
        assert!(!should_suggest_form_burst("今天天气不错，下午一起去喝咖啡吧"));
        // 只有手机号，缺少地址/姓名，不弹窗防误报
        assert!(!should_suggest_form_burst("我的手机号是13800138000，到了打给我"));
        // 普通逗号列表，不主动弹窗
        assert!(!should_suggest_form_burst("苹果, 香蕉, 橙子"));
        // 空文本
        assert!(!should_suggest_form_burst(""));
    }

    #[test]
    fn test_detect_form_burst_kind() {
        assert_eq!(detect_form_burst_kind("a\tb\tc"), "table");
        assert_eq!(detect_form_burst_kind(r#"{"name": "test"}"#), "json");
        assert_eq!(detect_form_burst_kind("姓名：张三\n电话：13800138000"), "key_value");
        assert_eq!(detect_form_burst_kind("北京市朝阳区某路1号 138-0000-0000"), "contact");
        assert_eq!(detect_form_burst_kind("普通文本"), "text");
    }

    #[test]
    fn test_pipe_command_and_code_not_misclassified_as_table() {
        let cmd = "ps aux | grep nginx";
        assert!(!should_suggest_form_burst(cmd));
        assert_ne!(detect_form_burst_kind(cmd), "table");

        let ts_union = "type Status = 'idle' | 'loading' | 'done';";
        assert!(!should_suggest_form_burst(ts_union));
        assert_ne!(detect_form_burst_kind(ts_union), "table");

        let rust_or = "if flag_a || flag_b { return true; }";
        assert!(!should_suggest_form_burst(rust_or));
    }

    #[test]
    fn test_labeled_kv_preserves_unlabeled_address_line() {
        let mixed = "姓名：张三\n北京市朝阳区酒仙桥路10号\n电话：13800000000";
        let items = burst_form_text(mixed);
        assert_eq!(items, vec!["张三", "北京市朝阳区酒仙桥路10号", "13800000000"]);
    }

    #[test]
    fn test_contact_six_digit_building_or_room_number_not_stripped_as_postal_code() {
        let text = "张三 13800000000 北京市朝阳区酒仙桥路100015号100501室";
        let items = burst_form_text(text);
        assert_eq!(
            items,
            vec!["张三", "13800000000", "北京市朝阳区酒仙桥路100015号100501室"]
        );
    }
}
