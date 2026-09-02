//! UniFFI 桥接层（§8、§54、§80、§81）。
//!
//! 只暴露 Swift 友好的简单类型（Record / Enum / Object / i64 / String / Bool / Option），
//! 不暴露 `Arc<Mutex<T>>`、HashMap 等复杂 Rust 类型（§81）。
//! 命名保持稳定，作为 Swift ↔ Rust 的长期契约（§54）。

use std::sync::Arc;

use crate::cleanup::cleanup_manager::Retention as CoreRetention;
use crate::clipboard::model::{
    ClipboardItem as CoreClipboardItem, ItemType as CoreItemType, NewClipboardItem as CoreNewItem,
    Statistics as CoreStatistics,
};
use crate::error::AidoPasteError as CoreError;
use crate::storage::database::Database as CoreDatabase;
use uniffi::{Enum, Object, Record};

/// 剪贴板条目类型（§13）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Enum)]
pub enum ItemType {
    #[default]
    Text,
    Url,
    Image,
    File,
    Folder,
    RichText,
    Code,
    Other,
}

impl From<CoreItemType> for ItemType {
    fn from(value: CoreItemType) -> Self {
        match value {
            CoreItemType::Text => Self::Text,
            CoreItemType::Url => Self::Url,
            CoreItemType::Image => Self::Image,
            CoreItemType::File => Self::File,
            CoreItemType::Folder => Self::Folder,
            CoreItemType::RichText => Self::RichText,
            CoreItemType::Code => Self::Code,
            CoreItemType::Other => Self::Other,
        }
    }
}

impl From<ItemType> for CoreItemType {
    fn from(value: ItemType) -> Self {
        match value {
            ItemType::Text => Self::Text,
            ItemType::Url => Self::Url,
            ItemType::Image => Self::Image,
            ItemType::File => Self::File,
            ItemType::Folder => Self::Folder,
            ItemType::RichText => Self::RichText,
            ItemType::Code => Self::Code,
            ItemType::Other => Self::Other,
        }
    }
}

/// 历史保留时长（§32）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Enum)]
pub enum Retention {
    OneDay,
    SevenDays,
    ThirtyDays,
    NinetyDays,
    Never,
}

impl From<Retention> for CoreRetention {
    fn from(value: Retention) -> Self {
        match value {
            Retention::OneDay => Self::OneDay,
            Retention::SevenDays => Self::SevenDays,
            Retention::ThirtyDays => Self::ThirtyDays,
            Retention::NinetyDays => Self::NinetyDays,
            Retention::Never => Self::Never,
        }
    }
}

/// 已持久化的剪贴板条目（§13）。
#[derive(Debug, Clone, Record)]
pub struct ClipboardItem {
    pub id: i64,
    pub item_type: ItemType,
    pub created_at: i64,
    pub updated_at: i64,
    pub title: Option<String>,
    pub preview: Option<String>,
    pub text_content: Option<String>,
    pub url: Option<String>,
    pub file_path: Option<String>,
    pub image_path: Option<String>,
    pub thumbnail_path: Option<String>,
    pub source_app: Option<String>,
    pub source_app_name: Option<String>,
    pub content_size: i64,
    pub uti: Option<String>,
    pub content_hash: String,
    pub is_pinned: bool,
    pub metadata: Option<String>,
}

impl From<CoreClipboardItem> for ClipboardItem {
    fn from(item: CoreClipboardItem) -> Self {
        Self {
            id: item.id,
            item_type: ItemType::from(item.item_type),
            created_at: item.created_at,
            updated_at: item.updated_at,
            title: item.title,
            preview: item.preview,
            text_content: item.text_content,
            url: item.url,
            file_path: item.file_path,
            image_path: item.image_path,
            thumbnail_path: item.thumbnail_path,
            source_app: item.source_app,
            source_app_name: item.source_app_name,
            content_size: item.content_size,
            uti: item.uti,
            content_hash: item.content_hash,
            is_pinned: item.is_pinned,
            metadata: item.metadata,
        }
    }
}

/// 新条目输入（§16 方向：Swift → Rust）。
#[derive(Debug, Clone, Default, Record)]
pub struct NewClipboardItem {
    pub item_type: ItemType,
    pub text_content: Option<String>,
    pub url: Option<String>,
    pub file_path: Option<String>,
    /// 图片暂存文件路径（§16：Swift 落临时文件，Core 读取转存）。
    pub image_source_path: Option<String>,
    pub uti: Option<String>,
    pub source_app: Option<String>,
    pub source_app_name: Option<String>,
    pub title: Option<String>,
    pub metadata: Option<String>,
    /// 捕获时间（毫秒）；None 表示使用当前时间。
    pub created_at: Option<i64>,
}

