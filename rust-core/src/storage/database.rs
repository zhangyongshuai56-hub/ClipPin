//! SQLite 存储与数据库管理（§12、§14、§46、§47、§48）。
//!
//! 所有访问经由单一连接串行化；WAL + busy_timeout 保证崩溃恢复与并发写入安全。
//! schema 通过 `PRAGMA user_version` 迁移框架演进，只追加迁移、不改历史（§47）。

use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use rusqlite::types::Value;
use rusqlite::{Connection, OptionalExtension, Row, params, params_from_iter};

use crate::cleanup::cleanup_manager::Retention;
use crate::clipboard::classifier;
use crate::clipboard::dedup;
use crate::clipboard::model::{ClipboardItem, ItemType, NewClipboardItem, Statistics, now_ms};
use crate::error::{AidoPasteError, Result};

/// 单次查询返回的最大条数，防御一次性加载过多数据（§57）。
const MAX_PAGE_SIZE: usize = 1000;

/// 当前 schema 版本。
const SCHEMA_VERSION: u32 = 1;

/// 迁移 SQL 列表，下标 `i` 对应目标版本 `i + 1`。
/// 只允许追加新版本，禁止修改历史条目（§47）。
const MIGRATIONS: &[&str] = &[
    // v1：初始 schema（§14）。
    // FTS5 采用 external-content + trigram：中英文都能子串匹配（§29）。
    "
    CREATE TABLE clipboard_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        title TEXT,
        preview TEXT,
        text_content TEXT,
        url TEXT,
        file_path TEXT,
        image_path TEXT,
        thumbnail_path TEXT,
        source_app TEXT,
        source_app_name TEXT,
        content_size INTEGER NOT NULL DEFAULT 0,
        uti TEXT,
        content_hash TEXT NOT NULL,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        metadata TEXT
    );

    CREATE INDEX idx_clipboard_items_created_at ON clipboard_items(created_at);
    CREATE INDEX idx_clipboard_items_updated_at ON clipboard_items(updated_at);
    CREATE INDEX idx_clipboard_items_type ON clipboard_items(type);
    CREATE INDEX idx_clipboard_items_is_pinned ON clipboard_items(is_pinned);
    CREATE INDEX idx_clipboard_items_content_hash ON clipboard_items(content_hash);

    CREATE VIRTUAL TABLE clipboard_fts USING fts5(
        title, text_content, url, file_path, source_app_name,
        content='clipboard_items', content_rowid='id',
        tokenize='trigram case_sensitive 0'
    );

    CREATE TRIGGER clipboard_items_fts_ai AFTER INSERT ON clipboard_items BEGIN
        INSERT INTO clipboard_fts(rowid, title, text_content, url, file_path, source_app_name)
        VALUES (new.id, new.title, new.text_content, new.url, new.file_path, new.source_app_name);
    END;

    CREATE TRIGGER clipboard_items_fts_ad AFTER DELETE ON clipboard_items BEGIN
        INSERT INTO clipboard_fts(clipboard_fts, rowid, title, text_content, url, file_path, source_app_name)
        VALUES ('delete', old.id, old.title, old.text_content, old.url, old.file_path, old.source_app_name);
    END;

    CREATE TRIGGER clipboard_items_fts_au AFTER UPDATE ON clipboard_items BEGIN
        INSERT INTO clipboard_fts(clipboard_fts, rowid, title, text_content, url, file_path, source_app_name)
        VALUES ('delete', old.id, old.title, old.text_content, old.url, old.file_path, old.source_app_name);
        INSERT INTO clipboard_fts(rowid, title, text_content, url, file_path, source_app_name)
        VALUES (new.id, new.title, new.text_content, new.url, new.file_path, new.source_app_name);
    END;
    ",
];

/// SQLite 数据库入口。`Clone` 共享同一连接（Arc），可安全跨线程使用。
#[derive(Clone)]
pub struct Database {
    conn: Arc<Mutex<Connection>>,
}

