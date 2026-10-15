/// Tokenizes a pure search string into phrases and keywords.
/// Quoted strings `"exact phrase"` are preserved as single tokens.
/// Unquoted words are split by whitespace.
pub fn tokenize_search_query(query: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut in_quote = false;
    let mut current = String::new();

    for ch in query.chars() {
        if ch == '"' {
            if in_quote {
                if !current.trim().is_empty() {
                    tokens.push(current.trim().to_string());
                }
                current.clear();
                in_quote = false;
            } else {
                if !current.trim().is_empty() {
                    for word in current.split_whitespace() {
                        tokens.push(word.to_string());
                    }
                }
                current.clear();
                in_quote = true;
            }
        } else {
            current.push(ch);
        }
    }

    if !current.trim().is_empty() {
        if in_quote {
            tokens.push(current.trim().to_string());
        } else {
            for word in current.split_whitespace() {
                tokens.push(word.to_string());
            }
        }
    }

    tokens
}

pub fn format_fts_match_query(query: &str) -> String {
    let tokens = tokenize_search_query(query);
    if tokens.is_empty() {
        return String::new();
    }

    tokens
        .into_iter()
        .map(|token| format!("\"{}\"", token.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_fts_query() {
        assert_eq!(format_fts_match_query("hello world"), "\"hello\" \"world\"");
        assert_eq!(format_fts_match_query("高性能 内核"), "\"高性能\" \"内核\"");
        assert_eq!(
            format_fts_match_query("hello \"exact phrase\" world"),
            "\"hello\" \"exact phrase\" \"world\""
        );
        assert_eq!(format_fts_match_query("type: text"), "\"type:\" \"text\"");
    }
}