fn to_core_new_item(item: NewClipboardItem) -> CoreNewItem {
    CoreNewItem {
        item_type: CoreItemType::from(item.item_type),
        text_content: item.text_content,
        url: item.url,
        file_path: item.file_path,
        image_source_path: item.image_source_path,
        uti: item.uti,
        source_app: item.source_app,
        source_app_name: item.source_app_name,
        title: item.title,
        metadata: item.metadata,
        created_at: item.created_at,
    }
}

/// 类型计数（统计用；避免向 Swift 暴露 HashMap，§81）。
#[derive(Debug, Clone, Record)]
pub struct TypeCount {
    pub item_type: ItemType,
    pub count: i64,
}

/// 统计信息（§54 get_statistics）。
#[derive(Debug, Clone, Record)]
pub struct Statistics {
    pub total_count: i64,
    pub pinned_count: i64,
    pub total_content_size: i64,
    pub by_type: Vec<TypeCount>,
}

impl From<CoreStatistics> for Statistics {
    fn from(stats: CoreStatistics) -> Self {
        Self {
            total_count: stats.total_count,
            pinned_count: stats.pinned_count,
            total_content_size: stats.total_content_size,
            by_type: stats
                .by_type
                .into_iter()
                .map(|(item_type, count)| TypeCount {
                    item_type: ItemType::from(item_type),
                    count,
                })
                .collect(),
        }
    }
}

/// 核心错误（§82）。UniFFI 会把它映射为 Swift 的 Error 枚举。
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum AidoPasteError {
    #[error("database error: {message}")]
    Database { message: String },

    #[error("storage error: {message}")]
    Storage { message: String },

    #[error("invalid input: {message}")]
    InvalidInput { message: String },

    #[error("item not found: id={id}")]
    NotFound { id: i64 },

    #[error("permission denied: {message}")]
    PermissionDenied { message: String },

    #[error("file system error: {message}")]
    FileSystem { message: String },

    #[error("migration to v{target} failed: {message}")]
    Migration { target: u32, message: String },
}

impl From<CoreError> for AidoPasteError {
    fn from(error: CoreError) -> Self {
        match error {
            CoreError::Database(e) => Self::Database {
                message: e.to_string(),
            },
            CoreError::Storage(message) => Self::Storage { message },
            CoreError::InvalidInput(message) => Self::InvalidInput { message },
            CoreError::NotFound(id) => Self::NotFound { id },
            CoreError::PermissionDenied(message) => Self::PermissionDenied { message },
            CoreError::FileSystem(e) => Self::FileSystem {
                message: e.to_string(),
            },
            CoreError::Migration { target, message } => Self::Migration { target, message },
        }
    }
}

/// 分页参数换算：负数一律报 InvalidInput，不静默截断（§53）。
fn page_range(limit: i64, offset: i64) -> Result<(usize, usize), AidoPasteError> {
    let limit = usize::try_from(limit).map_err(|_| AidoPasteError::InvalidInput {
        message: format!("limit out of range: {limit}"),
    })?;
    let offset = usize::try_from(offset).map_err(|_| AidoPasteError::InvalidInput {
        message: format!("offset out of range: {offset}"),
    })?;
    Ok((limit, offset))
}

/// 数据库入口对象（§54）。Swift 启动时创建一个实例并长期持有。
#[derive(Object)]
pub struct AidoPasteDatabase {
    db: CoreDatabase,
}

#[uniffi::export]
impl AidoPasteDatabase {
    /// 打开（或创建）指定路径的数据库。
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, AidoPasteError> {
        Ok(Arc::new(Self {
            db: CoreDatabase::open(path)?,
        }))
    }

    /// 内存数据库，供 Swift 单元测试使用。
    #[uniffi::constructor]
    pub fn open_in_memory() -> Result<Arc<Self>, AidoPasteError> {
        Ok(Arc::new(Self {
            db: CoreDatabase::open_in_memory()?,
        }))
    }

    /// 当前 schema 版本。
    pub fn schema_version(&self) -> Result<u32, AidoPasteError> {
        Ok(self.db.schema_version()?)
    }

    /// 创建条目（自动去重，§17）。
    pub fn create_item(&self, new_item: NewClipboardItem) -> Result<ClipboardItem, AidoPasteError> {
        Ok(self.db.create_item(to_core_new_item(new_item))?.into())
    }

    /// 读取单条。
    pub fn get_item(&self, id: i64) -> Result<ClipboardItem, AidoPasteError> {
        Ok(self.db.get_item(id)?.into())
    }

