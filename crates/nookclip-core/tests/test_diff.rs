//! 文本差异对比（Inline Diff / `⌘D`）对外行为契约测试。
//!
//! 这些用例锁定三件事：
//! 1. **字词级定位精度**：中文按字、英文按词、标点独立，改动能被精确圈出；
//! 2. **合并可逆性**：全选新版 == 新版原文，全选旧版 == 旧版原文（逐字节）；
//! 3. **超长护栏**：大文本不卡死、被标记截断。

use nookclip_core::algorithms::diff::{
    diff_texts, merge_diff_text, DiffOptions, DiffSpan, DiffTag, HunkChoice, TextDiffResult,
};

fn render(spans: &[DiffSpan]) -> String {
    spans.iter().map(|s| s.text.as_str()).collect()
}

fn emphasized(spans: &[DiffSpan], tag: DiffTag) -> String {
    spans
        .iter()
        .filter(|s| s.tag == tag && s.emphasized)
        .map(|s| s.text.as_str())
        .collect()
}

/// 在差异块里按行号找到指定类型的第一行
fn find_line(result: &TextDiffResult, tag: DiffTag) -> &nookclip_core::algorithms::diff::DiffLine {
    result
        .hunks
        .iter()
        .flat_map(|h| h.lines.iter())
        .find(|l| l.tag == tag)
        .expect("应存在该类型的差异行")
}

// ---------------------------------------------------------------------------
// 1. 字词级定位精度
// ---------------------------------------------------------------------------

#[test]
fn contract_chinese_number_change_is_char_precise() {
    let old = "合同总金额：人民币 10000 元整";
    let new = "合同总金额：人民币 12000 元整";
    let result = diff_texts(old, new, DiffOptions::default());

    let deleted = find_line(&result, DiffTag::Delete);
    assert_eq!(render(&deleted.spans), old);
    assert_eq!(emphasized(&deleted.spans, DiffTag::Delete), "10000");

    let inserted = find_line(&result, DiffTag::Insert);
    assert_eq!(render(&inserted.spans), new);
    assert_eq!(emphasized(&inserted.spans, DiffTag::Insert), "12000");
}

#[test]
fn contract_code_identifier_rename_is_word_precise() {
    let old = "const maxRetryCount = 3;\nfetchUser(userId);";
    let new = "const maxRetryTotal = 3;\nfetchUser(userId);";
    let result = diff_texts(old, new, DiffOptions::default());

    // 第 2 行相同，不应产生差异行
    assert_eq!(result.stats.added_lines, 1);
    assert_eq!(result.stats.removed_lines, 1);
    assert_eq!(
        emphasized(&find_line(&result, DiffTag::Delete).spans, DiffTag::Delete),
        "Count"
    );
    assert_eq!(
        emphasized(&find_line(&result, DiffTag::Insert).spans, DiffTag::Insert),
        "Total"
    );
}

#[test]
fn contract_punctuation_change_is_detected() {
    let old = "第一条款；第二条款。";
    let new = "第一条款；第二条款，";
    let result = diff_texts(old, new, DiffOptions::default());
    assert_eq!(
        emphasized(&find_line(&result, DiffTag::Delete).spans, DiffTag::Delete),
        "。"
    );
    assert_eq!(
        emphasized(&find_line(&result, DiffTag::Insert).spans, DiffTag::Insert),
        "，"
    );
}

#[test]
fn contract_yaml_value_change_keeps_key_context_unemphasized() {
    let old = "server:\n  port: 8080\n  host: 0.0.0.0";
    let new = "server:\n  port: 9090\n  host: 0.0.0.0";
    let result = diff_texts(old, new, DiffOptions::default());

    let deleted = find_line(&result, DiffTag::Delete);
    assert_eq!(render(&deleted.spans), "  port: 8080");
    // 只有数字被强调，缩进与 key 保持普通文本
    assert_eq!(emphasized(&deleted.spans, DiffTag::Delete), "8080");
    assert_eq!(deleted.old_line_no, 2);
}

