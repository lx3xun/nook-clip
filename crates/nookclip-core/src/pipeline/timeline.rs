use chrono::{DateTime, Datelike, FixedOffset, Utc};
use std::collections::BTreeMap;

use crate::model::{
    CalendarContext, ClipItemSummary, TimeBucketKey, TimeGroupLevel, TimeGroupSection,
    TimeGroupSummary,
};

/// 时间分组的分档决策：给定本地时间戳，返回它归属于哪个桶。
/// 逐条分组（group_items_by_timeline）与全量锚点聚合（group_timestamps）
/// 共用本函数——两处各自实现过一次，任何一边改动都会让锚点计数与列表项对不上。
#[derive(Clone, Debug, PartialEq, Eq)]
enum Bucket {
    Today,
    Yesterday,
    ThisWeek,
    Month {
        year: i32,
        month: u32,
        /// 本月桶实际覆盖到的最后一天：月初 → (今天 - 近档窗口)。
        /// 展示层用它渲染「10月 1–15日」，说明这一段不含上面的近档。
        last_day: u32,
    },
    Year(i32),
}

/// 近档（今天/昨天/本周）与远档（月份/年份）的统一判定。
///
/// 分档依据是「该条目的自然日差」（今天 = 0），不是周界：
/// 距今 ≤ `TimeGroupLevel::SPAN_JUSTIFIED_DAYS` 天 → 近档三段；
/// 更早一律进入月档/年档——不再有「上周」这个中间档。
///
/// 为什么去掉「上周」：本周最多回溯 7 天，而「上周」这一档最多覆盖 7 天，
/// 月档一个月最多 31 天。若保留「上周」，列表里会出现
/// 今天 / 昨天 / 本月 / 上周 这种粒度忽细忽粗的断层——「上周」夹在「本月」之后，
/// 读者需要在脑子里把「上周」重新换算成具体日期才能判断该点哪里。
/// 去掉后只剩两种粒度：7 天内按天，7 天外按月。
fn bucket_of(
    ts_local: chrono::NaiveDate,
    today: chrono::NaiveDate,
    current_year: i32,
) -> Bucket {
    let elapsed = (ts_local - today).num_days();
    if elapsed >= 0 {
        return Bucket::Today;
    }
    if elapsed == -1 {
        return Bucket::Yesterday;
    }
    // 距今 2..=SPAN_JUSTIFIED_DAYS 天 → 仍属近档
    if (-TimeGroupLevel::SPAN_JUSTIFIED_DAYS..=-2).contains(&elapsed) {
        return Bucket::ThisWeek;
    }
    let year = ts_local.year();
    if year == current_year {
        Bucket::Month {
            year,
            month: ts_local.month(),
            last_day: month_bucket_last_day(ts_local.month(), today),
        }
    } else {
        Bucket::Year(year)
    }
}

/// 某个月份桶实际覆盖到的最后一天（本地日）。
///
/// 当月桶只装「近档窗口之外」的条目：今天是 10/23、窗口 7 天 →
/// 近档覆盖 10/16–10/23，当月桶是 10/1–10/15，`last_day` = 15。
/// 历史月份是完整的，返回该月天数。月初时当月桶为空区间（返回 0），
/// 此时该月不会产生桶。
pub(crate) fn month_bucket_last_day(month: u32, today: chrono::NaiveDate) -> u32 {
    if month != today.month() {
        return days_in_month(today.year(), month);
    }
    // 当月：上界 = 今天 - (窗口天数 + 1)，因为「今天」也算在窗口内
    let cutoff = today - chrono::Duration::days(TimeGroupLevel::SPAN_JUSTIFIED_DAYS + 1);
    if cutoff.month() != month || cutoff.year() != today.year() {
        return 0; // 月初：整个当月都还在近档里
    }
    cutoff.day()
}

