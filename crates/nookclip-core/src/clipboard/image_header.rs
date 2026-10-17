/// Extracts (width, height) in pixels from raw image bytes
/// without decoding pixels. Supports PNG, TIFF, BMP, JPEG, and GIF.
pub fn parse_image_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 10 {
        return None;
    }

    // 1. PNG: 8-byte magic + 4-byte length + "IHDR" + 4-byte width + 4-byte height
    if data.starts_with(b"\x89PNG\r\n\x1a\n") && data.len() >= 24 {
        if &data[12..16] == b"IHDR" {
            let width = u32::from_be_bytes(data[16..20].try_into().ok()?);
            let height = u32::from_be_bytes(data[20..24].try_into().ok()?);
            return Some((width, height));
        }
    }

    // 2. BMP: "BM" signature, width at offset 18..22, height at offset 22..26 (little endian)
    if data.starts_with(b"BM") && data.len() >= 26 {
        let width = u32::from_le_bytes(data[18..22].try_into().ok()?);
        let height_raw = i32::from_le_bytes(data[22..26].try_into().ok()?);
        let height = height_raw.unsigned_abs();
        if width > 0 && height > 0 {
            return Some((width, height));
        }
    }

    // 3. GIF: "GIF87a" or "GIF89a", width at 6..8, height at 8..10 (little endian)
    if (data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a")) && data.len() >= 10 {
        let width = u16::from_le_bytes(data[6..8].try_into().ok()?) as u32;
        let height = u16::from_le_bytes(data[8..10].try_into().ok()?) as u32;
        if width > 0 && height > 0 {
            return Some((width, height));
        }
    }

    // 4. TIFF: "II*\0" (little-endian) or "MM\0*" (big-endian)
    if data.starts_with(b"II*\0") || data.starts_with(b"MM\0*") {
        let is_le = data.starts_with(b"II");
        let read_u16 = |buf: &[u8]| -> Option<u16> {
            let bytes: [u8; 2] = buf.try_into().ok()?;
            Some(if is_le { u16::from_le_bytes(bytes) } else { u16::from_be_bytes(bytes) })
        };
        let read_u32 = |buf: &[u8]| -> Option<u32> {
            let bytes: [u8; 4] = buf.try_into().ok()?;
            Some(if is_le { u32::from_le_bytes(bytes) } else { u32::from_be_bytes(bytes) })
        };

        let ifd_offset = read_u32(data.get(4..8)?)? as usize;
        if ifd_offset + 2 <= data.len() {
            let num_entries = read_u16(data.get(ifd_offset..ifd_offset + 2)?)? as usize;
            let mut width = None;
            let mut height = None;

            for i in 0..num_entries {
                let entry_offset = ifd_offset + 2 + i * 12;
                if entry_offset + 12 > data.len() {
                    break;
                }
                let tag = read_u16(data.get(entry_offset..entry_offset + 2)?)?;
                let val_type = read_u16(data.get(entry_offset + 2..entry_offset + 4)?)?;
                let val_buf = data.get(entry_offset + 8..entry_offset + 12)?;

                let val = match val_type {
                    3 => read_u16(val_buf.get(0..2)?)? as u32, // SHORT
                    4 => read_u32(val_buf)?,                   // LONG
                    _ => continue,
                };

                if tag == 0x0100 {
                    width = Some(val);
                } else if tag == 0x0101 {
                    height = Some(val);
                }
                if width.is_some() && height.is_some() {
                    break;
                }
            }
            if let (Some(w), Some(h)) = (width, height) {
                if w > 0 && h > 0 {
                    return Some((w, h));
                }
            }
        }
    }

    // 5. JPEG: Starts with 0xFFD8, scans markers until SOF0 (0xFFC0) or SOF2 (0xFFC2)
    if data.starts_with(&[0xFF, 0xD8]) {
        let mut idx = 2;
        while idx + 4 <= data.len() {
            if data[idx] != 0xFF {
                break;
            }
            let marker = data[idx + 1];
            idx += 2;
            if marker == 0xD9 || marker == 0xDA {
                // EOI or SOS (start of scan)
                break;
            }
            if idx + 2 > data.len() {
                break;
            }
            let len = u16::from_be_bytes([data[idx], data[idx + 1]]) as usize;
            if len < 2 || idx + len > data.len() {
                break;
            }
            // SOF0 (Baseline), SOF1 (Extended), SOF2 (Progressive)
            if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
                if idx + 7 <= data.len() {
                    let height = u16::from_be_bytes([data[idx + 3], data[idx + 4]]) as u32;
                    let width = u16::from_be_bytes([data[idx + 5], data[idx + 6]]) as u32;
                    if width > 0 && height > 0 {
                        return Some((width, height));
                    }
                }
            }
            idx += len;
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_png_dimensions() {
        let mut data = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]; // 8-byte magic
        data.extend_from_slice(&13u32.to_be_bytes()); // length
        data.extend_from_slice(b"IHDR");
        data.extend_from_slice(&1920u32.to_be_bytes()); // width
        data.extend_from_slice(&1080u32.to_be_bytes()); // height
        data.extend_from_slice(&[8, 6, 0, 0, 0]);

        assert_eq!(parse_image_dimensions(&data), Some((1920, 1080)));
    }

    #[test]
    fn test_parse_bmp_dimensions() {
        let mut data = vec![0u8; 30];
        data[0] = b'B';
        data[1] = b'M';
        data[18..22].copy_from_slice(&800u32.to_le_bytes());
        data[22..26].copy_from_slice(&600i32.to_le_bytes());

        assert_eq!(parse_image_dimensions(&data), Some((800, 600)));
    }

    #[test]
    fn test_parse_gif_dimensions() {
        let mut data = b"GIF89a".to_vec();
        data.extend_from_slice(&320u16.to_le_bytes());
        data.extend_from_slice(&240u16.to_le_bytes());

        assert_eq!(parse_image_dimensions(&data), Some((320, 240)));
    }

    #[test]
    fn test_parse_tiff_le_dimensions() {
        let mut data = b"II*\0".to_vec();
        data.extend_from_slice(&8u32.to_le_bytes()); // IFD offset at 8
        data.extend_from_slice(&2u16.to_le_bytes()); // 2 entries

        // Tag 0x0100 (ImageWidth), Type 4 (LONG), Count 1, Value 1024
        data.extend_from_slice(&0x0100u16.to_le_bytes());
        data.extend_from_slice(&4u16.to_le_bytes());
        data.extend_from_slice(&1u32.to_le_bytes());
        data.extend_from_slice(&1024u32.to_le_bytes());

        // Tag 0x0101 (ImageLength), Type 3 (SHORT), Count 1, Value 768
        data.extend_from_slice(&0x0101u16.to_le_bytes());
        data.extend_from_slice(&3u16.to_le_bytes());
        data.extend_from_slice(&1u32.to_le_bytes());
        data.extend_from_slice(&768u16.to_le_bytes());
        data.extend_from_slice(&[0, 0]);

        assert_eq!(parse_image_dimensions(&data), Some((1024, 768)));
    }

    #[test]
    fn test_truncated_bytes_fallback() {
        assert_eq!(parse_image_dimensions(&[]), None);
        assert_eq!(parse_image_dimensions(b"\x89PNG\r\n\x1a\n"), None);
        assert_eq!(parse_image_dimensions(&[0xFF, 0xD8, 0xFF]), None);
    }
}
