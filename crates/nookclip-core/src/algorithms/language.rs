use std::collections::HashSet;
use std::sync::LazyLock;

struct Profile {
    id: &'static str,
    keywords: Vec<(&'static str, f64)>,
    markers: Vec<(&'static str, f64, bool)>, // (literal, weight, case_insensitive)
}

static PROFILES: LazyLock<Vec<Profile>> = LazyLock::new(|| {
    vec![
        Profile {
            id: "java",
            keywords: vec![
                ("public", 2.0),
                ("private", 2.0),
                ("protected", 2.0),
                ("class", 2.0),
                ("static", 2.0),
                ("final", 2.0),
                ("void", 2.0),
                ("new", 1.0),
                ("import", 1.0),
                ("package", 1.0),
                ("implements", 2.0),
                ("extends", 2.0),
                ("boolean", 2.0),
                ("instanceof", 3.0),
                ("return", 1.0),
            ],
            markers: vec![
                ("import java.", 5.0, false),
                ("@Override", 4.0, false),
                ("System.out", 4.0, false),
                ("String[] args", 4.0, false),
                ("public static void main", 5.0, false),
                ("throws ", 2.0, false),
            ],
        },
        Profile {
            id: "kotlin",
            keywords: vec![
                ("fun", 5.0),
                ("val", 4.0),
                ("var", 2.0),
                ("object", 2.0),
                ("when", 2.0),
                ("companion", 3.0),
                ("sealed", 2.0),
                ("internal", 2.0),
                ("override", 2.0),
                ("init", 1.0),
            ],
            markers: vec![
                ("data class", 4.0, false),
                ("?:", 3.0, false),
                ("!!", 3.0, false),
                ("suspend fun", 5.0, false),
                ("companion object", 4.0, false),
                ("lateinit", 4.0, false),
            ],
        },
        Profile {
            id: "swift",
            keywords: vec![
                ("func", 4.0),
                ("let", 2.0),
                ("var", 2.0),
                ("struct", 3.0),
                ("protocol", 3.0),
                ("extension", 3.0),
                ("guard", 3.0),
                ("defer", 2.0),
                ("throws", 2.0),
                ("init", 2.0),
                ("self", 2.0),
                ("nil", 1.0),
                ("enum", 2.0),
                ("public", 1.0),
                ("private", 1.0),
                ("where", 1.0),
            ],
            markers: vec![
                ("@State", 5.0, false),
                ("@IBOutlet", 4.0, false),
                ("@IBAction", 4.0, false),
                ("@Published", 4.0, false),
                ("@escaping", 4.0, false),
                ("guard let", 4.0, false),
                ("if let", 3.0, false),
                ("import SwiftUI", 5.0, false),
                ("import Foundation", 2.0, false),
                ("[weak self]", 4.0, false),
                ("try!", 3.0, false),
                ("try?", 3.0, false),
                (" -> ", 2.0, false),
                ("weak var", 3.0, false),
            ],
        },
        Profile {
            id: "objc",
            keywords: vec![],
            markers: vec![
                ("#import <", 5.0, false),
                ("#import \"", 4.0, false),
                ("@interface", 5.0, false),
                ("@implementation", 5.0, false),
                ("@property", 5.0, false),
                ("@end", 4.0, false),
                ("NSLog(", 4.0, false),
                ("NSString", 3.0, false),
                ("NSArray", 3.0, false),
                ("NSMutableArray", 4.0, false),
                ("dispatch_async", 4.0, false),
                ("[self ", 4.0, false),
                ("instancetype", 4.0, false),
            ],
        },
        Profile {
            id: "python",
            keywords: vec![
                ("def", 3.0),
                ("import", 1.0),
                ("elif", 4.0),
                ("none", 4.0),
                ("lambda", 3.0),
                ("self", 2.0),
                ("pass", 2.0),
                ("raise", 3.0),
                ("except", 4.0),
                ("with", 1.0),
                ("print", 2.0),
                ("from", 1.0),
                ("class", 2.0),
                ("return", 1.0),
                ("not", 2.0),
            ],
            markers: vec![("__name__", 4.0, false), ("if __name__ ==", 5.0, false)],
        },
        Profile {
            id: "javascript",
            keywords: vec![
                ("function", 3.0),
                ("const", 3.0),
                ("let", 1.0),
                ("var", 1.0),
                ("return", 1.0),
                ("async", 2.0),
                ("await", 2.0),
                ("export", 2.0),
                ("console", 3.0),
                ("typeof", 2.0),
                ("document", 3.0),
                ("window", 2.0),
                ("undefined", 4.0),
                ("new", 1.0),
                ("this", 1.0),
            ],
            markers: vec![
                ("console.log(", 4.0, false),
                ("=>", 2.0, false),
                ("require(", 3.0, false),
                ("module.exports", 5.0, false),
                ("process.env", 4.0, false),
                ("addEventListener", 3.0, false),
            ],
        },
        Profile {
            id: "typescript",
            keywords: vec![
                ("interface", 3.0),
                ("type", 2.0),
                ("enum", 2.0),
                ("implements", 2.0),
                ("readonly", 3.0),
                ("declare", 3.0),
                ("abstract", 2.0),
                ("namespace", 2.0),
            ],
            markers: vec![
                (": string", 3.0, false),
                (": number", 3.0, false),
                (": boolean", 3.0, false),
                (": void", 2.0, false),
                ("<T>", 2.0, false),
                ("export type", 4.0, false),
            ],
        },
        Profile {
            id: "go",
            keywords: vec![
                ("func", 4.0),
                ("package", 2.0),
                ("chan", 4.0),
                ("defer", 2.0),
                ("range", 2.0),
                ("struct", 2.0),
                ("type", 2.0),
                ("fmt", 3.0),
                ("nil", 1.0),
            ],
            markers: vec![
                (":=", 5.0, false),
                ("package main", 4.0, false),
                ("import (", 3.0, false),
                ("if err != nil", 4.0, false),
            ],
        },
        Profile {
            id: "rust",
            keywords: vec![
                ("fn", 4.0),
                ("mut", 5.0),
                ("impl", 3.0),
                ("pub", 2.0),
                ("use", 2.0),
                ("match", 2.0),
                ("crate", 4.0),
                ("trait", 2.0),
                ("dyn", 3.0),
                ("where", 1.0),
                ("loop", 2.0),
                ("mod", 3.0),
            ],
            markers: vec![
                ("let mut", 5.0, false),
                ("println!(", 4.0, false),
                ("&str", 4.0, false),
                ("#[derive", 5.0, false),
                ("Vec<", 3.0, false),
                ("::", 2.0, false),
                ("->", 1.0, false),
            ],
        },
        Profile {
            id: "c",
            keywords: vec![
                ("int", 1.0),
                ("char", 2.0),
                ("double", 1.0),
                ("float", 1.0),
                ("while", 1.0),
                ("return", 1.0),
                ("sizeof", 3.0),
                ("typedef", 3.0),
                ("unsigned", 2.0),
                ("void", 1.0),
                ("const", 2.0),
                ("struct", 2.0),
                ("static", 1.0),
                ("long", 1.0),
                ("null", 3.0),
            ],
            markers: vec![
                ("#include <", 4.0, false),
                ("printf(", 4.0, false),
                ("malloc(", 4.0, false),
                ("scanf(", 4.0, false),
            ],
        },
        Profile {
            id: "cpp",
            keywords: vec![
                ("namespace", 2.0),
                ("class", 2.0),
                ("template", 3.0),
                ("typename", 4.0),
                ("virtual", 3.0),
                ("delete", 2.0),
                ("override", 2.0),
                ("const", 1.0),
                ("auto", 2.0),
                ("public", 1.0),
                ("private", 1.0),
                ("inline", 2.0),
                ("constexpr", 4.0),
            ],
            markers: vec![
                ("std::", 5.0, false),
                ("#include <iostream>", 5.0, false),
                ("cout", 4.0, false),
                ("cin", 2.0, false),
                ("endl", 4.0, false),
                ("nullptr", 3.0, false),
                ("template<", 4.0, false),
                ("vector<", 2.0, false),
            ],
        },
        Profile {
            id: "csharp",
            keywords: vec![
                ("using", 2.0),
                ("namespace", 2.0),
                ("var", 1.0),
                ("string", 2.0),
                ("bool", 2.0),
                ("async", 2.0),
                ("await", 2.0),
                ("readonly", 2.0),
                ("partial", 3.0),
                ("override", 2.0),
                ("sealed", 2.0),
                ("internal", 2.0),
                ("public", 2.0),
                ("private", 2.0),
                ("class", 2.0),
                ("static", 2.0),
                ("void", 2.0),
                ("return", 1.0),
            ],
            markers: vec![
                ("using System", 5.0, false),
                ("Console.Write", 4.0, false),
                ("Console.ReadLine", 5.0, false),
                ("get; set;", 4.0, false),
                ("Task<", 4.0, false),
                (".ToList()", 4.0, false),
                ("string[]", 3.0, false),
            ],
        },
        Profile {
            id: "ruby",
            keywords: vec![
                ("def", 3.0),
                ("end", 4.0),
                ("puts", 4.0),
                ("require", 2.0),
                ("nil", 1.0),
                ("self", 2.0),
                ("yield", 3.0),
                ("module", 2.0),
                ("begin", 2.0),
                ("rescue", 4.0),
                ("elsif", 4.0),
                ("unless", 3.0),
                ("ensure", 3.0),
            ],
            markers: vec![
                ("attr_accessor", 5.0, false),
                ("do |", 4.0, false),
                ("#{", 4.0, false),
                (".each do", 4.0, false),
                ("require '", 4.0, false),
                ("require \"", 4.0, false),
            ],
        },
        Profile {
            id: "php",
            keywords: vec![
                ("echo", 2.0),
                ("function", 2.0),
                ("public", 1.0),
                ("private", 1.0),
                ("foreach", 3.0),
                ("endforeach", 4.0),
                ("isset", 4.0),
                ("unset", 3.0),
            ],
            markers: vec![
                ("<?php", 6.0, false),
                ("<?=", 4.0, false),
                ("$_POST", 5.0, false),
                ("$_GET", 5.0, false),
                ("$_SERVER", 5.0, false),
                ("array(", 3.0, false),
            ],
        },
        Profile {
            id: "shell",
            keywords: vec![
                ("echo", 2.0),
                ("fi", 4.0),
                ("esac", 5.0),
                ("done", 2.0),
                ("elif", 3.0),
                ("then", 2.0),
                ("sudo", 3.0),
                ("chmod", 2.0),
                ("export", 2.0),
                ("grep", 2.0),
                ("awk", 3.0),
                ("sed", 1.0),
                ("curl", 2.0),
                ("bash", 2.0),
                ("apt", 2.0),
                ("yum", 3.0),
            ],
            markers: vec![
                ("brew install", 3.0, false),
                ("2>&1", 4.0, false),
                (">/dev/null", 5.0, false),
                ("2>/dev/null", 5.0, false),
            ],
        },
        Profile {
            id: "sql",
            keywords: vec![],
            markers: vec![
                ("SELECT ", 3.0, false),
                ("FROM ", 2.0, false),
                ("WHERE ", 2.0, false),
                ("INSERT INTO", 4.0, false),
                ("CREATE TABLE", 4.0, false),
                ("DELETE FROM", 4.0, false),
                ("JOIN ", 2.0, false),
                ("GROUP BY", 3.0, false),
                ("ORDER BY", 3.0, false),
                ("ALTER TABLE", 4.0, false),
                ("VALUES", 2.0, false),
            ],
        },
        Profile {
            id: "html",
            keywords: vec![],
            markers: vec![
                ("<!doctype", 5.0, true),
                ("<html", 5.0, true),
                ("</html>", 5.0, true),
                ("<head", 3.0, true),
                ("<body", 4.0, true),
                ("<div", 3.0, true),
                ("</div>", 4.0, true),
                ("<span", 3.0, true),
                ("<p>", 2.0, true),
                ("<a href", 3.0, true),
                ("<meta", 3.0, true),
                ("<link", 3.0, true),
                ("<img", 3.0, true),
                ("<table", 3.0, true),
            ],
        },
        Profile {
            id: "xml",
            keywords: vec![],
            markers: vec![
                ("<?xml", 6.0, false),
                ("xmlns:", 4.0, false),
                ("xmlns=", 4.0, false),
            ],
        },
        Profile {
            id: "css",
            keywords: vec![],
            markers: vec![
                ("display:", 2.0, true),
                ("padding:", 3.0, true),
                ("margin:", 3.0, true),
                ("color:", 2.0, true),
                ("background:", 2.0, true),
                ("font-size:", 3.0, true),
                ("font-weight:", 3.0, true),
                ("border:", 2.0, true),
                ("border-radius:", 3.0, true),
                ("!important", 5.0, true),
                ("px;", 2.0, true),
                ("rem;", 2.0, true),
                ("width:", 2.0, true),
                ("height:", 2.0, true),
                ("position:", 2.0, true),
                ("text-align:", 3.0, true),
                ("align-items:", 3.0, true),
                ("justify-content:", 3.0, true),
                ("@media", 4.0, true),
                ("@keyframes", 5.0, true),
            ],
        },
        Profile {
            id: "dart",
            keywords: vec![
                ("async", 2.0),
                ("await", 2.0),
                ("final", 2.0),
                ("extends", 2.0),
                ("class", 2.0),
                ("print", 2.0),
                ("var", 1.0),
                ("void", 2.0),
                ("static", 2.0),
            ],
            markers: vec![
                ("void main()", 5.0, false),
                ("(this.", 4.0, false),
                ("Widget", 3.0, false),
                ("BuildContext", 5.0, false),
                ("Future<", 3.0, false),
                ("setState(", 4.0, false),
                ("=>", 2.0, false),
            ],
        },
        Profile {
            id: "lua",
            keywords: vec![
                ("local", 4.0),
                ("nil", 1.0),
                ("then", 1.0),
                ("end", 2.0),
                ("elseif", 3.0),
                ("function", 3.0),
                ("repeat", 4.0),
                ("until", 2.0),
                ("return", 1.0),
            ],
            markers: vec![("local function", 5.0, false), ("..", 2.0, false)],
        },
        Profile {
            id: "r",
            keywords: vec![("library", 3.0), ("function", 1.0), ("return", 1.0)],
            markers: vec![
                ("<-", 4.0, false),
                ("%>%", 5.0, false),
                ("library(", 3.0, false),
                ("data.frame(", 5.0, false),
                ("ggplot", 4.0, false),
                ("geom_", 4.0, false),
                ("read.csv", 4.0, false),
            ],
        },
        Profile {
            id: "scala",
            keywords: vec![
                ("object", 3.0),
                ("def", 3.0),
                ("val", 3.0),
                ("var", 1.0),
                ("match", 2.0),
                ("trait", 2.0),
                ("implicit", 4.0),
                ("sealed", 2.0),
                ("extends", 2.0),
                ("with", 1.0),
                ("yield", 2.0),
                ("lazy", 2.0),
                ("package", 1.0),
            ],
            markers: vec![
                ("import scala", 5.0, false),
                ("case class", 3.0, false),
                (": Unit", 4.0, false),
            ],
        },
        Profile {
            id: "vb",
            keywords: vec![
                ("dim", 4.0),
                ("sub", 3.0),
                ("then", 2.0),
                ("byval", 5.0),
                ("byref", 5.0),
                ("inherits", 4.0),
                ("nothing", 3.0),
                ("module", 3.0),
                ("end", 2.0),
                ("function", 2.0),
                ("integer", 2.0),
            ],
            markers: vec![
                ("End Sub", 5.0, false),
                ("End Function", 5.0, false),
                ("End If", 4.0, false),
                ("Dim ", 4.0, false),
                ("MsgBox(", 5.0, false),
                ("Console.WriteLine", 3.0, false),
            ],
        },
        Profile {
            id: "matlab",
            keywords: vec![
                ("function", 3.0),
                ("end", 2.0),
                ("disp", 3.0),
                ("fprintf", 2.0),
                ("nargin", 4.0),
                ("nargout", 4.0),
                ("zeros", 3.0),
            ],
            markers: vec![
                ("function [", 4.0, false),
                (".^", 3.0, false),
                ("disp(", 3.0, false),
                ("fprintf(", 3.0, false),
                ("%%", 3.0, false),
            ],
        },
        Profile {
            id: "groovy",
            keywords: vec![("def", 3.0), ("println", 4.0)],
            markers: vec![("@Grab", 5.0, false), (".each {", 3.0, false)],
        },
    ]
});

const SAMPLE_LINE_LIMIT: usize = 100;
const SAMPLE_BYTE_LIMIT: usize = 8_192;

pub struct LanguageClassification {
    pub is_code: bool,
    pub language: Option<String>,
}

/// 识别代码具体语言（置信度过线时返回 Some(lang_id)，不含语言不明的结构兜底）
pub fn classify_language(text: &str) -> Option<String> {
    classify_code(text).language
}

/// 判断文本是否为代码（含具体语言识别 + 多行高密度符号结构兜底）
pub fn is_code_like(text: &str) -> bool {
    classify_code(text).is_code
}

pub fn classify_code(text: &str) -> LanguageClassification {
    let trimmed = text.trim();
    if trimmed.chars().count() < 2 {
        return LanguageClassification {
            is_code: false,
            language: None,
        };
    }

    // 纯非 ASCII 文本（如中文笔记）短路
    if !trimmed.chars().any(|c| c.is_ascii()) {
        return LanguageClassification {
            is_code: false,
            language: None,
        };
    }

    let lines: Vec<&str> = trimmed.lines().collect();
    let sample = sample_text(&lines);

    // 1. JSON：{…}/[…] 包裹且真实可解析
    if ((trimmed.starts_with('{') && trimmed.ends_with('}'))
        || (trimmed.starts_with('[') && trimmed.ends_with(']')))
        && serde_json::from_str::<serde_json::Value>(&sample).is_ok()
    {
        return LanguageClassification {
            is_code: true,
            language: Some("json".to_string()),
        };
    }

    // 2. 终端输出（框线字符或 ANSI 转义序列）不是源代码
    if is_terminal_output(&sample) {
        return LanguageClassification {
            is_code: false,
            language: None,
        };
    }

    // 3. Vue 单文件组件：<template> + <script>/<style>
    if sample.contains("<template")
        && (sample.contains("<script") || sample.contains("<style"))
    {
        return LanguageClassification {
            is_code: true,
            language: Some("vue".to_string()),
        };
    }

    // 4. XML 声明开头
    if trimmed.starts_with("<?xml") {
        return LanguageClassification {
            is_code: true,
            language: Some("xml".to_string()),
        };
    }

    // 5. shebang 直读解释器
    if let Some(first_line) = lines.first().map(|l| l.trim()) {
        if first_line.starts_with("#!") {
            let lower = first_line.to_lowercase();
            if lower.contains("python") {
                return LanguageClassification {
                    is_code: true,
                    language: Some("python".to_string()),
                };
            }
            if lower.contains("bash")
                || lower.contains("zsh")
                || lower.contains("fish")
                || lower.ends_with("/sh")
                || lower.contains(" sh")
            {
                return LanguageClassification {
                    is_code: true,
                    language: Some("shell".to_string()),
                };
            }
            if lower.contains("node") {
                return LanguageClassification {
                    is_code: true,
                    language: Some("javascript".to_string()),
                };
            }
            if lower.contains("ruby") {
                return LanguageClassification {
                    is_code: true,
                    language: Some("ruby".to_string()),
                };
            }
            return LanguageClassification {
                is_code: true,
                language: None,
            };
        }
    }

    // 6. 词边界关键字（≥2 字符）+ 字面标记加权打分
    let words: HashSet<String> = sample
        .split(|c: char| !c.is_alphanumeric() && c != '_')
        .filter(|s| s.chars().count() >= 2)
        .map(|s| s.to_lowercase())
        .collect();

    let mut scores: Vec<(&'static str, f64)> = Vec::new();
    let lower_sample = sample.to_lowercase();

    for profile in PROFILES.iter() {
        let mut score = 0.0;
        for (kw, weight) in &profile.keywords {
            if words.contains(*kw) {
                score += *weight;
            }
        }
        for (marker, weight, ci) in &profile.markers {
            let hit = if *ci {
                lower_sample.contains(&marker.to_lowercase())
            } else {
                sample.contains(*marker)
            };
            if hit {
                score += *weight;
            }
        }
        if score > 0.0 {
            scores.push((profile.id, score));
        }
    }

    scores.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    if let Some((top_id, top_score)) = scores.first() {
        if *top_score >= 4.0 {
            let second_score = scores.get(1).map(|s| s.1).unwrap_or(0.0);
            if second_score == 0.0 || *top_score >= second_score * 1.25 {
                let mut winner = *top_id;
                // JSX 后置规则：JS/TS 胜出但含组件标签语法 → React JSX/TSX
                if (winner == "javascript" || winner == "typescript")
                    && (sample.contains("</")
                        || sample.contains("/>")
                        || sample.contains("className="))
                {
                    winner = "jsx";
                }
                return LanguageClassification {
                    is_code: true,
                    language: Some(winner.to_string()),
                };
            }
        }
    }

    // 7. 行格式启发（YAML / TOML）
    if looks_like_yaml(&lines) {
        return LanguageClassification {
            is_code: true,
            language: Some("yaml".to_string()),
        };
    }
    if looks_like_toml(&lines) {
        return LanguageClassification {
            is_code: true,
            language: Some("toml".to_string()),
        };
    }

    // 8. 结构兜底：多行且符号种类丰富 → 归入代码分类（language 为 None，UI 展示 Code 并由 highlight.js 自动检测）
    let code_tokens = ["{", "}", "(", ")", ";", "=", "->", "=>", "[", "]"];
    let kinds = code_tokens.iter().filter(|t| trimmed.contains(**t)).count();
    if lines.len() >= 3 && kinds >= 4 {
        return LanguageClassification {
            is_code: true,
            language: None,
        };
    }

    LanguageClassification {
        is_code: false,
        language: None,
    }
}

fn sample_text(lines: &[&str]) -> String {
    let joined = lines
        .iter()
        .take(SAMPLE_LINE_LIMIT)
        .copied()
        .collect::<Vec<_>>()
        .join("\n");
    if joined.len() <= SAMPLE_BYTE_LIMIT {
        return joined;
    }
    let mut result = String::with_capacity(SAMPLE_BYTE_LIMIT);
    let mut count = 0;
    for ch in joined.chars() {
        let len = ch.len_utf8();
        if count + len > SAMPLE_BYTE_LIMIT {
            break;
        }
        result.push(ch);
        count += len;
    }
    result
}

fn is_terminal_output(sample: &str) -> bool {
    let mut box_count = 0;
    let mut esc_count = 0;
    for ch in sample.chars() {
        let code = ch as u32;
        if (0x2500..=0x259F).contains(&code) {
            box_count += 1;
            if box_count >= 4 {
                return true;
            }
        } else if code == 0x1B {
            esc_count += 1;
            if esc_count >= 2 {
                return true;
            }
        }
    }
    false
}

fn sample_has_cjk(lines: &[&str]) -> bool {
    lines.iter().take(20).any(|line| {
        line.chars()
            .any(|c| (0x4E00..=0x9FFF).contains(&(c as u32)))
    })
}

fn looks_like_yaml(lines: &[&str]) -> bool {
    let non_empty: Vec<&str> = lines
        .iter()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect();
    if non_empty.len() < 3 {
        return false;
    }
    if non_empty[0] == "---" {
        return true;
    }
    if sample_has_cjk(lines) {
        return false;
    }
    let check_lines: Vec<&str> = non_empty.into_iter().take(20).collect();
    let mut matches = 0usize;
    for line in &check_lines {
        if line.starts_with("- ") || *line == "-" {
            matches += 1;
            continue;
        }
        let Some(colon_idx) = line.find(':') else {
            continue;
        };
        if colon_idx == 0 {
            continue;
        }
        let key = &line[..colon_idx];
        let rest = &line[(colon_idx + 1)..];
        if rest.starts_with('{') {
            continue;
        }
        if !key.chars().all(|c| {
            c.is_ascii() && (c.is_ascii_alphanumeric() || "_-./ ".contains(c))
        }) {
            continue;
        }
        if rest.is_empty() || rest.starts_with(' ') {
            matches += 1;
        }
    }
    (matches as f64) / (check_lines.len() as f64) >= 0.6
}

fn looks_like_toml(lines: &[&str]) -> bool {
    let non_empty: Vec<&str> = lines
        .iter()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect();
    if non_empty.len() < 2 {
        return false;
    }
    let section_headers = non_empty
        .iter()
        .filter(|line| {
            if !line.starts_with('[') || !line.ends_with(']') || line.len() <= 2 {
                return false;
            }
            let inner = &line[1..(line.len() - 1)];
            inner
                .chars()
                .all(|c| c.is_alphanumeric() || c == '.' || c == '-' || c == '_')
        })
        .count();
    if section_headers == 0 {
        return false;
    }
    let kv_lines = non_empty.iter().filter(|l| l.contains(" = ")).count();
    if non_empty.iter().any(|l| l.contains('{') || l.contains(';')) {
        return false;
    }
    ((kv_lines + section_headers) as f64) / (non_empty.len() as f64) >= 0.5
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_lang(code: &str, expected: &str) {
        assert_eq!(
            classify_language(code).as_deref(),
            Some(expected),
            "expected language '{expected}' for sample:\n{code}"
        );
    }

    #[test]
    fn test_classify_all_31_supported_languages() {
        assert_lang(
            "package com.example.demo;\nimport java.util.List;\npublic class UserService {\n    private final UserRepository repository;\n    public User findById(Long id) {\n        return repository.findById(id).orElseThrow();\n    }\n}",
            "java",
        );
        assert_lang(
            "data class User(val name: String, val age: Int)\nfun main() {\n    println(User(\"Alice\", 30))\n}",
            "kotlin",
        );
        assert_lang(
            "import SwiftUI\nstruct CounterView: View {\n    @State private var count = 0\n    func increment() -> Int {\n        return count + 1\n    }\n}",
            "swift",
        );
        assert_lang(
            "#import <Foundation/Foundation.h>\n@interface User : NSObject\n@property (nonatomic, strong) NSString *name;\n@end",
            "objc",
        );
        assert_lang(
            "import numpy as np\ndef process_data(items):\n    result = [x * 2 for x in items]\n    return np.array(result)",
            "python",
        );
        assert_lang(
            "const arr = [1, 2, 3];\nconst doubled = arr.map(x => x * 2);\nconsole.log(doubled);",
            "javascript",
        );
        assert_lang(
            "interface User {\n    name: string;\n    age: number;\n}\nfunction greet(user: User): string {\n    return `Hello ${user.name}`;\n}",
            "typescript",
        );
        assert_lang(
            "import React, { useState } from 'react';\nfunction Counter() {\n  const [count, setCount] = useState(0);\n  return <div className=\"counter\"><button onClick={() => setCount(count + 1)}>Click</button></div>;\n}",
            "jsx",
        );
        assert_lang(
            "<template>\n  <div>{{ msg }}</div>\n</template>\n<script>\nexport default {}\n</script>",
            "vue",
        );
        assert_lang(
            "package main\nimport \"fmt\"\nfunc main() {\n    ch := make(chan int, 1)\n    defer close(ch)\n    fmt.Println(\"hello\", ch)\n}",
            "go",
        );
        assert_lang(
            "use std::collections::HashMap;\nfn main() {\n    let mut map = HashMap::new();\n    map.insert(\"key\", 42);\n    println!(\"{}\", map.len());\n}",
            "rust",
        );
        assert_lang(
            "#include <stdio.h>\nint main() {\n    printf(\"Hello, World!\\n\");\n    return 0;\n}",
            "c",
        );
        assert_lang(
            "#include <iostream>\nusing namespace std;\nint main() {\n    cout << \"Hello\" << endl;\n    return 0;\n}",
            "cpp",
        );
        assert_lang(
            "using System;\nnamespace Demo { public class Program { static void Main(string[] args) { Console.WriteLine(\"Hi\"); } } }",
            "csharp",
        );
        assert_lang(
            "class User < ApplicationRecord\n  def initialize(name)\n    @name = name\n  end\n  def greet\n    puts \"Hello #{@name}\"\n  end\nend",
            "ruby",
        );
        assert_lang(
            "<?php\nfunction greet($name) {\n    echo \"Hello \" . $name;\n    return true;\n}\n?>",
            "php",
        );
        assert_lang(
            "#!/bin/bash\nset -e\nfor f in *.txt; do\n  echo \"Processing $f\"\ndone",
            "shell",
        );
        assert_lang(
            "SELECT id, title, created_at FROM items\nWHERE is_favorite = 1\nORDER BY last_used_at DESC",
            "sql",
        );
        assert_lang(
            "<!DOCTYPE html>\n<html>\n<head><title>Test</title></head>\n<body>\n  <div class=\"container\">Hello</div>\n</body>\n</html>",
            "html",
        );
        assert_lang(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n  <item id=\"1\">hello</item>\n</root>",
            "xml",
        );
        assert_lang(
            "{\"name\":\"NookClip\",\"version\":2,\"features\":[\"clipboard\",\"ocr\"]}",
            "json",
        );
        assert_lang(
            "name: nook\nversion: 1.0.0\ndependencies:\n  - swift\n  - rust",
            "yaml",
        );
        assert_lang(
            "[package]\nname = \"nook\"\nversion = \"0.1.0\"",
            "toml",
        );
        assert_lang(
            ".card {\n  display: flex;\n  padding: 16px;\n  color: #333;\n  border-radius: 8px;\n}",
            "css",
        );
        assert_lang(
            "class User {\n  final String name;\n  User(this.name);\n  void greet() => print('Hello $name');\n}",
            "dart",
        );
        assert_lang(
            "local function greet(name)\n  print(\"Hello, \" .. name)\nend",
            "lua",
        );
        assert_lang(
            "library(ggplot2)\ndf <- data.frame(x = c(1, 2, 3))\nggplot(df, aes(x)) + geom_point()",
            "r",
        );
        assert_lang(
            "object Main extends App {\n  def greet(name: String): Unit = println(s\"hello $name\")\n}",
            "scala",
        );
        assert_lang(
            "Module Program\n    Sub Main()\n        Console.WriteLine(\"Hello\")\n    End Sub\nEnd Module",
            "vb",
        );
        assert_lang(
            "function y = square(x)\n    y = x.^2;\n    disp(y)\nend",
            "matlab",
        );
        assert_lang(
            "def message = ['hello', 'world']\nprintln message.join(' ')",
            "groovy",
        );
    }

    #[test]
    fn test_negative_samples_and_strict_confidence_heuristics() {
        // Chinese prose and key:value notes
        assert_eq!(classify_language("今天下午三点开会，请大家准时到二楼会议室参加项目评审。"), None);
        assert!(!is_code_like("今天下午三点开会，请大家准时到二楼会议室参加项目评审。"));
        assert!(!is_code_like("时间: 下午三点\n地点: 二楼会议室\n议题: 项目评审"));

        // English prose including Lua weak keywords (until/then)
        let prose = "Please wait until the build finishes, then close the terminal window.";
        assert_eq!(classify_language(prose), None);
        assert!(!is_code_like(prose));

        // Terminal box-drawing banner and ANSI escape output
        let banner = "┌─────────┐\n│ Recent  │\n└─────────┘\nWait until the sync finishes, then check.";
        assert_eq!(classify_language(banner), None);
        assert!(!is_code_like(banner));
        let ansi = "\u{1B}[32mSuccess\u{1B}[0m\n\u{1B}[31mError: timeout\u{1B}[0m\nDone in 2s";
        assert!(!is_code_like(ansi));

        // Structural fallback: multi-line code with rich symbols but ambiguous language
        let ambiguous = "foo(a, b) {\n  x = bar[0];\n  return x;\n}";
        assert_eq!(classify_language(ambiguous), None);
        assert!(is_code_like(ambiguous));
    }
}