/// 某年某月的天数
pub(crate) fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
            if leap { 29 } else { 28 }
        }
        _ => 30,
    }
}

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
    let current_year = now_local.year();

    let mut today_items = Vec::new();
    let mut yesterday_items = Vec::new();
    let mut this_week_items = Vec::new();
    let mut month_buckets: BTreeMap<(i32, u32), Vec<ClipItemSummary>> = BTreeMap::new();
    let mut year_buckets: BTreeMap<i32, Vec<ClipItemSummary>> = BTreeMap::new();

    for item in items {
        let dt_utc = DateTime::<Utc>::from_timestamp(item.last_used_at as i64, 0).unwrap_or(now_utc);
        let dt_local = dt_utc.with_timezone(&tz);
        match bucket_of(dt_local.date_naive(), today_date, current_year) {
            Bucket::Today => today_items.push(item),
            Bucket::Yesterday => yesterday_items.push(item),
            Bucket::ThisWeek => this_week_items.push(item),
            // last_day 与 (year, month) 一一对应，分组时按组统一重算
            Bucket::Month { year, month, .. } => {
                month_buckets.entry((year, month)).or_default().push(item)
            }
            Bucket::Year(year) => year_buckets.entry(year).or_default().push(item),
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
    for ((year, month), m_items) in month_buckets.into_iter().rev() {
        sections.push(TimeGroupSection {
            id: format!("month-{month}"),
            bucket: TimeBucketKey::Month {
                year,
                month,
                last_day: month_bucket_last_day(month, today_date),
            },
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
    let current_year = now_local.year();

    let mut today_count = 0u32;
    let mut yesterday_count = 0u32;
    let mut this_week_count = 0u32;
    let mut month_counts: BTreeMap<(i32, u32), u32> = BTreeMap::new();
    let mut year_counts: BTreeMap<i32, u32> = BTreeMap::new();

    for &ts in timestamps {
        let dt_utc = DateTime::<Utc>::from_timestamp(ts as i64, 0).unwrap_or(now_utc);
        let dt_local = dt_utc.with_timezone(&tz);
        match bucket_of(dt_local.date_naive(), today_date, current_year) {
            Bucket::Today => today_count += 1,
            Bucket::Yesterday => yesterday_count += 1,
            Bucket::ThisWeek => this_week_count += 1,
            Bucket::Month { year, month, .. } => {
                *month_counts.entry((year, month)).or_default() += 1;
            }
            Bucket::Year(year) => {
                *year_counts.entry(year).or_default() += 1;
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
    for ((year, month), count) in month_counts.into_iter().rev() {
        summaries.push(TimeGroupSummary {
            id: format!("month-{month}"),
            bucket: TimeBucketKey::Month {
                year,
                month,
                last_day: month_bucket_last_day(month, today_date),
            },
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
/// 第一行是三个近端计数，后续每行一个更早的本地月份桶（降序）。
///
/// `last_week_count` 已随「上周」档退役，SQL 仍会回传该列（保留兼容），此处忽略。
/// `today` 用于标注当月桶的 `last_day`（该桶只装近档窗口之外的条目）。
pub fn anchor_rows_to_summaries(
    rows: &[crate::storage::repository::AnchorCountRow],
    today: chrono::NaiveDate,
) -> Vec<TimeGroupSummary> {
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
                bucket: TimeBucketKey::Month {
                    year,
                    month,
                    last_day: month_bucket_last_day(month, today),
                },
                count: row.year_count,
            });
        }
    }
    summaries
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_item(id: &str, ts: f64) -> ClipItemSummary {
        ClipItemSummary {
            id: id.to_string(),
            item_type: "text".to_string(),
            title: id.to_string(),
            summary: id.to_string(),
            created_at: ts,
            last_used_at: ts,
            copy_count: 1,
            favorite: false,
            ..Default::default()
        }
    }

    fn calendar_at(now_ts: f64) -> CalendarContext {
        CalendarContext {
            now_ts,
            tz_offset_secs: 0,
            first_weekday: 1,
        }
    }

    /// 逐条分组与全量锚点聚合必须逐组同序同数（两者共用 bucket_of）
    fn assert_item_and_timestamp_agree(items: Vec<ClipItemSummary>, calendar: &CalendarContext) {
        let sections = group_items_by_timeline(items.clone(), calendar);
        let timestamps: Vec<f64> = items.iter().map(|i| i.last_used_at).collect();
        let anchors = group_timestamps(&timestamps, calendar);
        let section_ids: Vec<&str> = sections.iter().map(|s| s.id.as_str()).collect();
        let anchor_ids: Vec<&str> = anchors.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(section_ids, anchor_ids, "分组 id 序列必须一致");
        for (a, s) in anchors.iter().zip(sections.iter()) {
            assert_eq!(a.count, s.items.len() as u32, "组 {} 计数必须一致", a.id);
        }
        let total: u32 = anchors.iter().map(|a| a.count).sum();
        assert_eq!(total as usize, items.len(), "锚点计数之和必须等于条目数（不得漏计/重计）");
    }

    /// 2026-10-16 12:00 UTC，星期五；本周（ISO 周一起）从 10-12 起
    const NOW: f64 = 1_792_152_000.0;
    const DAY: f64 = 86_400.0;

    #[test]
    fn test_near_tiers_split_by_elapsed_days() {
        // 今天 / 昨天 / 3 天前（仍在 7 天窗口内）→ 三个近档依次出现
        let items = vec![
            make_item("today", NOW - 100.0),
            make_item("yesterday", NOW - DAY),
            make_item("d3", NOW - 3.0 * DAY),
        ];
        let sections = group_items_by_timeline(items, &calendar_at(NOW));
        assert_eq!(
            sections.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            vec!["today", "yesterday", "this-week"]
        );
    }

    #[test]
    fn test_span_tier_includes_seven_days_ago() {
        // 正好 7 天前仍在「近档」——这是分档阈值本身，必须有测试钉住
        let items = vec![make_item("d7", NOW - 7.0 * DAY)];
        let sections = group_items_by_timeline(items, &calendar_at(NOW));
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].id, "this-week");
    }

    #[test]
    fn test_span_tier_excludes_eight_days_ago() {
        // 8 天前应进入月份桶，而不是单独的「上周」桶
        let items = vec![make_item("d8", NOW - 8.0 * DAY)];
        let sections = group_items_by_timeline(items, &calendar_at(NOW));
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].id, "month-10");
        assert!(
            sections.iter().all(|s| s.id != "last-week"),
            "「上周」桶已退役，不得再出现"
        );
    }

    #[test]
    fn test_last_week_bucket_is_gone() {
        // 回归：曾经会出现 today / yesterday / 本月 / 上周 的粒度断层
        let items = vec![
            make_item("today", NOW - 100.0),
            make_item("yesterday", NOW - DAY),
            make_item("last-month", NOW - 40.0 * DAY),
            make_item("last-week", NOW - 9.0 * DAY),
            make_item("last-year", NOW - 400.0 * DAY),
        ];
        let sections = group_items_by_timeline(items, &calendar_at(NOW));
        let ids: Vec<&str> = sections.iter().map(|s| s.id.as_str()).collect();
        assert!(!ids.contains(&"last-week"), "实际分组：{ids:?}");
        assert_eq!(ids[0], "today");
        assert_eq!(ids[1], "yesterday");
        // 近档之后立即进入月档，粒度断层消失
        assert!(ids[2].starts_with("month-"), "实际分组：{ids:?}");
    }

    #[test]
    fn test_far_tier_groups_by_month_and_year() {
        let items = vec![
            make_item("d8", NOW - 8.0 * DAY),
            make_item("d40", NOW - 40.0 * DAY),
            make_item("d400", NOW - 400.0 * DAY),
        ];
        let sections = group_items_by_timeline(items, &calendar_at(NOW));
        let ids: Vec<&str> = sections.iter().map(|s| s.id.as_str()).collect();
        // 同年 → month-10 / month-9；跨年 → year-2025
        assert_eq!(ids, vec!["month-10", "month-9", "year-2025"]);
    }

    #[test]
    fn test_month_bucket_last_day_for_current_month() {
        // 今天 2026-10-23，窗口 7 天 → 近档覆盖 10/16–10/23，本月桶到 10/15
        let today = chrono::NaiveDate::from_ymd_opt(2026, 10, 23).unwrap();
        assert_eq!(month_bucket_last_day(10, today), 15);
    }

    #[test]
    fn test_month_bucket_last_day_for_historical_month() {
        // 历史月份覆盖整月：9 月 30 天、2 月 28/29 天
        let today = chrono::NaiveDate::from_ymd_opt(2026, 10, 23).unwrap();
        assert_eq!(month_bucket_last_day(9, today), 30);
        assert_eq!(month_bucket_last_day(2, today), 28);
        let leap_day = chrono::NaiveDate::from_ymd_opt(2024, 3, 15).unwrap();
        assert_eq!(month_bucket_last_day(2, leap_day), 29, "闰年 2 月");
    }

    #[test]
    fn test_month_bucket_last_day_zero_early_in_month() {
        // 今天 10/3：近档覆盖 9/27–10/3，整个 10 月都还没进月档 → 0（该桶不产生）
        let today = chrono::NaiveDate::from_ymd_opt(2026, 10, 3).unwrap();
        assert_eq!(month_bucket_last_day(10, today), 0);
    }

    #[test]
    fn test_month_bucket_range_matches_tier_boundary() {
        // 桶上界必须正好卡在近档之外。基准取 2026-10-23 12:00 UTC（周五）：
        // 近档覆盖 10/16–10/23，本月桶到 10/15 → 10/15 进月档、10/16 进近档。
        let now_oct23 = NOW + 7.0 * DAY;
        let sections = group_items_by_timeline(
            vec![
                make_item("d15", now_oct23 - 8.0 * DAY), // 10/15
                make_item("d16", now_oct23 - 7.0 * DAY), // 10/16
            ],
            &calendar_at(now_oct23),
        );
        let month = sections.iter().find(|s| s.id.starts_with("month-")).expect("应有月份桶");
        assert_eq!(month.items.len(), 1, "月份桶只应装 10/15 一条");
        assert_eq!(month.items[0].id, "d15");
        match &month.bucket {
            TimeBucketKey::Month { last_day, .. } => assert_eq!(*last_day, 15),
            other => panic!("期望 Month 桶，实际 {other:?}"),
        }
    }

    #[test]
    fn test_bucket_level_threshold() {
        assert_eq!(TimeGroupLevel::for_elapsed_days(0), TimeGroupLevel::Near);
        assert_eq!(TimeGroupLevel::for_elapsed_days(7), TimeGroupLevel::Near);
        assert_eq!(TimeGroupLevel::for_elapsed_days(8), TimeGroupLevel::Far);
    }

    #[test]
    fn test_timeline_grouping_and_anchors() {
        let items = vec![
            make_item("today", NOW - 100.0),
            make_item("yesterday", NOW - DAY),
            make_item("this_week", NOW - DAY * 2.0),
            make_item("d7", NOW - DAY * 7.0),
            make_item("last_week", NOW - DAY * 9.0),
            make_item("last_month", NOW - DAY * 40.0),
            make_item("last_year", NOW - DAY * 400.0),
        ];
        assert_item_and_timestamp_agree(items, &calendar_at(NOW));
    }

    #[test]
    fn test_distant_past_grouping_and_anchors_agree() {
        // 更早的跨度：3 个月、8 个月、跨两年
        let items = vec![
            make_item("d8", NOW - 8.0 * DAY),
            make_item("d90", NOW - 90.0 * DAY),
            make_item("d250", NOW - 250.0 * DAY),
            make_item("d900", NOW - 900.0 * DAY),
        ];
        assert_item_and_timestamp_agree(items, &calendar_at(NOW));
    }
}
