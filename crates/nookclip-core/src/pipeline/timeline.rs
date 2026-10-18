use chrono::{DateTime, Datelike, FixedOffset, Utc};
use std::collections::BTreeMap;

use crate::model::{CalendarContext, ClipItemSummary, TimeBucketKey, TimeGroupSection, TimeGroupSummary};

pub fn group_items_by_timeline(
    items: Vec<ClipItemSummary>,
    calendar: &CalendarContext,
) -> Vec<TimeGroupSection> {
    if items.is_empty() {
        return Vec::new();
    }

    let tz = match FixedOffset::east_opt(calendar.tz_offset_secs) {
        Some(off) => off,
        None => FixedOffset::east_opt(0).unwrap(),
    };

    let now_utc = DateTime::<Utc>::from_timestamp(calendar.now_ts as i64, 0).unwrap_or_else(|| Utc::now());
    let now_local = now_utc.with_timezone(&tz);
    let today_date = now_local.date_naive();
    let yesterday_date = today_date.pred_opt().unwrap_or(today_date);
    let current_year = now_local.year();

    // 计算本周与上周的周界（循环外一次推导，避免每条目重复时间减法与 ISO 周换算）
    let this_week_num = now_local.iso_week().week();
    let this_week_year = now_local.iso_week().year();
    let last_week_ref = now_local - chrono::Duration::days(7);
    let last_week_num = last_week_ref.iso_week().week();
    let last_week_year = last_week_ref.iso_week().year();

    let mut today_items = Vec::new();
    let mut yesterday_items = Vec::new();
    let mut this_week_items = Vec::new();
    let mut last_week_items = Vec::new();
    let mut month_buckets: BTreeMap<(i32, u32), Vec<ClipItemSummary>> = BTreeMap::new();
    let mut year_buckets: BTreeMap<i32, Vec<ClipItemSummary>> = BTreeMap::new();

    for item in items {
        let dt_utc = DateTime::<Utc>::from_timestamp(item.last_used_at as i64, 0).unwrap_or(now_utc);
        let dt_local = dt_utc.with_timezone(&tz);
        let item_date = dt_local.date_naive();

        if item_date == today_date {
            today_items.push(item);
        } else if item_date == yesterday_date {
            yesterday_items.push(item);
        } else if dt_local.iso_week().week() == this_week_num && dt_local.iso_week().year() == this_week_year {
            this_week_items.push(item);
        } else {
            // 判定是否属于上周 (相对于本周前推 7 天对应的那一周)
            if dt_local.iso_week().week() == last_week_num && dt_local.iso_week().year() == last_week_year {
                last_week_items.push(item);
            } else if dt_local.year() == current_year {
                month_buckets.entry((dt_local.year(), dt_local.month())).or_default().push(item);
            } else {
                year_buckets.entry(dt_local.year()).or_default().push(item);
            }
        }
    }

    let mut sections = Vec::new();

    if !today_items.is_empty() {
        sections.push(TimeGroupSection {
            id: "today".to_string(),
            bucket: TimeBucketKey::Today,
            items: today_items,
        });
    }
    if !yesterday_items.is_empty() {
        sections.push(TimeGroupSection {
            id: "yesterday".to_string(),
            bucket: TimeBucketKey::Yesterday,
            items: yesterday_items,
        });
    }
    if !this_week_items.is_empty() {
        sections.push(TimeGroupSection {
            id: "this-week".to_string(),
            bucket: TimeBucketKey::ThisWeek,
            items: this_week_items,
        });
    }
    if !last_week_items.is_empty() {
        sections.push(TimeGroupSection {
            id: "last-week".to_string(),
            bucket: TimeBucketKey::LastWeek,
            items: last_week_items,
        });
    }
    for ((year, month), m_items) in month_buckets.into_iter().rev() {
        sections.push(TimeGroupSection {
            id: format!("month-{month}"),
            bucket: TimeBucketKey::Month { year, month },
            items: m_items,
        });
    }
    for (year, y_items) in year_buckets.into_iter().rev() {
        sections.push(TimeGroupSection {
            id: format!("year-{year}"),
            bucket: TimeBucketKey::Year { year },
            items: y_items,
        });
    }

    sections
}

