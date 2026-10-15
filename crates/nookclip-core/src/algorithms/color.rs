pub fn parse_color_hex(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.len() < 4 || trimmed.len() > 25 {
        return None;
    }

    // 1. Hex: #RGB, #RRGGBB, #RRGGBBAA
    if let Some(hex) = trimmed.strip_prefix('#') {
        if !hex.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }

        let int_val = u64::from_str_radix(hex, 16).ok()?;

        let (r, g, b) = match hex.len() {
            3 => {
                let r = ((int_val >> 8) & 0xF) * 17;
                let g = ((int_val >> 4) & 0xF) * 17;
                let b = (int_val & 0xF) * 17;
                (r, g, b)
            }
            6 => {
                let r = (int_val >> 16) & 0xFF;
                let g = (int_val >> 8) & 0xFF;
                let b = int_val & 0xFF;
                (r, g, b)
            }
            8 => {
                let r = (int_val >> 24) & 0xFF;
                let g = (int_val >> 16) & 0xFF;
                let b = (int_val >> 8) & 0xFF;
                (r, g, b)
            }
            _ => return None,
        };

        return Some(format!("#{:02X}{:02X}{:02X}", r, g, b));
    }

    // 2. rgb(r, g, b)
    let lower = trimmed.to_lowercase();
    if lower.starts_with("rgb(") && lower.ends_with(')') {
        let inner = &trimmed[4..trimmed.len() - 1];
        let parts: Vec<&str> = inner.split(',').map(|s| s.trim()).collect();
        if parts.len() == 3 {
            let r: u8 = parts[0].parse().ok()?;
            let g: u8 = parts[1].parse().ok()?;
            let b: u8 = parts[2].parse().ok()?;
            return Some(format!("#{:02X}{:02X}{:02X}", r, g, b));
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hex_3() {
        assert_eq!(parse_color_hex("#FFF"), Some("#FFFFFF".to_string()));
        assert_eq!(parse_color_hex("#f0a"), Some("#FF00AA".to_string()));
    }

    #[test]
    fn test_hex_6() {
        assert_eq!(parse_color_hex("#3498DB"), Some("#3498DB".to_string()));
        assert_eq!(parse_color_hex("#123456"), Some("#123456".to_string()));
    }

    #[test]
    fn test_hex_8() {
        assert_eq!(parse_color_hex("#3498DBFF"), Some("#3498DB".to_string()));
    }

    #[test]
    fn test_invalid_hex() {
        assert_eq!(parse_color_hex("#define"), None);
        assert_eq!(parse_color_hex("#coffee"), None);
    }

    #[test]
    fn test_rgb() {
        assert_eq!(
            parse_color_hex("rgb(52, 152, 219)"),
            Some("#3498DB".to_string())
        );
    }
}
