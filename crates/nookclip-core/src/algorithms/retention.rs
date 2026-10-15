use crate::model::RetentionConfig;

pub fn should_prune(config: &RetentionConfig) -> bool {
    config.max_age_days.map(|d| d > 0).unwrap_or(false)
        || config.max_item_count.map(|c| c > 0).unwrap_or(false)
}