#[test]
fn contract_untouched_lines_produce_no_change_hunk() {
    let old = "a\nb\nc";
    let new = "a\nb\nc";
    let result = diff_texts(old, new, DiffOptions::default());
    assert!(result.stats.is_identical);
    assert_eq!(result.stats.changed_hunks, 0);
    assert!(result.hunks.iter().all(|h| !h.is_change));
}

// ---------------------------------------------------------------------------
// 2. 合并可逆性（「一键复制合并版」的正确性底线）
// ---------------------------------------------------------------------------

fn assert_merge_reversible(old: &str, new: &str) {
    let result = diff_texts(old, new, DiffOptions::default());

    // 全选新版（默认 / 空 choices）
    assert_eq!(
        merge_diff_text(&result.hunks, &[]),
        new,
        "空 choices 必须得到新版原文"
    );
    let keep_new: Vec<u8> = result.hunks.iter().map(|_| 0u8).collect();
    assert_eq!(
        merge_diff_text(&result.hunks, &keep_new),
        new,
        "全选 0 必须得到新版原文"
    );

    // 全选旧版
    let keep_old: Vec<u8> = result.hunks.iter().map(|_| 1u8).collect();
    assert_eq!(
        merge_diff_text(&result.hunks, &keep_old),
        old,
        "全选 1 必须得到旧版原文"
    );
}

#[test]
fn contract_merge_reversible_across_shapes() {
    let cases: Vec<(&str, &str)> = vec![
        ("", ""),
        ("", "hello"),
        ("hello", ""),
        ("a\nb\nc", "a\nb\nc"),
        ("a\nb\nc", "a\nB\nc"),
        ("a\nb", "a\nb\nc"),
        ("a\nb\nc", "a\nc"),
        ("a\nb\n", "a\nc\n"),
        ("a\r\nb\r\n", "a\r\nc\r\n"),
        ("1\n2\n3\n4\n5", "1\nX\n3\nY\n5"),
        ("# 注释\nport: 1\n", "# 注释\nport: 2\n"),
        ("今天天气很好", "今天天气不好"),
        ("{}", "{\n  \"a\": 1\n}"),
    ];
    for (old, new) in cases {
        assert_merge_reversible(old, new);
    }
}

#[test]
fn contract_merge_keep_both_keeps_both_versions() {
    let old = "a\nold\nc";
    let new = "a\nnew\nc";
    let result = diff_texts(old, new, DiffOptions::default());

    let mut choices = vec![0u8; result.hunks.len()];
    for (index, hunk) in result.hunks.iter().enumerate() {
        if hunk.is_change {
            choices[index] = 2; // 两者都保留
        }
    }
    assert_eq!(merge_diff_text(&result.hunks, &choices), "a\nold\nnew\nc");
}

#[test]
fn contract_merge_partial_choice_per_hunk() {
    let old = "keep\nOLD1\nmid\nOLD2\nend";
    let new = "keep\nNEW1\nmid\nNEW2\nend";
    let result = diff_texts(old, new, DiffOptions::default());

    let change_indexes: Vec<usize> = result
        .hunks
        .iter()
        .enumerate()
        .filter(|(_, h)| h.is_change)
        .map(|(i, _)| i)
        .collect();
    assert_eq!(change_indexes.len(), 2);

    let mut choices = vec![0u8; result.hunks.len()];
    choices[change_indexes[0]] = 1; // 第一处保留旧版
    choices[change_indexes[1]] = 0; // 第二处保留新版
    assert_eq!(
        merge_diff_text(&result.hunks, &choices),
        "keep\nOLD1\nmid\nNEW2\nend"
    );
}

#[test]
fn contract_merge_choice_codes_are_stable() {
    // FFI 层用 0/1/2 三个整数传选择，此处锁定编码含义
    assert_eq!(HunkChoice::from_code(0), HunkChoice::KeepNew);
    assert_eq!(HunkChoice::from_code(1), HunkChoice::KeepOld);
    assert_eq!(HunkChoice::from_code(2), HunkChoice::KeepBoth);
    // 未来新增编码或脏数据不应 panic，一律退回默认「保留新版」
    assert_eq!(HunkChoice::from_code(255), HunkChoice::KeepNew);
}