impl Database {
    /// 打开（或创建）数据库文件。
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path)?;
        Self::initialize(conn)
    }

    /// 内存数据库，供测试与临时场景。
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        Self::initialize(conn)
    }

    fn initialize(mut conn: Connection) -> Result<Self> {
        let journal_mode: String =
            conn.query_row("PRAGMA journal_mode=WAL", [], |row| row.get(0))?;
        log::debug!(target: "aidopaste", "journal_mode={journal_mode}");
        // WAL + NORMAL：崩溃不丢已提交事务，写入开销低（§48）
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.busy_timeout(std::time::Duration::from_millis(5_000))?;
        run_migrations(&mut conn)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    fn lock_conn(&self) -> Result<MutexGuard<'_, Connection>> {
        self.conn
            .lock()
            .map_err(|_| AidoPasteError::Storage("database connection lock poisoned".into()))
    }

    /// 当前 schema 版本。
    pub fn schema_version(&self) -> Result<u32> {
        let conn = self.lock_conn()?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
        Ok(version as u32)
    }

    /// 创建条目（§54 create_item）。相同 content_hash 不重复入库（§17）：
    /// 仅刷新 updated_at 并更新来源，保留 created_at 与 Pin 状态。
    pub fn create_item(&self, new_item: NewClipboardItem) -> Result<ClipboardItem> {
        new_item.validate()?;
        let (item_type, metadata) = refine_type_and_metadata(&new_item);
        let content_hash = dedup::hash_for_new_item(&new_item)?;
        // 标题 / 预览必须按细分后的类型推导（例如文本形式的 URL 要取域名做标题）
        let mut effective = new_item.clone();
        effective.item_type = item_type;
        // 文本载荷被识别为 URL 时，把内容规范化到 url 字段（text_content 保留，供搜索）
        if item_type == ItemType::Url && effective.url.is_none() {
            effective.url = effective
                .text_content
                .as_deref()
                .map(str::trim)
                .map(str::to_string);
        }
        let content_size = effective.content_size();
        let now = now_ms();
        let created_at = new_item.created_at.unwrap_or(now);
        let title = new_item.title.clone().or_else(|| effective.derive_title());
        let preview = effective.derive_preview();

        let mut conn = self.lock_conn()?;
        let tx = conn.transaction()?;
        let existing: Option<i64> = tx
            .query_row(
                "SELECT id FROM clipboard_items WHERE content_hash = ?1",
                params![content_hash],
                |row| row.get(0),
            )
            .optional()?;
        let id = match existing {
            Some(id) => {
                tx.execute(
                    "UPDATE clipboard_items
                     SET updated_at = ?2,
                         source_app = COALESCE(?3, source_app),
                         source_app_name = COALESCE(?4, source_app_name)
                     WHERE id = ?1",
                    params![id, now, new_item.source_app, new_item.source_app_name,],
                )?;
                id
            }
            None => {
                tx.execute(
                    "INSERT INTO clipboard_items
                        (type, created_at, updated_at, title, preview, text_content, url,
                         file_path, source_app, source_app_name, content_size, uti,
                         content_hash, is_pinned, metadata)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, 0, ?14)",
                    params![
                        item_type.as_str(),
                        created_at,
                        now,
                        title,
                        preview,
                        new_item.text_content,
                        new_item.url,
                        new_item.file_path,
                        new_item.source_app,
                        new_item.source_app_name,
                        content_size,
                        new_item.uti,
                        content_hash,
                        metadata,
                    ],
                )?;
                tx.last_insert_rowid()
            }
        };
        tx.commit()?;
        // §84：日志只允许 type / size / id 等元信息，禁止内容原文
        log::info!(target: "aidopaste", "item captured id={id} type={} size={content_size}", item_type.as_str());
        drop(conn);
        self.get_item(id)
    }

    /// 读取单条。
    pub fn get_item(&self, id: i64) -> Result<ClipboardItem> {
        let conn = self.lock_conn()?;
        conn.query_row(
            "SELECT * FROM clipboard_items WHERE id = ?1",
            params![id],
            row_to_item,
        )
        .optional()?
        .ok_or(AidoPasteError::NotFound(id))
    }

    /// 分页列出（§58）：置顶在前，其余按最近使用排序。
    /// `limit` 超过 [`MAX_PAGE_SIZE`] 时自动截断。
    pub fn get_items(
        &self,
        filter: Option<ItemType>,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<ClipboardItem>> {
        let conn = self.lock_conn()?;
        list_items(&conn, filter, limit.min(MAX_PAGE_SIZE), offset)
    }

    /// 置顶条目（§31），按最近使用排序。
    pub fn get_pinned_items(&self, limit: usize, offset: usize) -> Result<Vec<ClipboardItem>> {
        let conn = self.lock_conn()?;
        let mut stmt = conn.prepare(
            "SELECT * FROM clipboard_items WHERE is_pinned = 1
             ORDER BY updated_at DESC, id DESC LIMIT ?1 OFFSET ?2",
        )?;
        let rows = stmt.query_map(
            params![limit.min(MAX_PAGE_SIZE) as i64, offset as i64],
            row_to_item,
        )?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(AidoPasteError::from)
    }

    /// 全文搜索（§29、§30）。空查询等价于 [`Database::get_items`]。
    pub fn search_items(
        &self,
        query: &str,
        filter: Option<ItemType>,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<ClipboardItem>> {
        let conn = self.lock_conn()?;
        crate::search::search_engine::search(&conn, query, filter, limit.min(MAX_PAGE_SIZE), offset)
    }

    /// 删除单条。
    pub fn delete_item(&self, id: i64) -> Result<()> {
        let conn = self.lock_conn()?;
        let affected = conn.execute("DELETE FROM clipboard_items WHERE id = ?1", params![id])?;
        if affected == 0 {
            return Err(AidoPasteError::NotFound(id));
        }
        log::info!(target: "aidopaste", "item deleted id={id}");
        Ok(())
    }

    /// 批量删除，返回实际删除数。分批执行以规避 SQLite 参数上限。
    pub fn delete_items(&self, ids: &[i64]) -> Result<usize> {
        let mut conn = self.lock_conn()?;
        let tx = conn.transaction()?;
        let mut deleted = 0;
        for chunk in ids.chunks(500) {
            let placeholders = vec!["?"; chunk.len()].join(", ");
            let values: Vec<Value> = chunk.iter().map(|id| Value::Integer(*id)).collect();
            deleted += tx.execute(
                &format!("DELETE FROM clipboard_items WHERE id IN ({placeholders})"),
                params_from_iter(values),
            )?;
        }
        tx.commit()?;
        if deleted > 0 {
            log::info!(target: "aidopaste", "items deleted count={deleted}");
        }
        Ok(deleted)
    }

    /// Pin / Unpin（§31、§54）。
    pub fn pin_item(&self, id: i64) -> Result<()> {
        self.set_pinned(id, true)
    }

    pub fn unpin_item(&self, id: i64) -> Result<()> {
        self.set_pinned(id, false)
    }

    fn set_pinned(&self, id: i64, pinned: bool) -> Result<()> {
        let conn = self.lock_conn()?;
        let affected = conn.execute(
            "UPDATE clipboard_items SET is_pinned = ?2 WHERE id = ?1",
            params![id, pinned],
        )?;
        if affected == 0 {
            return Err(AidoPasteError::NotFound(id));
        }
        Ok(())
    }

    /// 删除过期未 Pin 条目（§32）。`now_ms` 由调用方注入，便于测试与调度。
    pub fn cleanup_expired(&self, retention: Retention, now_ms: i64) -> Result<usize> {
        let Some(days) = retention.days() else {
            return Ok(0);
        };
        let cutoff = now_ms - (days as i64) * 86_400_000;
        let conn = self.lock_conn()?;
        let deleted = conn.execute(
            "DELETE FROM clipboard_items WHERE is_pinned = 0 AND updated_at < ?1",
            params![cutoff],
        )?;
        if deleted > 0 {
            log::info!(target: "aidopaste", "cleanup deleted count={deleted}");
        }
        Ok(deleted)
    }

    /// 历史条数上限（§50）：超出部分从最旧的非 Pin 条目删起。
    pub fn enforce_history_limit(&self, max_count: usize) -> Result<usize> {
        let conn = self.lock_conn()?;
        let deleted = conn.execute(
            "DELETE FROM clipboard_items
             WHERE is_pinned = 0 AND id IN (
                 SELECT id FROM clipboard_items WHERE is_pinned = 0
                 ORDER BY updated_at DESC, id DESC
                 LIMIT -1 OFFSET ?1
             )",
            params![max_count as i64],
        )?;
        if deleted > 0 {
            log::info!(target: "aidopaste", "history limit trimmed count={deleted}");
        }
        Ok(deleted)
    }

    /// 统计信息（§54 get_statistics）。
    pub fn get_statistics(&self) -> Result<Statistics> {
        let conn = self.lock_conn()?;
        let (total_count, total_content_size, pinned_count) = conn.query_row(
            "SELECT COUNT(*), COALESCE(SUM(content_size), 0), COALESCE(SUM(is_pinned), 0)
             FROM clipboard_items",
            [],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )?;
        let mut stmt = conn.prepare("SELECT type, COUNT(*) FROM clipboard_items GROUP BY type")?;
        let by_type = stmt
            .query_map([], |row| {
                Ok((
                    ItemType::from_db(&row.get::<_, String>(0)?),
                    row.get::<_, i64>(1)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(Statistics {
            total_count,
            pinned_count,
            total_content_size,
            by_type,
        })
    }
}

/// Text 类型走规则分类器细分（§19）；检测到代码语言时写入 `metadata.language`。
fn refine_type_and_metadata(item: &NewClipboardItem) -> (ItemType, Option<String>) {
    if item.item_type != ItemType::Text {
        return (item.item_type, item.metadata.clone());
    }
    let Some(text) = item.text_content.as_deref() else {
        return (ItemType::Text, item.metadata.clone());
    };
    let classified = classifier::classify_text(text);
    if classified == ItemType::Text {
        return (ItemType::Text, item.metadata.clone());
    }
    let metadata = classifier::detect_code_language(text)
        .map(|lang| with_language(item.metadata.as_deref(), lang));
    (classified, metadata)
}

/// 在 metadata JSON 中写入（或覆盖）language 字段；原 metadata 非法时重建对象。
fn with_language(metadata: Option<&str>, lang: &str) -> String {
    use serde_json::Value;
    let mut value = metadata
        .and_then(|m| serde_json::from_str::<Value>(m).ok())
        .unwrap_or_else(|| Value::Object(serde_json::Map::new()));
    if let Value::Object(ref mut map) = value {
        map.insert("language".into(), Value::String(lang.into()));
    }
    value.to_string()
}

/// 按类型分页列出：置顶在前，其余按最近使用排序。
pub(crate) fn list_items(
    conn: &Connection,
    filter: Option<ItemType>,
    limit: usize,
    offset: usize,
) -> Result<Vec<ClipboardItem>> {
    let mut sql = String::from("SELECT * FROM clipboard_items");
    let mut values: Vec<Value> = Vec::new();
    if let Some(item_type) = filter {
        sql.push_str(" WHERE type = ?");
        values.push(Value::Text(item_type.as_str().into()));
    }
    let limit_index = values.len() + 1;
    let offset_index = values.len() + 2;
    sql.push_str(&format!(
        " ORDER BY is_pinned DESC, updated_at DESC, id DESC LIMIT ?{limit_index} OFFSET ?{offset_index}"
    ));
    values.push(Value::Integer(limit as i64));
    values.push(Value::Integer(offset as i64));

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(values), row_to_item)?;
    rows.collect::<std::result::Result<Vec<_>, _>>()
        .map_err(AidoPasteError::from)
}

pub(crate) fn row_to_item(row: &Row) -> rusqlite::Result<ClipboardItem> {
    let type_text: String = row.get("type")?;
    Ok(ClipboardItem {
        id: row.get("id")?,
        item_type: ItemType::from_db(&type_text),
        created_at: row.get("created_at")?,
        updated_at: row.get("updated_at")?,
        title: row.get("title")?,
        preview: row.get("preview")?,
        text_content: row.get("text_content")?,
        url: row.get("url")?,
        file_path: row.get("file_path")?,
        image_path: row.get("image_path")?,
        thumbnail_path: row.get("thumbnail_path")?,
        source_app: row.get("source_app")?,
        source_app_name: row.get("source_app_name")?,
        content_size: row.get("content_size")?,
        uti: row.get("uti")?,
        content_hash: row.get("content_hash")?,
        is_pinned: row.get::<_, i64>("is_pinned")? != 0,
        metadata: row.get("metadata")?,
    })
}

fn run_migrations(conn: &mut Connection) -> Result<()> {
    let current: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    for (index, sql) in MIGRATIONS.iter().enumerate() {
        let target = (index + 1) as u32;
        if current >= target as i64 {
            continue;
        }
        // 每个迁移与 user_version 写入同事务，失败整体回滚（§46、§47）
        let tx = conn.transaction().map_err(|e| AidoPasteError::Migration {
            target,
            message: e.to_string(),
        })?;
        tx.execute_batch(sql)
            .map_err(|e| AidoPasteError::Migration {
                target,
                message: e.to_string(),
            })?;
        tx.pragma_update(None, "user_version", target as i64)
            .map_err(|e| AidoPasteError::Migration {
                target,
                message: e.to_string(),
            })?;
        tx.commit().map_err(|e| AidoPasteError::Migration {
            target,
            message: e.to_string(),
        })?;
        log::info!(target: "aidopaste", "database migrated to v{target}");
    }
    debug_assert_eq!(MIGRATIONS.len() as u32, SCHEMA_VERSION);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_database_reaches_latest_version() {
        let db = Database::open_in_memory().unwrap();
        assert_eq!(db.schema_version().unwrap(), SCHEMA_VERSION);
    }

    #[test]
    fn with_language_merges_into_existing_metadata() {
        assert_eq!(
            with_language(Some(r#"{"a":1}"#), "swift"),
            r#"{"a":1,"language":"swift"}"#
        );
        assert_eq!(with_language(None, "json"), r#"{"language":"json"}"#);
        // 原 metadata 不是合法 JSON 时重建而不是报错
        assert_eq!(
            with_language(Some("not json"), "sql"),
            r#"{"language":"sql"}"#
        );
    }
}
