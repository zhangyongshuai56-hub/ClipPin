//! 内容哈希与去重支持（§17）。哈希只基于内容字节，与来源、时间无关。

use sha2::{Digest, Sha256};

use super::model::NewClipboardItem;
use crate::error::{PasteError, Result};

/// 内容字节的 SHA-256 十六进制摘要。
pub fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    let digest = hasher.finalize();
    let mut hex = String::with_capacity(digest.len() * 2);
    for byte in digest.iter() {
        hex.push_str(&format!("{byte:02x}"));
    }
    hex
}

/// 为新条目计算 content_hash。相同内容得到相同哈希，是去重的唯一依据。
pub fn hash_for_new_item(item: &NewClipboardItem) -> Result<String> {
    let content = item
        .content()
        .ok_or_else(|| PasteError::InvalidInput("item has no hashable content".into()))?;
    Ok(sha256_hex(content.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clipboard::model::ItemType;

    #[test]
    fn sha256_is_stable_and_hex() {
        // echo -n "hello" | shasum -a 256
        assert_eq!(
            sha256_hex(b"hello"),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn identical_content_hashes_identically() {
        let a = NewClipboardItem {
            item_type: ItemType::Text,
            text_content: Some("Hello".into()),
            ..Default::default()
        };
        let b = NewClipboardItem {
            item_type: ItemType::Text,
            text_content: Some("Hello".into()),
            source_app: Some("other.app".into()),
            ..Default::default()
        };
        assert_eq!(
            hash_for_new_item(&a).unwrap(),
            hash_for_new_item(&b).unwrap()
        );
    }

    #[test]
    fn different_content_hashes_differently() {
        let a = NewClipboardItem {
            item_type: ItemType::Text,
            text_content: Some("Hello".into()),
            ..Default::default()
        };
        let b = NewClipboardItem {
            item_type: ItemType::Text,
            text_content: Some("Hello ".into()),
            ..Default::default()
        };
        assert_ne!(
            hash_for_new_item(&a).unwrap(),
            hash_for_new_item(&b).unwrap()
        );
    }

    #[test]
    fn empty_item_cannot_be_hashed() {
        let item = NewClipboardItem::default();
        assert!(matches!(
            hash_for_new_item(&item),
            Err(PasteError::InvalidInput(_))
        ));
    }
}
