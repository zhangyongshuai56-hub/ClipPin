//! 剪贴板数据模型（§13）与派生字段（标题 / 预览）计算。

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::{AidoPasteError, Result};

/// 标题最大字符数。
const MAX_TITLE_CHARS: usize = 80;
/// 预览最大字符数。
const MAX_PREVIEW_CHARS: usize = 280;

/// 当前 Unix 时间（毫秒）。系统时钟早于 epoch 时回退为 0，不 panic。
pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 剪贴板条目类型（§19 第一阶段为规则识别）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
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

impl ItemType {
    /// 全部类型，供遍历（统计等）。
    pub const ALL: [ItemType; 8] = [
        ItemType::Text,
        ItemType::Url,
        ItemType::Image,
        ItemType::File,
        ItemType::Folder,
        ItemType::RichText,
        ItemType::Code,
        ItemType::Other,
    ];

    /// 数据库存储标识。
    pub fn as_str(self) -> &'static str {
        match self {
            ItemType::Text => "text",
            ItemType::Url => "url",
            ItemType::Image => "image",
            ItemType::File => "file",
            ItemType::Folder => "folder",
            ItemType::RichText => "rich_text",
            ItemType::Code => "code",
            ItemType::Other => "other",
        }
    }

    /// 从数据库读取。未知标识（未来版本新增类型）回退为 Other，保证向前兼容。
    pub fn from_db(value: &str) -> Self {
        match value {
            "text" => ItemType::Text,
            "url" => ItemType::Url,
            "image" => ItemType::Image,
            "file" => ItemType::File,
            "folder" => ItemType::Folder,
            "rich_text" => ItemType::RichText,
            "code" => ItemType::Code,
            _ => ItemType::Other,
        }
    }
}

/// 新建条目的输入。由 Swift 侧从 NSPasteboard payload 构造（Phase 4），
/// id、哈希、时间戳、派生字段与 Pin 状态全部由 Core 计算，调用方不可注入。
#[derive(Debug, Clone, Default)]
pub struct NewClipboardItem {
    pub item_type: ItemType,
    pub text_content: Option<String>,
    pub url: Option<String>,
    pub file_path: Option<String>,
    /// 图片暂存文件路径（§16：Swift 落临时文件，Core 读取并转存，避免大块二进制跨 FFI 复制）。
    /// Core 读取后按内容哈希转存，临时文件由 Swift 侧清理。
    pub image_source_path: Option<String>,
    pub uti: Option<String>,
    pub source_app: Option<String>,
    pub source_app_name: Option<String>,
    /// 调用方已知标题（如文件名）时可提供；缺省由内容推导。
    pub title: Option<String>,
    /// 元数据 JSON 文本。分类器检测到代码语言时会补充 `language` 字段。
    pub metadata: Option<String>,
    /// 捕获时间（毫秒）。None 表示使用当前时间；主要用于测试与回放。
    pub created_at: Option<i64>,
}

/// 已持久化的剪贴板条目。
#[derive(Debug, Clone)]
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

impl NewClipboardItem {
    /// 规范化内容：哈希与大小都基于它（text → url → file_path 优先）。
    pub fn content(&self) -> Option<&str> {
        self.text_content
            .as_deref()
            .or(self.url.as_deref())
            .or(self.file_path.as_deref())
            .filter(|s| !s.is_empty())
    }

    /// 内容字节数（UTF-8）。
    pub fn content_size(&self) -> i64 {
        self.content().map_or(0, |c| c.len() as i64)
    }

    /// 基础校验：至少要有一种可保存的内容。
    pub fn validate(&self) -> Result<()> {
        if self.content().is_none() && self.image_source_path.is_none() {
            return Err(AidoPasteError::InvalidInput(
                "clipboard item requires non-empty text, url, file_path or image".into(),
            ));
        }
        Ok(())
    }

    /// 推导标题：URL 取域名，文件取文件名，文本取首个非空行。
    pub fn derive_title(&self) -> Option<String> {
        match self.item_type {
            ItemType::Url => self.url.as_deref().and_then(url_host),
            ItemType::File | ItemType::Folder => {
                self.file_path.as_deref().and_then(last_path_component)
            }
            ItemType::Image => None,
            _ => self
                .text_content
                .as_deref()
                .and_then(first_non_empty_line)
                .map(|l| truncate_chars(l, MAX_TITLE_CHARS)),
        }
    }