#[test]
fn contract_merge_handles_short_choices_array() {
    let result = diff_texts("a\nb", "a\nX", DiffOptions::default());
    // 只给一个选择（且比 hunks 少）：缺的按默认处理，不应 panic
    let merged = merge_diff_text(&result.hunks, &[0u8]);
    assert_eq!(merged, "a\nX");
}

// ---------------------------------------------------------------------------
// 3. 行号与片段拼接契约
// ---------------------------------------------------------------------------

#[test]
fn contract_span_concat_restores_original_line() {
    let old = "let cfg = { retries: 3, timeout: 30 };";
    let new = "let cfg = { retries: 5, timeout: 60 };";
    let result = diff_texts(old, new, DiffOptions::default());
    for line in result.hunks.iter().flat_map(|h| h.lines.iter()) {
        match line.tag {
            DiffTag::Delete => assert_eq!(render(&line.spans), old),
            DiffTag::Insert => assert_eq!(render(&line.spans), new),
            DiffTag::Equal => {}
        }
    }
}

#[test]
fn contract_line_numbers_follow_file_convention() {
    let old = "l1\nl2\nl3\nl4";
    let new = "l1\nl2\nl3-changed\nl4\nl5";
    let result = diff_texts(old, new, DiffOptions::default());

    let deleted = find_line(&result, DiffTag::Delete);
    assert_eq!(deleted.old_line_no, 3);
    assert_eq!(deleted.new_line_no, 0); // 删除行在新版里没有行号

    let inserted = find_line(&result, DiffTag::Insert);
    assert_eq!(inserted.old_line_no, 0); // 新增行在旧版里没有行号
    assert_eq!(inserted.new_line_no, 3);
}

#[test]
fn contract_hunk_ids_are_sequential_from_zero() {
    let result = diff_texts("a\nb\nc\nd\ne", "a\nB\nc\nD\ne", DiffOptions::default());
    for (index, hunk) in result.hunks.iter().enumerate() {
        assert_eq!(hunk.id, index as u32);
    }
}

#[test]
fn contract_change_hunk_has_lines_and_context_hunk_does_not() {
    let result = diff_texts(
        "same\nold\nsame2",
        "same\nnew\nsame2",
        DiffOptions::default(),
    );
    for hunk in &result.hunks {
        if hunk.is_change {
            assert!(!hunk.lines.is_empty(), "改动块必须带逐行渲染数据");
        } else {
            assert!(hunk.lines.is_empty(), "上下文块用 new_lines 平铺渲染即可");
            assert_eq!(hunk.old_lines, hunk.new_lines);
        }
    }
}

// ---------------------------------------------------------------------------
// 4. 超长与异常输入护栏
// ---------------------------------------------------------------------------

#[test]
fn contract_truncation_marks_flag_and_still_merges() {
    let old = (1..=50)
        .map(|i| format!("line {i}"))
        .collect::<Vec<_>>()
        .join("\n");
    let new = (1..=50)
        .map(|i| format!("line {i}!"))
        .collect::<Vec<_>>()
        .join("\n");
    let options = DiffOptions {
        max_lines: 10,
        ..DiffOptions::default()
    };
    let result = diff_texts(&old, &new, options);
    assert!(result.stats.is_truncated);
    // 截断后仍保证合并可逆（针对截断后的内容）
    let merged = merge_diff_text(&result.hunks, &[]);
    let expected = new.split('\n').take(10).collect::<Vec<_>>().join("\n");
    assert_eq!(merged, expected);
}