pub fn group_timestamps(
    timestamps: &[f64],
    calendar: &CalendarContext,
) -> Vec<TimeGroupSummary> {
    if timestamps.is_empty() {
        return Vec::new();
    }

    let tz = match FixedOffset::east_opt(calendar.tz_offset_secs) {
        Some(off) => off,
        None => FixedOffset::east_opt(0).unwrap(),
    };

    let now_utc = DateTime::<Utc>::from_timestamp(calendar.now_ts as i64, 0).unwrap_or_else(|| Utc::now());
    let now_local = now_utc.with_timezone(&tz);
    let today_date = now_local.date_naive();
    let yesterday_date = today_date.pred_opt().unwrap_or(today_date);
    let current_year = now_local.year();
    let this_week_num = now_local.iso_week().week();
    let this_week_year = now_local.iso_week().year();
    // 上周基准在循环外一次推导，循环内只比对数字
    let last_week_ref = now_local - chrono::Duration::days(7);
    let last_week_num = last_week_ref.iso_week().week();
    let last_week_year = last_week_ref.iso_week().year();

    let mut today_count = 0u32;
    let mut yesterday_count = 0u32;
    let mut this_week_count = 0u32;
    let mut last_week_count = 0u32;
    let mut month_counts: BTreeMap<(i32, u32), u32> = BTreeMap::new();
    let mut year_counts: BTreeMap<i32, u32> = BTreeMap::new();

    for &ts in timestamps {
        let dt_utc = DateTime::<Utc>::from_timestamp(ts as i64, 0).unwrap_or(now_utc);
        let dt_local = dt_utc.with_timezone(&tz);
        let item_date = dt_local.date_naive();

        if item_date == today_date {
            today_count += 1;
        } else if item_date == yesterday_date {
            yesterday_count += 1;
        } else if dt_local.iso_week().week() == this_week_num && dt_local.iso_week().year() == this_week_year {
            this_week_count += 1;
        } else {
            if dt_local.iso_week().week() == last_week_num && dt_local.iso_week().year() == last_week_year {
                last_week_count += 1;
            } else if dt_local.year() == current_year {
                *month_counts.entry((dt_local.year(), dt_local.month())).or_default() += 1;
            } else {
                *year_counts.entry(dt_local.year()).or_default() += 1;
            }
        }
    }

    let mut summaries = Vec::new();
    if today_count > 0 {
        summaries.push(TimeGroupSummary {
            id: "today".to_string(),
            bucket: TimeBucketKey::Today,
            count: today_count,
        });
    }
    if yesterday_count > 0 {
        summaries.push(TimeGroupSummary {
            id: "yesterday".to_string(),
            bucket: TimeBucketKey::Yesterday,
            count: yesterday_count,
        });
    }
    if this_week_count > 0 {
        summaries.push(TimeGroupSummary {
            id: "this-week".to_string(),
            bucket: TimeBucketKey::ThisWeek,
            count: this_week_count,
        });
    }
    if last_week_count > 0 {
        summaries.push(TimeGroupSummary {
            id: "last-week".to_string(),
            bucket: TimeBucketKey::LastWeek,
            count: last_week_count,
        });
    }
    for ((year, month), count) in month_counts.into_iter().rev() {
        summaries.push(TimeGroupSummary {
            id: format!("month-{month}"),
            bucket: TimeBucketKey::Month { year, month },
            count,
        });
    }
    for (year, count) in year_counts.into_iter().rev() {
        summaries.push(TimeGroupSummary {
            id: format!("year-{year}"),
            bucket: TimeBucketKey::Year { year },
            count,
        });
    }

    summaries
}