    /// 推导预览：列表页展示的短文本。
    pub fn derive_preview(&self) -> Option<String> {
        match self.item_type {
            ItemType::Url => self.url.clone(),
            ItemType::File | ItemType::Folder => self.file_path.clone(),
            ItemType::Image => None,
            _ => self.text_content.as_deref().map(|t| {
                let collapsed: String = t.split_whitespace().collect::<Vec<_>>().join(" ");
                truncate_with_ellipsis(&collapsed, MAX_PREVIEW_CHARS)
            }),
        }
    }
}

/// 统计信息（§54 get_statistics）。
#[derive(Debug, Clone, Default)]
pub struct Statistics {
    pub total_count: i64,
    pub pinned_count: i64,
    pub total_content_size: i64,
    pub by_type: Vec<(ItemType, i64)>,
}

fn truncate_chars(s: &str, max: usize) -> String {
    s.chars().take(max).collect()
}

fn truncate_with_ellipsis(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut cut: String = s.chars().take(max).collect();
    cut.push('…');
    cut
}

fn first_non_empty_line(s: &str) -> Option<&str> {
    s.lines().map(str::trim).find(|l| !l.is_empty())
}

fn url_host(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let host = rest.split(['/', '?', '#']).next()?;
    (!host.is_empty()).then(|| host.to_string())
}

fn last_path_component(path: &str) -> Option<String> {
    let trimmed = path.trim_end_matches('/');
    Path::new(trimmed)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_item(text: &str) -> NewClipboardItem {
        NewClipboardItem {
            item_type: ItemType::Text,
            text_content: Some(text.into()),
            ..Default::default()
        }
    }

    #[test]
    fn content_prefers_text_then_url_then_path() {
        let mut item = text_item("hello");
        assert_eq!(item.content(), Some("hello"));
        item.text_content = None;
        item.url = Some("https://a.com".into());
        assert_eq!(item.content(), Some("https://a.com"));
        item.url = None;
        item.file_path = Some("/tmp/x".into());
        assert_eq!(item.content(), Some("/tmp/x"));
        item.file_path = None;
        assert_eq!(item.content(), None);
    }

    #[test]
    fn validate_rejects_empty_item() {
        let item = NewClipboardItem::default();
        assert!(matches!(
            item.validate(),
            Err(AidoPasteError::InvalidInput(_))
        ));
        assert!(text_item("ok").validate().is_ok());
    }

    #[test]
    fn derive_title_for_url_uses_host() {
        let item = NewClipboardItem {
            item_type: ItemType::Url,
            url: Some("https://developer.apple.com/design/?x=1".into()),
            ..Default::default()
        };
        assert_eq!(item.derive_title().as_deref(), Some("developer.apple.com"));
    }

    #[test]
    fn derive_title_for_file_uses_file_name() {
        let item = NewClipboardItem {
            item_type: ItemType::File,
            file_path: Some("/Users/undo/Desktop/report.xlsx".into()),
            ..Default::default()
        };
        assert_eq!(item.derive_title().as_deref(), Some("report.xlsx"));
    }

    #[test]
    fn derive_title_for_text_uses_first_non_empty_line() {
        let item = text_item("\n  \n第二行标题\n正文");
        assert_eq!(item.derive_title().as_deref(), Some("第二行标题"));
    }

    #[test]
    fn derive_preview_collapses_whitespace_and_truncates() {
        let long = "字".repeat(500);
        let item = text_item(&long);
        let preview = item.derive_preview().unwrap();
        assert_eq!(preview.chars().count(), MAX_PREVIEW_CHARS + 1); // 含省略号
        assert!(preview.ends_with('…'));

        let short = text_item("a\n\tb   c");
        assert_eq!(short.derive_preview().as_deref(), Some("a b c"));
    }

    #[test]
    fn item_type_roundtrip_unknown_falls_back_to_other() {
        assert_eq!(ItemType::from_db(ItemType::Code.as_str()), ItemType::Code);
        assert_eq!(ItemType::from_db("future_type"), ItemType::Other);
    }
}
