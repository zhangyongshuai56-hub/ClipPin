//! 自动清理策略（§32）与历史条数上限（§50）。
//! Phase 7/8 起此处将同步清理对应图片、缩略图与缓存文件。

use std::sync::Arc;

use crate::clipboard::model::now_ms;
use crate::error::Result;
use crate::storage::database::Database;

/// 历史保留时长（§32）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Retention {
    OneDay,
    SevenDays,
    ThirtyDays,
    NinetyDays,
    Never,
}

impl Retention {
    /// 对应保留天数；[`Retention::Never`] 为 `None`。
    pub fn days(self) -> Option<u64> {
        match self {
            Retention::OneDay => Some(1),
            Retention::SevenDays => Some(7),
            Retention::ThirtyDays => Some(30),
            Retention::NinetyDays => Some(90),
            Retention::Never => None,
        }
    }
}

/// 一次清理的结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CleanupReport {
    pub deleted_items: usize,
}

/// 定期清理入口。Phase 9 接入后台调度，UI / 设置只与它交互。
pub struct CleanupManager {
    db: Arc<Database>,
}

impl CleanupManager {
    pub fn new(db: Arc<Database>) -> Self {
        Self { db }
    }

    /// 执行一次过期清理。Pin 条目永不清理（§32）。
    pub fn run(&self, retention: Retention) -> Result<CleanupReport> {
        let deleted_items = self.db.cleanup_expired(retention, now_ms())?;
        Ok(CleanupReport { deleted_items })
    }

    /// 历史条数上限（§50）。Pin 不计入限制。
    pub fn enforce_history_limit(&self, max_count: usize) -> Result<usize> {
        self.db.enforce_history_limit(max_count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retention_days_mapping() {
        assert_eq!(Retention::OneDay.days(), Some(1));
        assert_eq!(Retention::SevenDays.days(), Some(7));
        assert_eq!(Retention::ThirtyDays.days(), Some(30));
        assert_eq!(Retention::NinetyDays.days(), Some(90));
        assert_eq!(Retention::Never.days(), None);
    }
}
