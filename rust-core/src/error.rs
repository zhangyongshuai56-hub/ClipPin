//! 统一错误模型（§82）。Phase 3 通过 UniFFI 暴露给 Swift，映射为 UserFacingError。

/// AidoPaste 核心错误。
#[derive(Debug, thiserror::Error)]
pub enum AidoPasteError {
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("storage error: {0}")]
    Storage(String),

    #[error("invalid input: {0}")]
    InvalidInput(String),

    #[error("item not found: id={0}")]
    NotFound(i64),

    #[error("permission denied: {0}")]
    PermissionDenied(String),

    #[error("file system error: {0}")]
    FileSystem(#[from] std::io::Error),

    #[error("migration to v{target} failed: {message}")]
    Migration { target: u32, message: String },
}

/// 核心统一 Result 别名。
pub type Result<T> = std::result::Result<T, AidoPasteError>;