/// 把 SQL 聚合出的锚点计数行转换为 TimeGroupSummary（供 query_snapshot 用）。
/// 第一行是四个近端计数，后续每行一个更早的本地月份桶（降序）。
pub fn anchor_rows_to_summaries(rows: &[crate::storage::repository::AnchorCountRow]) -> Vec<TimeGroupSummary> {
    let mut summaries = Vec::new();
    let Some(first) = rows.first() else {
        return summaries;
    };

    if first.today_count > 0 {
        summaries.push(TimeGroupSummary {
            id: "today".to_string(),
            bucket: TimeBucketKey::Today,
            count: first.today_count,
        });
    }
    if first.yesterday_count > 0 {
        summaries.push(TimeGroupSummary {
            id: "yesterday".to_string(),
            bucket: TimeBucketKey::Yesterday,
            count: first.yesterday_count,
        });
    }
    if first.this_week_count > 0 {
        summaries.push(TimeGroupSummary {
            id: "this-week".to_string(),
            bucket: TimeBucketKey::ThisWeek,
            count: first.this_week_count,
        });
    }
    if first.last_week_count > 0 {
        summaries.push(TimeGroupSummary {
            id: "last-week".to_string(),
            bucket: TimeBucketKey::LastWeek,
            count: first.last_week_count,
        });
    }
    for row in &rows[1..] {
        if row.year_count == 0 {
            continue;
        }
        if let Some(year) = row.year.filter(|_| row.month.is_none()) {
            summaries.push(TimeGroupSummary {
                id: format!("year-{year}"),
                bucket: TimeBucketKey::Year { year },
                count: row.year_count,
            });
        } else if let (Some(year), Some(month)) = (row.year, row.month) {
            summaries.push(TimeGroupSummary {
                id: format!("month-{month}"),
                bucket: TimeBucketKey::Month { year, month },
                count: row.year_count,
            });
        }
    }
    summaries
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_timeline_grouping_and_anchors() {
        // 固定当前基准时间: 2026-10-16 12:00:00 UTC (星期五)
        let now_ts = 1792152000.0;
        let calendar = CalendarContext {
            now_ts,
            tz_offset_secs: 0,
            first_weekday: 1,
        };

        let make_item = |id: &str, ts: f64| ClipItemSummary {
            id: id.to_string(),
            item_type: "text".to_string(),
            title: id.to_string(),
            summary: id.to_string(),
            created_at: ts,
            last_used_at: ts,
            copy_count: 1,
            favorite: false,
            source_app_bundle_id: None,
            source_app_name: None,
            source_device_id: None,
            source_device_name: None,
            source_platform: None,
            is_sensitive: false,
            deleted_at: None,
            payload_path: None,
            ocr_text: None,
            metadata_json: None,
            kind: "text".to_string(),
        };

        let items = vec![
            make_item("today", now_ts - 100.0),
            make_item("yesterday", now_ts - 86400.0),
            make_item("this_week", now_ts - 86400.0 * 2.0),
            make_item("last_week", now_ts - 86400.0 * 7.0),
            make_item("last_month", now_ts - 86400.0 * 40.0),
            make_item("last_year", now_ts - 86400.0 * 400.0),
        ];

        let sections = group_items_by_timeline(items, &calendar);
        let ids: Vec<&str> = sections.iter().map(|s| s.id.as_str()).collect();
        assert!(ids.contains(&"today"));
        assert!(ids.contains(&"yesterday"));
        assert!(ids.contains(&"this-week"));
        assert!(ids.contains(&"last-week"));

        let timestamps: Vec<f64> = vec![
            now_ts - 100.0,
            now_ts - 86400.0,
            now_ts - 86400.0 * 2.0,
            now_ts - 86400.0 * 7.0,
            now_ts - 86400.0 * 40.0,
            now_ts - 86400.0 * 400.0,
        ];
        let anchors = group_timestamps(&timestamps, &calendar);
        assert_eq!(anchors.len(), sections.len());
        for (a, s) in anchors.iter().zip(sections.iter()) {
            assert_eq!(a.id, s.id);
            assert_eq!(a.count, s.items.len() as u32);
        }
    }
}
