//! 图片与缩略图存储（§20）。
//! 原图按内容哈希命名存入 `Images/`，缩略图（PNG，最长边 320px）存入 `Thumbnails/`；
//! 数据库只保存路径（§12）。内容寻址让重复保存天然幂等，也便于孤儿文件清理（Phase 9）。

use std::fs;
use std::path::{Path, PathBuf};

use crate::error::{AidoPasteError, Result};

/// 缩略图最长边（§59：列表只加载缩略图，不加载原图）。
const THUMBNAIL_MAX_EDGE: u32 = 320;

/// 一张图片落盘后的产物路径。
#[derive(Debug, Clone)]
pub struct StoredImage {
    pub image_path: String,
    pub thumbnail_path: Option<String>,
}

/// 图片文件存储。线程安全：所有方法只做文件系统操作，无内部状态。
#[derive(Debug, Clone)]
pub struct ImageStore {
    images_dir: PathBuf,
    thumbnails_dir: PathBuf,
}

impl ImageStore {
    /// 打开（或创建）存储目录结构。
    pub fn open(storage_root: &Path) -> Result<Self> {
        let images_dir = storage_root.join("Images");
        let thumbnails_dir = storage_root.join("Thumbnails");
        fs::create_dir_all(&images_dir)?;
        fs::create_dir_all(&thumbnails_dir)?;
        Ok(Self {
            images_dir,
            thumbnails_dir,
        })
    }

    /// 把捕获的图片文件按内容哈希落盘并生成缩略图。
    /// 写临时文件后 rename，崩溃不会留下半截文件（§48）。
    pub fn store(&self, source: &Path, content_hash: &str) -> Result<StoredImage> {
        let extension = source
            .extension()
            .and_then(|e| e.to_str())
            .map(str::to_lowercase)
            .filter(|e| !e.is_empty())
            .unwrap_or_else(|| "png".to_string());

        let image_path = self.images_dir.join(format!("{content_hash}.{extension}"));
        let temp_path = self
            .images_dir
            .join(format!(".tmp-{content_hash}.{extension}"));
        fs::copy(source, &temp_path)?;
        fs::rename(&temp_path, &image_path)?;

        Ok(StoredImage {
            image_path: image_path.to_string_lossy().into_owned(),
            thumbnail_path: self.store_thumbnail(source, content_hash),
        })
    }

    /// 删除条目对应的图片与缩略图文件（§32）。文件不存在时忽略。
    pub fn remove(&self, image_path: Option<&str>, thumbnail_path: Option<&str>) {
        for path in [image_path, thumbnail_path].into_iter().flatten() {
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    log::warn!(target: "aidopaste", "artifact remove failed: {error}");
                }
            }
        }
    }

    /// 生成缩略图。无法解码的格式（如 HEIC）记录后跳过，不影响原图保存。
    fn store_thumbnail(&self, source: &Path, content_hash: &str) -> Option<String> {
        match self.try_store_thumbnail(source, content_hash) {
            Ok(path) => path,
            Err(error) => {
                // §84：日志不含内容，仅记录失败事实
                log::warn!(target: "aidopaste", "thumbnail generation skipped: {error}");
                None
            }
        }
    }

    fn try_store_thumbnail(&self, source: &Path, content_hash: &str) -> Result<Option<String>> {
        let image = image::open(source)
            .map_err(|error| AidoPasteError::Storage(format!("image decode failed: {error}")))?;
        let thumbnail = image.thumbnail(THUMBNAIL_MAX_EDGE, THUMBNAIL_MAX_EDGE);
        let path = self.thumbnails_dir.join(format!("{content_hash}.png"));
        let temp_path = self.thumbnails_dir.join(format!(".tmp-{content_hash}.png"));
        thumbnail
            .save_with_format(&temp_path, image::ImageFormat::Png)
            .map_err(|error| {
                AidoPasteError::Storage(format!("thumbnail encode failed: {error}"))
            })?;
        fs::rename(&temp_path, &path)?;
        Ok(Some(path.to_string_lossy().into_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_png(path: &Path, width: u32, height: u32) {
        let image = image::RgbImage::from_pixel(width, height, image::Rgb([180, 40, 40]));
        image
            .save_with_format(path, image::ImageFormat::Png)
            .unwrap();
    }

    #[test]
    fn store_creates_hash_named_image_and_thumbnail() {
        let root = tempfile::tempdir().unwrap();
        let store = ImageStore::open(root.path()).unwrap();
        let source_dir = tempfile::tempdir().unwrap();
        let source = source_dir.path().join("capture.png");
        make_test_png(&source, 640, 480);

        let stored = store.store(&source, "abc123").unwrap();
        assert!(stored.image_path.ends_with("Images/abc123.png"));
        let thumbnail = stored.thumbnail_path.expect("png should have thumbnail");
        assert!(thumbnail.ends_with("Thumbnails/abc123.png"));
        assert!(Path::new(&stored.image_path).exists());
        assert!(Path::new(&thumbnail).exists());

        // 缩略图最长边不超过 320
        let decoded = image::open(Path::new(&thumbnail)).unwrap();
        assert!(decoded.width() <= 320 && decoded.height() <= 320);
    }

    #[test]
    fn store_is_idempotent_for_same_hash() {
        let root = tempfile::tempdir().unwrap();
        let store = ImageStore::open(root.path()).unwrap();
        let source_dir = tempfile::tempdir().unwrap();
        let source = source_dir.path().join("capture.tiff");
        // 用 png 数据配 tiff 扩展名也可以：store 只搬运字节
        make_test_png(&source, 100, 100);

        let first = store.store(&source, "hash1").unwrap();
        let second = store.store(&source, "hash1").unwrap();
        assert_eq!(first.image_path, second.image_path);
    }

    #[test]
    fn undecodable_image_still_stores_without_thumbnail() {
        let root = tempfile::tempdir().unwrap();
        let store = ImageStore::open(root.path()).unwrap();
        let source_dir = tempfile::tempdir().unwrap();
        let source = source_dir.path().join("garbage.png");
        fs::write(&source, b"not an image at all").unwrap();

        let stored = store.store(&source, "bad1").unwrap();
        assert!(Path::new(&stored.image_path).exists());
        assert!(stored.thumbnail_path.is_none());
    }

    #[test]
    fn remove_deletes_artifacts_and_tolerates_missing() {
        let root = tempfile::tempdir().unwrap();
        let store = ImageStore::open(root.path()).unwrap();
        let source_dir = tempfile::tempdir().unwrap();
        let source = source_dir.path().join("capture.png");
        make_test_png(&source, 50, 50);
        let stored = store.store(&source, "del1").unwrap();

        store.remove(Some(&stored.image_path), stored.thumbnail_path.as_deref());
        assert!(!Path::new(&stored.image_path).exists());
        // 再次删除不报错
        store.remove(Some(&stored.image_path), stored.thumbnail_path.as_deref());
    }
}