    /// 分页列出：置顶在前，其余按最近使用排序。
    pub fn get_items(
        &self,
        filter: Option<ItemType>,
        limit: i64,
        offset: i64,
    ) -> Result<Vec<ClipboardItem>, AidoPasteError> {
        let (limit, offset) = page_range(limit, offset)?;
        Ok(self
            .db
            .get_items(filter.map(CoreItemType::from), limit, offset)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// 置顶条目。
    pub fn get_pinned_items(
        &self,
        limit: i64,
        offset: i64,
    ) -> Result<Vec<ClipboardItem>, AidoPasteError> {
        let (limit, offset) = page_range(limit, offset)?;
        Ok(self
            .db
            .get_pinned_items(limit, offset)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// 全文搜索（§29、§30）。
    pub fn search_items(
        &self,
        query: String,
        filter: Option<ItemType>,
        limit: i64,
        offset: i64,
    ) -> Result<Vec<ClipboardItem>, AidoPasteError> {
        let (limit, offset) = page_range(limit, offset)?;
        Ok(self
            .db
            .search_items(&query, filter.map(CoreItemType::from), limit, offset)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// 删除单条。
    pub fn delete_item(&self, id: i64) -> Result<(), AidoPasteError> {
        Ok(self.db.delete_item(id)?)
    }

    /// 批量删除，返回实际删除数。
    pub fn delete_items(&self, ids: Vec<i64>) -> Result<i64, AidoPasteError> {
        Ok(self.db.delete_items(&ids)? as i64)
    }

    /// Pin（§31）。
    pub fn pin_item(&self, id: i64) -> Result<(), AidoPasteError> {
        Ok(self.db.pin_item(id)?)
    }

    /// Unpin（§31）。
    pub fn unpin_item(&self, id: i64) -> Result<(), AidoPasteError> {
        Ok(self.db.unpin_item(id)?)
    }

    /// 执行一次过期清理（§32）。
    pub fn cleanup_expired(&self, retention: Retention) -> Result<i64, AidoPasteError> {
        let deleted = self
            .db
            .cleanup_expired(retention.into(), crate::clipboard::model::now_ms())?;
        Ok(deleted as i64)
    }

    /// 历史条数上限（§50），返回清理条数。
    pub fn enforce_history_limit(&self, max_count: i64) -> Result<i64, AidoPasteError> {
        let max_count = usize::try_from(max_count).map_err(|_| AidoPasteError::InvalidInput {
            message: format!("max_count out of range: {max_count}"),
        })?;
        Ok(self.db.enforce_history_limit(max_count)? as i64)
    }

    /// 统计信息。
    pub fn get_statistics(&self) -> Result<Statistics, AidoPasteError> {
        Ok(self.db.get_statistics()?.into())
    }

    /// 清扫孤儿图片文件（§48），返回删除数。
    pub fn sweep_orphan_artifacts(&self) -> Result<i64, AidoPasteError> {
        Ok(self.db.sweep_orphan_artifacts()? as i64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_surface_roundtrip_search_pin_statistics() {
        let db = AidoPasteDatabase::open_in_memory().unwrap();
        assert_eq!(db.schema_version().unwrap(), 1);

        let created = db
            .create_item(NewClipboardItem {
                item_type: ItemType::Text,
                text_content: Some("UniFFI 边界测试条目".into()),
                source_app: Some("com.apple.Safari".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(created.item_type, ItemType::Text);
        assert_eq!(created.source_app.as_deref(), Some("com.apple.Safari"));

        let found = db.search_items("边界测试".into(), None, 50, 0).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].id, created.id);

        db.pin_item(created.id).unwrap();
        let pinned = db.get_pinned_items(50, 0).unwrap();
        assert_eq!(pinned.len(), 1);

        let stats = db.get_statistics().unwrap();
        assert_eq!(stats.total_count, 1);
        assert_eq!(stats.pinned_count, 1);
        assert_eq!(stats.by_type.len(), 1);
        assert_eq!(stats.by_type[0].item_type, ItemType::Text);

        assert_eq!(db.delete_items(vec![created.id]).unwrap(), 1);
        assert_eq!(db.get_statistics().unwrap().total_count, 0);
    }

    #[test]
    fn ffi_error_mapping_not_found() {
        let db = AidoPasteDatabase::open_in_memory().unwrap();
        match db.get_item(987654) {
            Err(AidoPasteError::NotFound { id }) => assert_eq!(id, 987654),
            other => panic!("expected NotFound, got {other:?}"),
        }
    }

    #[test]
    fn ffi_page_range_rejects_negative() {
        let db = AidoPasteDatabase::open_in_memory().unwrap();
        let error = db.get_items(None, -1, 0).unwrap_err();
        assert!(matches!(error, AidoPasteError::InvalidInput { .. }));
    }
}