#[test]
fn contract_huge_text_finishes_quickly() {
    // 2000 行 × 两侧完全不同：应被 max_lines 截断，且必须快速返回
    let old: String = (0..2000)
        .map(|i| format!("old-{i}-{}", "x".repeat(40)))
        .collect::<Vec<_>>()
        .join("\n");
    let new: String = (0..2000)
        .map(|i| format!("new-{i}-{}", "y".repeat(40)))
        .collect::<Vec<_>>()
        .join("\n");

    let started = std::time::Instant::now();
    let result = diff_texts(&old, &new, DiffOptions::default());
    let elapsed = started.elapsed();

    assert!(result.stats.is_truncated);
    assert!(
        elapsed < std::time::Duration::from_secs(2),
        "大文本对比耗时过长：{elapsed:?}"
    );
}

#[test]
fn contract_long_single_line_degrades_gracefully() {
    // 压缩后的 JSON 单行：token 数远超上限 → 整行降级，不强调行内字词
    let old = format!(
        "{{{}}}",
        (0..500)
            .map(|i| format!("\"k{i}\":{i}"))
            .collect::<Vec<_>>()
            .join(",")
    );
    let new = format!(
        "{{{}}}",
        (0..500)
            .map(|i| format!("\"k{i}\":{i}0"))
            .collect::<Vec<_>>()
            .join(",")
    );
    let result = diff_texts(&old, &new, DiffOptions::default());

    assert!(!result.hunks.is_empty());
    assert_eq!(result.stats.changed_hunks, 1);
    assert_eq!(merge_diff_text(&result.hunks, &[]), new);
}

#[test]
fn contract_emoji_and_cjk_offsets_do_not_panic() {
    let old = "🎉 发版完成：v1.0 ✅";
    let new = "🎉 发版完成：v1.2 ✅";
    let result = diff_texts(old, new, DiffOptions::default());
    assert_eq!(
        emphasized(&find_line(&result, DiffTag::Delete).spans, DiffTag::Delete),
        "0"
    );
    assert_eq!(
        emphasized(&find_line(&result, DiffTag::Insert).spans, DiffTag::Insert),
        "2"
    );
    assert_eq!(merge_diff_text(&result.hunks, &[]), new);
}

#[test]
fn contract_whitespace_only_reformat_can_be_ignored() {
    let old = "if (a) {\n  b();\n}";
    let new = "if (a) {\n    b();\n}";
    let strict = diff_texts(old, new, DiffOptions::default());
    assert!(strict.stats.changed_hunks > 0);

    let loose = diff_texts(
        old,
        new,
        DiffOptions {
            ignore_whitespace: true,
            ..DiffOptions::default()
        },
    );
    // 打开「忽略空白」后，2 空格变 4 空格属于纯排版差异，不该再算改动；
    // 否则用户勾了这个开关却发现什么都没变，会以为开关坏了
    assert_eq!(loose.stats.changed_hunks, 0);
}

#[test]
fn contract_ignore_whitespace_still_reports_real_edits() {
    let old = "if (a) {\n  b();\n}";
    let new = "if (a) {\n    c();\n}";
    let loose = diff_texts(
        old,
        new,
        DiffOptions {
            ignore_whitespace: true,
            ..DiffOptions::default()
        },
    );
    // 缩进被忽略，但 b() -> c() 是真实改动，必须标出来
    assert_eq!(loose.stats.changed_hunks, 1);
    let changed: Vec<String> = loose
        .hunks
        .iter()
        .filter(|hunk| hunk.is_change)
        .flat_map(|hunk| hunk.lines.iter().flat_map(|line| line.spans.iter()))
        .filter(|span| span.emphasized)
        .map(|span| span.text.clone())
        .collect();
    // 行内强调按原始文本切分，缩进会并入同一片段；只断言真正变的字母在里面
    assert!(
        changed.iter().any(|span| span.trim() == "b"),
        "实际：{changed:?}"
    );
    assert!(
        changed.iter().any(|span| span.trim() == "c"),
        "实际：{changed:?}"
    );
}

#[test]
fn contract_identical_fast_path_has_full_similarity() {
    let text = "line\n".repeat(200);
    let result = diff_texts(&text, &text, DiffOptions::default());
    assert!(result.stats.is_identical);
    assert_eq!(result.stats.similarity_permille, 1000);
    assert_eq!(merge_diff_text(&result.hunks, &[]), text);
}
