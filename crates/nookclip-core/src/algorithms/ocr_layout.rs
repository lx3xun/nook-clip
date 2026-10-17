/// OCR 识别文字块（坐标系：原点在左下角或归一化，Y 越大越靠上）
#[derive(Clone, Debug, PartialEq)]
pub struct OcrTextBlock {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl OcrTextBlock {
    #[inline]
    fn min_x(&self) -> f64 {
        self.x
    }

    #[inline]
    fn max_x(&self) -> f64 {
        self.x + self.width
    }

    #[inline]
    fn min_y(&self) -> f64 {
        self.y
    }

    #[inline]
    fn max_y(&self) -> f64 {
        self.y + self.height
    }

    #[inline]
    fn mid_y(&self) -> f64 {
        self.y + self.height * 0.5
    }
}

struct RenderedLine {
    text: String,
    min_y: f64,
    max_y: f64,
    avg_height: f64,
}

/// 根据文字块坐标重排版（同行聚类、行内从左到右排序、按间隙插空格、按段落行距插空行）
pub fn format_ocr_layout(blocks: &[OcrTextBlock]) -> String {
    if blocks.is_empty() {
        return String::new();
    }

    // 1. 按 Y 轴降序排列（Y 越大越靠上）
    let mut sorted_by_y = blocks.to_vec();
    sorted_by_y.sort_by(|a, b| {
        b.mid_y()
            .partial_cmp(&a.mid_y())
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // 2. 动态聚类归行
    let mut lines: Vec<Vec<OcrTextBlock>> = Vec::new();
    for block in sorted_by_y {
        let threshold = block.height * 0.5;
        let should_merge = lines
            .last()
            .and_then(|line| line.first())
            .map(|first| (first.mid_y() - block.mid_y()).abs() < threshold)
            .unwrap_or(false);

        if should_merge {
            if let Some(last_line) = lines.last_mut() {
                last_line.push(block);
            }
        } else {
            lines.push(vec![block]);
        }
    }

    // 3. 行内从左到右排序并按间距追加空格
    let mut rendered_lines: Vec<RenderedLine> = Vec::new();
    for mut line in lines {
        line.sort_by(|a, b| {
            a.min_x()
                .partial_cmp(&b.min_x())
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let mut line_string = String::new();
        let mut last_max_x: Option<f64> = None;

        for item in &line {
            let trimmed = item.text.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Some(prev_max_x) = last_max_x {
                let spacing = item.min_x() - prev_max_x;
                if spacing > item.height * 0.2 {
                    line_string.push(' ');
                }
            }
            line_string.push_str(trimmed);
            last_max_x = Some(item.max_x());
        }

        if !line_string.is_empty() {
            let min_y = line
                .iter()
                .map(|b| b.min_y())
                .fold(f64::INFINITY, f64::min);
            let max_y = line
                .iter()
                .map(|b| b.max_y())
                .fold(f64::NEG_INFINITY, f64::max);
            let avg_height =
                line.iter().map(|b| b.height).sum::<f64>() / (line.len() as f64);
            rendered_lines.push(RenderedLine {
                text: line_string,
                min_y,
                max_y,
                avg_height,
            });
        }
    }

    if rendered_lines.is_empty() {
        return String::new();
    }

    // 4. 多行组装：当相邻两行垂直间距明显大于正常行高（> 1.5 倍）时，保留空行分段
    let mut output = String::new();
    let mut prev_line: Option<&RenderedLine> = None;
    for line in &rendered_lines {
        if let Some(prev) = prev_line {
            let vertical_gap = prev.min_y - line.max_y;
            if vertical_gap > prev.avg_height * 1.5 {
                output.push_str("\n\n");
            } else {
                output.push('\n');
            }
        }
        output.push_str(&line.text);
        prev_line = Some(line);
    }

    output.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_same_line_blocks_merged_in_horizontal_order() {
        let block_right = OcrTextBlock {
            text: "World".to_string(),
            x: 0.5,
            y: 0.775,
            width: 0.3,
            height: 0.05,
        };
        let block_left = OcrTextBlock {
            text: "Hello".to_string(),
            x: 0.1,
            y: 0.775,
            width: 0.3,
            height: 0.05,
        };
        assert_eq!(format_ocr_layout(&[block_right, block_left]), "Hello World");
    }

    #[test]
    fn test_adjacent_blocks_without_gap_do_not_add_space() {
        let block1 = OcrTextBlock {
            text: "中".to_string(),
            x: 0.1,
            y: 0.8,
            width: 0.05,
            height: 0.05,
        };
        let block2 = OcrTextBlock {
            text: "文".to_string(),
            x: 0.151,
            y: 0.8,
            width: 0.05,
            height: 0.05,
        };
        assert_eq!(format_ocr_layout(&[block1, block2]), "中文");
    }

    #[test]
    fn test_multiple_lines_sorted_top_to_bottom() {
        let top = OcrTextBlock {
            text: "Top Line".to_string(),
            x: 0.1,
            y: 0.85,
            width: 0.3,
            height: 0.05,
        };
        let mid = OcrTextBlock {
            text: "Middle Line".to_string(),
            x: 0.1,
            y: 0.78,
            width: 0.3,
            height: 0.05,
        };
        let bot = OcrTextBlock {
            text: "Bottom Line".to_string(),
            x: 0.1,
            y: 0.71,
            width: 0.3,
            height: 0.05,
        };
        assert_eq!(
            format_ocr_layout(&[bot, top, mid]),
            "Top Line\nMiddle Line\nBottom Line"
        );
    }

    #[test]
    fn test_empty_blocks_ignored_and_paragraph_break() {
        let empty = OcrTextBlock {
            text: "   ".to_string(),
            x: 0.1,
            y: 0.85,
            width: 0.1,
            height: 0.05,
        };
        let p1 = OcrTextBlock {
            text: "Paragraph 1".to_string(),
            x: 0.1,
            y: 0.85,
            width: 0.4,
            height: 0.05,
        };
        let p2 = OcrTextBlock {
            text: "Paragraph 2".to_string(),
            x: 0.1,
            y: 0.55,
            width: 0.4,
            height: 0.05,
        };
        assert_eq!(
            format_ocr_layout(&[empty, p1, p2]),
            "Paragraph 1\n\nParagraph 2"
        );
    }
}
