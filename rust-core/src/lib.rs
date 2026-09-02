//! AidoPaste Rust Core。
//!
//! 职责（§5）：剪贴板数据模型、去重、内容分类、SQLite 存储、搜索、Pin、
//! 自动清理、哈希与数据处理。不包含任何 macOS UI 依赖，保持跨平台可复用（§9）。
//!
//! Swift 通过 UniFFI 调用本 crate（Phase 3 接入），Swift 侧不直接操作 SQLite（§12）。

#![forbid(unsafe_code)]

pub mod cleanup;
pub mod clipboard;
pub mod error;
pub mod search;
pub mod storage;

pub use cleanup::cleanup_manager::{CleanupManager, Retention};
pub use clipboard::model::{ClipboardItem, ItemType, NewClipboardItem, Statistics};
pub use error::{AidoPasteError, Result};
pub use storage::database::Database;
