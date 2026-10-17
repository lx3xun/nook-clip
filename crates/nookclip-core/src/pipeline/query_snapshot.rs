use crate::{
    error::Result,
    model::{CalendarContext, QueryFilter, QueryViewSnapshot},
    pipeline::timeline::{group_items_by_timeline, group_timestamps},
    search::tokenize_search_query,
    storage::repository::StorageRepository,
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

    // 4. 全量匹配记录的时间分组锚点计数 (不受分页 limit 截断)
    let all_timestamps = repo.time_group_timestamps(filter)?;
    let timeline_anchors = group_timestamps(&all_timestamps, calendar);

    // 5. 分类统计 (在当前搜索词下)
    let category_counts = repo.count_categories(filter.search_query.as_deref())?;

    Ok(QueryViewSnapshot {
        items,
        groups,
        timeline_anchors,
        category_counts,
        search_keywords,
        has_more,
    })
}
