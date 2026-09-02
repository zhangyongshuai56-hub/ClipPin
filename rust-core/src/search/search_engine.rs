//! 搜索实现（§29、§30）。
//!
//! ≥3 字符查询走 FTS5 trigram（中英文子串匹配），
//! 更短查询退回 LIKE（trigram 最少需要 3 个字符）。
//! 用户输入永远以引号短语形式传入 MATCH，操作符不会注入。

use rusqlite::types::Value;
use rusqlite::{Connection, params_from_iter};

use crate::clipboard::model::{ClipboardItem, ItemType};
use crate::error::Result;
use crate::storage::database::{list_items, row_to_item};

/// 搜索入口。`query` 为空时等价于按最近使用列出。
pub(crate) fn search(
    conn: &Connection,
    raw_query: &str,
    filter: Option<ItemType>,
    limit: usize,
    offset: usize,
) -> Result<Vec<ClipboardItem>> {
    let query = raw_query.trim();
    if query.is_empty() {
        return list_items(conn, filter, limit, offset);
    }
    if query.chars().count() >= 3 {
        search_fts(conn, query, filter, limit, offset)
    } else {
        search_like(conn, query, filter, limit, offset)
    }
}

/// FTS5 trigram 全文搜索。短语引号转义后整体作为一个 phrase，子串语义。
fn search_fts(
    conn: &Connection,
    query: &str,
    filter: Option<ItemType>,
    limit: usize,
    offset: usize,
) -> Result<Vec<ClipboardItem>> {
    let match_query = format!("\"{}\"", query.replace('"', "\"\""));
    let mut sql = String::from(
        "SELECT clipboard_items.* FROM clipboard_items
         JOIN clipboard_fts ON clipboard_fts.rowid = clipboard_items.id
         WHERE clipboard_fts MATCH ?1",
    );
    let mut values: Vec<Value> = vec![Value::Text(match_query)];
    if let Some(item_type) = filter {
        sql.push_str(" AND clipboard_items.type = ?2");
        values.push(Value::Text(item_type.as_str().into()));
    }
    let limit_index = values.len() + 1;
    let offset_index = values.len() + 2;
    // bm25 越小相关性越高
    sql.push_str(&format!(
        " ORDER BY bm25(clipboard_fts), clipboard_items.updated_at DESC, clipboard_items.id DESC
         LIMIT ?{limit_index} OFFSET ?{offset_index}"
    ));
    values.push(Value::Integer(limit as i64));
    values.push(Value::Integer(offset as i64));

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(values), row_to_item)?;
    rows.collect::<std::result::Result<Vec<_>, _>>()
        .map_err(Into::into)
}

/// 短查询（1–2 字符）的 LIKE 回退，覆盖 title / 正文 / URL / 文件路径 / 来源应用。
fn search_like(
    conn: &Connection,
    query: &str,
    filter: Option<ItemType>,
    limit: usize,
    offset: usize,
) -> Result<Vec<ClipboardItem>> {
    let escaped = query
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_");
    let pattern = format!("%{escaped}%");
    let mut sql = String::from(
        "SELECT * FROM clipboard_items WHERE (
            COALESCE(title, '') LIKE ?1 ESCAPE '\\'
            OR COALESCE(text_content, '') LIKE ?1 ESCAPE '\\'
            OR COALESCE(url, '') LIKE ?1 ESCAPE '\\'
            OR COALESCE(file_path, '') LIKE ?1 ESCAPE '\\'
            OR COALESCE(source_app_name, '') LIKE ?1 ESCAPE '\\'
        )",
    );
    let mut values: Vec<Value> = vec![Value::Text(pattern)];
    if let Some(item_type) = filter {
        sql.push_str(" AND type = ?2");
        values.push(Value::Text(item_type.as_str().into()));
    }
    let limit_index = values.len() + 1;
    let offset_index = values.len() + 2;
    sql.push_str(&format!(
        " ORDER BY updated_at DESC, id DESC LIMIT ?{limit_index} OFFSET ?{offset_index}"
    ));
    values.push(Value::Integer(limit as i64));
    values.push(Value::Integer(offset as i64));

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(values), row_to_item)?;
    rows.collect::<std::result::Result<Vec<_>, _>>()
        .map_err(Into::into)
}
