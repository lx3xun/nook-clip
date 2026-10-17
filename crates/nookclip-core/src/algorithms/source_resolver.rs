/// 应用激活记录（用于复制来源归因窗口）
#[derive(Clone, Debug, PartialEq)]
pub struct AppActivationRecord {
    pub bundle_id: Option<String>,
    pub name: Option<String>,
    /// 是否为 NookClip 自身窗口/面板
    pub is_self: bool,
    /// 激活发生的时间戳（秒）
    pub activated_at: f64,
}

/// 解析当前剪贴板变化的真实来源应用：
/// 修复「在应用 A 复制 → 轮询周期（如 0.35s）内切到应用 B，来源被误记为 B」的轮询竞态。
///
/// 规则：
/// 1. 若最新激活是 NookClip 自身且已稳定驻留 `>= poll_interval`：如实归因为 NookClip（面板内复制等）。
/// 2. 否则从末尾跳过 NookClip 自身激活，取最近的外部应用 `current`：
///    - 若 `current` 已驻留 `>= poll_interval`，归因为 `current`；
///    - 若 `current` 激活不足一个轮询周期（复制后快速切走），继续向前找切换前的外部应用 `prev`，有则归因 `prev`，否则回退 `current`。
/// 3. 若历史中仅有 NookClip 自身但尚未满足条件 1，返回最后一条自身记录（避免刚启动即呼出面板时丢失来源）。
pub fn resolve_source_app(
    history: &[AppActivationRecord],
    now_ts: f64,
    poll_interval: f64,
) -> Option<AppActivationRecord> {
    if history.is_empty() {
        return None;
    }

    if let Some(last) = history.last() {
        if last.is_self && (now_ts - last.activated_at) >= poll_interval {
            return Some(last.clone());
        }
    }

    let mut idx = history.len() as isize - 1;
    while idx >= 0 && history[idx as usize].is_self {
        idx -= 1;
    }

    if idx < 0 {
        return history.last().cloned();
    }

    let current = &history[idx as usize];
    if (now_ts - current.activated_at) >= poll_interval {
        return Some(current.clone());
    }

    let mut prev = idx - 1;
    while prev >= 0 && history[prev as usize].is_self {
        prev -= 1;
    }

    if prev >= 0 {
        Some(history[prev as usize].clone())
    } else {
        Some(current.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: f64 = 1_700_000_000.0;
    const POLL: f64 = 0.35;

    fn rec(bundle: &str, name: &str, is_self: bool, at: f64) -> AppActivationRecord {
        AppActivationRecord {
            bundle_id: Some(bundle.to_string()),
            name: Some(name.to_string()),
            is_self,
            activated_at: at,
        }
    }

    #[test]
    fn test_copy_then_quick_switch_attributes_to_previous_app() {
        let h = vec![
            rec("com.google.Chrome", "Google Chrome", false, T0),
            rec("com.orca", "Orca", false, T0 + 0.2),
        ];
        let src = resolve_source_app(&h, T0 + 0.3, POLL).unwrap();
        assert_eq!(src.bundle_id.as_deref(), Some("com.google.Chrome"));
    }

    #[test]
    fn test_stable_app_attributes_to_itself() {
        let h = vec![
            rec("com.google.Chrome", "Google Chrome", false, T0),
            rec("com.orca", "Orca", false, T0 + 5.0),
        ];
        let src = resolve_source_app(&h, T0 + 30.0, POLL).unwrap();
        assert_eq!(src.bundle_id.as_deref(), Some("com.orca"));
    }

    #[test]
    fn test_self_activation_skipped_when_transient() {
        let h = vec![
            rec("com.google.Chrome", "Google Chrome", false, T0),
            rec("nook.self", "NookClip", true, T0 + 0.1),
        ];
        let src = resolve_source_app(&h, T0 + 0.2, POLL).unwrap();
        assert_eq!(src.bundle_id.as_deref(), Some("com.google.Chrome"));
    }

    #[test]
    fn test_resident_self_attributes_to_nookclip() {
        let h = vec![
            rec("com.google.Chrome", "Google Chrome", false, T0),
            rec("com.lx3xun.nookclip", "NookClip", true, T0 + 5.0),
        ];
        let src = resolve_source_app(&h, T0 + 10.0, POLL).unwrap();
        assert_eq!(src.bundle_id.as_deref(), Some("com.lx3xun.nookclip"));
    }

    #[test]
    fn test_only_transient_self_activation_falls_back_to_self() {
        let h = vec![rec("com.lx3xun.nookclip", "NookClip", true, T0 + 0.1)];
        let src = resolve_source_app(&h, T0 + 0.2, POLL).unwrap();
        assert_eq!(src.bundle_id.as_deref(), Some("com.lx3xun.nookclip"));
    }
}
