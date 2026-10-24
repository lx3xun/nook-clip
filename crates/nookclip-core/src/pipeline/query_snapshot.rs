use crate::{
    error::Result,
    model::{CalendarContext, QueryFilter, QueryViewSnapshot},
    pipeline::timeline::group_items_by_timeline,
    search::tokenize_search_query,
    storage::repository::{StorageRepository, TimelineBoundaries},
};

pub fn query_view_snapshot(
    repo: &StorageRepository,
    filter: &QueryFilter,
    calendar: &CalendarContext,
) -> Result<QueryViewSnapshot> {
    // 1. 分词 (若有 search_query)
    let search_keywords = filter
        .search_query
        .as_deref()
        .map(|q| tokenize_search_query(q))
        .unwrap_or_default();

    // 2. 当前分页明细查询 (按 limit + 1 探测是否有更多行，BUG-018)
    let mut probe_filter = filter.clone();
    let requested_limit = filter.limit;
    probe_filter.limit = requested_limit.saturating_add(1);

    let mut items = repo.query_items(&probe_filter)?;
    let has_more = items.len() > requested_limit as usize;
    if has_more {
        items.truncate(requested_limit as usize);
    }

    // 3. 当前分页记录的时间分组
    let groups = group_items_by_timeline(items.clone(), calendar);

    // 4. 全量匹配记录的时间分组锚点计数 (不受分页 limit 截断)。
    //    边界按调用方时区在 Rust 侧算好后送 SQLite 聚合，
    //    不再把全库 last_used_at Vec<f64> 搬进内存再逐条 chrono 换算。
    let boundaries = timeline_boundaries(calendar);
    let anchor_rows = repo.time_group_anchor_counts(filter, &boundaries)?;
    // 当月桶的可见范围（10月 1–15日）需要知道「今天」是哪天：
    // 由与分组同一套时区换算得出，避免这里再算一遍本地日期
    let today_local = {
        let tz = chrono::FixedOffset::east_opt(calendar.tz_offset_secs)
            .unwrap_or_else(|| chrono::FixedOffset::east_opt(0).unwrap());
        chrono::DateTime::<chrono::Utc>::from_timestamp(calendar.now_ts as i64, 0)
            .unwrap_or_else(chrono::Utc::now)
            .with_timezone(&tz)
            .date_naive()
    };
    let timeline_anchors =
        crate::pipeline::timeline::anchor_rows_to_summaries(&anchor_rows, today_local);

    // 5. 分类统计 (在当前搜索词下)
    let category_counts = repo.count_categories(filter.search_query.as_deref(), filter.tag.as_deref())?;

    Ok(QueryViewSnapshot {
        items,
        groups,
        timeline_anchors,
        category_counts,
        search_keywords,
        has_more,
    })
}

/// 按日历上下文推导本地日/周/月边界（Unix 秒）。
/// SQLite 无时区概念，所有比较都以这些常量进行，保证与 Rust 侧
/// group_timestamps 的本地时区分组结果一致。
fn timeline_boundaries(calendar: &CalendarContext) -> TimelineBoundaries {
    let tz_secs = calendar.tz_offset_secs as i64;
    let day = 86_400i64;

    // 本地「今天 00:00」对应的 Unix 秒
    let now_local = calendar.now_ts as i64 + tz_secs;
    let today_start = now_local - now_local.rem_euclid(day);

    // 近档下界：与 timeline.rs 的 bucket_of 保持完全一致——分档依据是「自然日差」
    // 而非周界（不再有「上周」桶）。`SPAN_JUSTIFIED_DAYS` 天前的 00:00 是
    // 最后一天仍算「本周」的条目起点，更早一律进月/年桶。
    // 两边不同源会让锚点计数与列表项对不上。
    let this_week_start = today_start - crate::model::TimeGroupLevel::SPAN_JUSTIFIED_DAYS * day;
    // 已退役：仅供 SQL 与「近端」互斥判断，取与 this_week_start 相同值即让
    // last_week_count 恒为 0（该列保留以兼容既有查询形状）。
    let last_week_start = this_week_start;

    // 本地月份起点：本年度逐月回溯，更早年份按每年 1 月 1 日回溯至 1970 年。
    // 只回传起点时间戳，分组在 SQL 内完成。
    let mut month_starts = Vec::new();
    let today_civil = civil_from_days(today_start / day);
    let (mut y, mut m) = today_civil;
    while y >= 1970 {
        let start_days = days_from_civil(y, m, 1);
        month_starts.push((y, m, (start_days * day - tz_secs) as f64));
        if y == today_civil.0 {
            if m == 1 {
                m = 1;
                y -= 1;
            } else {
                m -= 1;
            }
        } else {
            y -= 1;
        }
    }

    TimelineBoundaries {
        today_start: (today_start - tz_secs) as f64,
        yesterday_start: (today_start - day - tz_secs) as f64,
        this_week_start: (this_week_start - tz_secs) as f64,
        last_week_start: (last_week_start - tz_secs) as f64,
        current_year: today_civil.0,
        month_starts,
    }
}

/// Unix 天数 → (年, 月)（民用历，与 chrono 日期换算一致的算法）
fn civil_from_days(days: i64) -> (i32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    ((y + if m <= 2 { 1 } else { 0 }) as i32, m as u32)
}

/// (年, 月, 日) → Unix 天数（民用历，Howard Hinnant 算法）
fn days_from_civil(y: i32, m: u32, d: i32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y } as i64;
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) as i64 + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}
