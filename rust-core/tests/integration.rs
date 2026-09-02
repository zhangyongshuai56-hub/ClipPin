//! 集成测试：创建 → 去重 → 分类 → 搜索 → Pin → 清理 → 统计 → 持久化。
//! 覆盖 §68（数据库/去重/分类/搜索/清理）与 §70 的 Core 侧场景。

use aidopaste_core::{CleanupManager, Database, ItemType, NewClipboardItem, Retention};

fn text(content: &str) -> NewClipboardItem {
    NewClipboardItem {
        item_type: ItemType::Text,
        text_content: Some(content.into()),
        ..Default::default()
    }
}

fn source(content: &str, app: &str) -> NewClipboardItem {
    NewClipboardItem {
        item_type: ItemType::Text,
        text_content: Some(content.into()),
        source_app: Some(app.into()),
        source_app_name: Some(app.into()),
        ..Default::default()
    }
}

#[test]
fn duplicate_content_dedups_and_touches() {
    let db = Database::open_in_memory().unwrap();
    let first = db
        .create_item(source("Hello AidoPaste", "com.apple.Safari"))
        .unwrap();
    db.pin_item(first.id).unwrap();

    let again = db
        .create_item(source("Hello AidoPaste", "com.google.Chrome"))
        .unwrap();

    // 同内容不产生新记录，id 不变
    assert_eq!(first.id, again.id);
    assert_eq!(db.get_items(None, 100, 0).unwrap().len(), 1);
    // Pin 状态保留，来源更新为最近一次
    let item = db.get_item(first.id).unwrap();
    assert!(item.is_pinned);
    assert_eq!(item.source_app.as_deref(), Some("com.google.Chrome"));
    // content_hash 稳定
    assert_eq!(first.content_hash, again.content_hash);
}

#[test]
fn text_is_auto_classified_to_url_or_code() {
    let db = Database::open_in_memory().unwrap();
    let url = db.create_item(text("https://apple.com")).unwrap();
    assert_eq!(url.item_type, ItemType::Url);
    assert_eq!(url.title.as_deref(), Some("apple.com"));

    let code = db
        .create_item(text(r#"{"name": "AidoPaste", "tags": [1, 2]}"#))
        .unwrap();
    assert_eq!(code.item_type, ItemType::Code);
    let metadata = code.metadata.as_deref().unwrap_or_default();
    assert!(metadata.contains("json"), "metadata={metadata}");

    let plain = db.create_item(text("今天天气不错")).unwrap();
    assert_eq!(plain.item_type, ItemType::Text);
}

#[test]
fn pagination_and_type_filter() {
    let db = Database::open_in_memory().unwrap();
    for i in 0..5 {
        db.create_item(text(&format!("text item {i}"))).unwrap();
    }
    for i in 0..3 {
        let url = NewClipboardItem {
            item_type: ItemType::Url,
            url: Some(format!("https://example{i}.com")),
            ..Default::default()
        };
        db.create_item(url).unwrap();
    }

    assert_eq!(db.get_items(None, 100, 0).unwrap().len(), 8);
    assert_eq!(db.get_items(None, 3, 0).unwrap().len(), 3);
    // 第二页
    let page2 = db.get_items(None, 3, 3).unwrap();
    assert_eq!(page2.len(), 3);
    // 类型过滤
    assert_eq!(db.get_items(Some(ItemType::Url), 100, 0).unwrap().len(), 3);
    assert_eq!(db.get_items(Some(ItemType::Text), 100, 0).unwrap().len(), 5);
}

#[test]
fn search_finds_english_cjk_and_quoted_content() {
    let db = Database::open_in_memory().unwrap();
    db.create_item(text("Apple Silicon 非常快")).unwrap();
    db.create_item(text("今天天气不错，适合出去走走")).unwrap();
    db.create_item(text(r#"复制 "引号" 内容"#)).unwrap();
    db.create_item(text("完全无关的内容")).unwrap();

    // 英文（大小写不敏感）
    assert_eq!(db.search_items("apple", None, 50, 0).unwrap().len(), 1);
    // 中文 ≥3 字走 trigram
    assert_eq!(db.search_items("天气不错", None, 50, 0).unwrap().len(), 1);
    // 中文 2 字走 LIKE 回退
    assert_eq!(db.search_items("天气", None, 50, 0).unwrap().len(), 1);
    // 含引号的内容可安全检索
    assert_eq!(db.search_items(r#""引号""#, None, 50, 0).unwrap().len(), 1);
    // FTS 操作符注入不会生效
    assert_eq!(
        db.search_items("apple OR notfound", None, 50, 0)
            .unwrap()
            .len(),
        0
    );
    // 无命中
    assert_eq!(db.search_items("zzzzz", None, 50, 0).unwrap().len(), 0);
    // 空查询 = 列出全部
    assert_eq!(db.search_items("  ", None, 50, 0).unwrap().len(), 4);
}

#[test]
fn search_supports_source_app_and_respects_type_filter() {
    let db = Database::open_in_memory().unwrap();
    db.create_item(source("zebra crossing 素材", "com.apple.Notes"))
        .unwrap();
    db.create_item(NewClipboardItem {
        item_type: ItemType::Url,
        url: Some("https://zebra.example.com".into()),
        source_app_name: Some("Safari".into()),
        ..Default::default()
    })
    .unwrap();

    // 命中来源应用名
    assert_eq!(db.search_items("Notes", None, 50, 0).unwrap().len(), 1);
    // 同关键词命中两种类型，再按类型过滤
    assert_eq!(db.search_items("zebra", None, 50, 0).unwrap().len(), 2);
    assert_eq!(
        db.search_items("zebra", Some(ItemType::Url), 50, 0)
            .unwrap()
            .len(),
        1
    );
    // URL / 文件路径关键词
    assert_eq!(
        db.search_items("zebra.example", None, 50, 0).unwrap().len(),
        1
    );
}

#[test]
fn delete_removes_from_search_index() {
    let db = Database::open_in_memory().unwrap();
    let item = db.create_item(text("unique-needle 特征词内容")).unwrap();
    assert_eq!(
        db.search_items("unique-needle", None, 50, 0).unwrap().len(),
        1
    );
    db.delete_item(item.id).unwrap();
    assert_eq!(
        db.search_items("unique-needle", None, 50, 0).unwrap().len(),
        0
    );
}

#[test]
fn batch_delete_returns_deleted_count() {
    let db = Database::open_in_memory().unwrap();
    let ids: Vec<i64> = (0..5)
        .map(|i| db.create_item(text(&format!("batch {i}"))).unwrap().id)
        .collect();
    let deleted = db.delete_items(&ids[0..3]).unwrap();
    assert_eq!(deleted, 3);
    assert_eq!(db.get_items(None, 100, 0).unwrap().len(), 2);
    // 重复删除同一批：0
    assert_eq!(db.delete_items(&ids[0..3]).unwrap(), 0);
}

#[test]
fn pin_unpin_and_pinned_listing() {
    let db = Database::open_in_memory().unwrap();
    let a = db.create_item(text("pin me")).unwrap();
    db.create_item(text("not pinned")).unwrap();

    assert_eq!(db.get_pinned_items(100, 0).unwrap().len(), 0);
    db.pin_item(a.id).unwrap();
    let pinned = db.get_pinned_items(100, 0).unwrap();
    assert_eq!(pinned.len(), 1);
    assert_eq!(pinned[0].id, a.id);
    db.unpin_item(a.id).unwrap();
    assert_eq!(db.get_pinned_items(100, 0).unwrap().len(), 0);

    // 不存在的 id 报 NotFound
    assert!(matches!(
        db.pin_item(999),
        Err(aidopaste_core::AidoPasteError::NotFound(999))
    ));
}

#[test]
fn cleanup_keeps_pinned_and_respects_retention_never() {
    let db = Database::open_in_memory().unwrap();
    let plain = db.create_item(text("old item")).unwrap();
    let pinned = db.create_item(text("old but pinned")).unwrap();
    db.pin_item(pinned.id).unwrap();

    // 8 天后
    let future = aidopaste_core::clipboard::model::now_ms() + 8 * 86_400_000;
    assert_eq!(db.cleanup_expired(Retention::SevenDays, future).unwrap(), 1);
    assert!(db.get_item(plain.id).is_err());
    assert!(db.get_item(pinned.id).is_ok());

    // 幂等
    assert_eq!(db.cleanup_expired(Retention::SevenDays, future).unwrap(), 0);
    // Never 永不清理
    assert_eq!(db.cleanup_expired(Retention::Never, future).unwrap(), 0);
}

#[test]
fn history_limit_keeps_recent_and_pinned() {
    let db = Database::open_in_memory().unwrap();
    let first = db.create_item(text("oldest, will be pinned")).unwrap();
    db.pin_item(first.id).unwrap();
    for i in 0..9 {
        db.create_item(text(&format!("history item {i}"))).unwrap();
    }
    assert_eq!(db.get_items(None, 100, 0).unwrap().len(), 10);

    let trimmed = db.enforce_history_limit(5).unwrap();
    // 4 条最旧的非 Pin 被删（第 5 名是 pinned，不参与）
    assert_eq!(trimmed, 4);
    assert_eq!(db.get_items(None, 100, 0).unwrap().len(), 6);
    // Pin 永远保留
    assert!(db.get_item(first.id).is_ok());
}

#[test]
fn statistics_reflect_data() {
    let db = Database::open_in_memory().unwrap();
    db.create_item(text("统计文本一")).unwrap();
    db.create_item(text("统计文本二")).unwrap();
    db.create_item(text("https://stats.example.com")).unwrap();
    let pinned = db.create_item(text("统计置顶")).unwrap();
    db.pin_item(pinned.id).unwrap();

    let stats = db.get_statistics().unwrap();
    assert_eq!(stats.total_count, 4);
    assert_eq!(stats.pinned_count, 1);
    assert_eq!(stats.by_type.len(), 2);
    let text_count = stats
        .by_type
        .iter()
        .find(|(t, _)| *t == ItemType::Text)
        .map(|(_, c)| *c)
        .unwrap_or(0);
    let url_count = stats
        .by_type
        .iter()
        .find(|(t, _)| *t == ItemType::Url)
        .map(|(_, c)| *c)
        .unwrap_or(0);
    assert_eq!(text_count, 3);
    assert_eq!(url_count, 1);
    assert!(stats.total_content_size > 0);
}

#[test]
fn data_persists_across_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("clipboard.db");

    let created_id = {
        let db = Database::open(&path).unwrap();
        assert_eq!(db.schema_version().unwrap(), 1);
        let item = db
            .create_item(source("跨重启保留的内容", "com.apple.Safari"))
            .unwrap();
        item.id
    };

    // 重新打开：数据完好，版本不重复迁移
    let db = Database::open(&path).unwrap();
    assert_eq!(db.schema_version().unwrap(), 1);
    let items = db.get_items(None, 100, 0).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, created_id);
    assert_eq!(items[0].text_content.as_deref(), Some("跨重启保留的内容"));
}

#[test]
fn missing_items_report_not_found() {
    let db = Database::open_in_memory().unwrap();
    assert!(matches!(
        db.get_item(12345),
        Err(aidopaste_core::AidoPasteError::NotFound(12345))
    ));
    assert!(db.delete_item(12345).is_err());
    assert!(db.unpin_item(12345).is_err());
}

#[test]
fn cleanup_manager_runs_over_shared_database() {
    let db = Database::open_in_memory().unwrap();
    let manager = CleanupManager::new(std::sync::Arc::new(db));
    let report = manager.run(Retention::Never).unwrap();
    assert_eq!(report.deleted_items, 0);
    assert_eq!(manager.enforce_history_limit(10).unwrap(), 0);
}

#[test]
fn concurrent_writers_are_serialized_safely() {
    let db = std::sync::Arc::new(Database::open_in_memory().unwrap());
    let handles: Vec<_> = (0..8)
        .map(|i| {
            let db = db.clone();
            std::thread::spawn(move || {
                for j in 0..10 {
                    db.create_item(text(&format!("thread-{i}-item-{j}")))
                        .unwrap();
                }
            })
        })
        .collect();
    for handle in handles {
        handle.join().unwrap();
    }
    // 80 条内容各不相同
    assert_eq!(db.get_items(None, 1000, 0).unwrap().len(), 80);
}

// MARK: - 图片（Phase 7）

/// 生成测试 PNG 文件，返回 (目录守卫, 文件路径, 文件大小)。
fn make_png(name: &str, width: u32, height: u32) -> (tempfile::TempDir, std::path::PathBuf, i64) {
    use image::Rgba;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(name);
    let image = image::RgbaImage::from_pixel(width, height, Rgba([60, 120, 200, 255]));
    image
        .save_with_format(&path, image::ImageFormat::Png)
        .unwrap();
    let size = std::fs::metadata(&path).unwrap().len() as i64;
    (dir, path, size)
}

fn image_item(source: &std::path::Path) -> NewClipboardItem {
    NewClipboardItem {
        item_type: ItemType::Image,
        image_source_path: Some(source.to_string_lossy().into_owned()),
        ..Default::default()
    }
}

#[test]
fn image_items_are_stored_with_thumbnail_and_dedup() {
    let db = Database::open_in_memory().unwrap();
    let (_guard, path, size) = make_png("capture.png", 640, 480);

    let first = db.create_item(image_item(&path)).unwrap();
    assert_eq!(first.item_type, ItemType::Image);
    assert_eq!(first.content_size, size);
    let image_path = first.image_path.clone().expect("image path set");
    let thumbnail_path = first.thumbnail_path.clone().expect("thumbnail generated");
    assert!(std::path::Path::new(&image_path).exists());
    assert!(std::path::Path::new(&thumbnail_path).exists());

    // 缩略图最长边不超过 320（§59）
    let decoded = image::open(&thumbnail_path).unwrap();
    assert!(decoded.width() <= 320 && decoded.height() <= 320);

    // 相同图片再次复制：去重 touch，不新增文件
    let again = db.create_item(image_item(&path)).unwrap();
    assert_eq!(first.id, again.id);
    assert_eq!(db.get_items(None, 100, 0).unwrap().len(), 1);

    // 删除条目：图片与缩略图一并清理（§32）
    db.delete_item(first.id).unwrap();
    assert!(!std::path::Path::new(&image_path).exists());
    assert!(!std::path::Path::new(&thumbnail_path).exists());
}

#[test]
fn cleanup_and_history_limit_remove_image_artifacts() {
    let db = Database::open_in_memory().unwrap();
    let (_guard, path, _) = make_png("cleanup.png", 200, 200);
    let item = db.create_item(image_item(&path)).unwrap();
    let image_path = item.image_path.clone().unwrap();
    let thumbnail_path = item.thumbnail_path.clone().unwrap();

    let future = aidopaste_core::clipboard::model::now_ms() + 2 * 86_400_000;
    assert_eq!(db.cleanup_expired(Retention::OneDay, future).unwrap(), 1);
    assert!(!std::path::Path::new(&image_path).exists());
    assert!(!std::path::Path::new(&thumbnail_path).exists());

    // 历史条数上限同样清理文件
    let item = db.create_item(image_item(&path)).unwrap();
    let image_path = item.image_path.clone().unwrap();
    assert_eq!(db.enforce_history_limit(0).unwrap(), 1);
    assert!(!std::path::Path::new(&image_path).exists());
}

#[test]
fn batch_delete_removes_image_artifacts() {
    let db = Database::open_in_memory().unwrap();
    let (_guard_a, path_a, _) = make_png("a.png", 64, 64);
    let (_guard_b, path_b, _) = make_png("b.png", 64, 64);
    let a = db.create_item(image_item(&path_a)).unwrap();
    let b = db.create_item(image_item(&path_b)).unwrap();

    db.delete_items(&[a.id, b.id]).unwrap();
    assert!(!std::path::Path::new(&a.image_path.unwrap()).exists());
    assert!(!std::path::Path::new(&b.thumbnail_path.unwrap()).exists());
}

// MARK: - 文件 / 文件夹（Phase 8）

fn file_item(path: &std::path::Path) -> NewClipboardItem {
    NewClipboardItem {
        item_type: ItemType::File,
        file_path: Some(path.to_string_lossy().into_owned()),
        ..Default::default()
    }
}

#[test]
fn file_items_capture_metadata_without_copying_content() {
    let db = Database::open_in_memory().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("report.xlsx");
    std::fs::write(&path, b"fake workbook bytes").unwrap();
    let expected_size = std::fs::metadata(&path).unwrap().len() as i64;

    let item = db.create_item(file_item(&path)).unwrap();
    assert_eq!(item.item_type, ItemType::File);
    assert_eq!(item.title.as_deref(), Some("report.xlsx"));
    assert_eq!(item.content_size, expected_size);
    // §21：不复制文件本体，无图片产物
    assert!(item.image_path.is_none());
    let metadata = item.metadata.as_deref().unwrap_or_default();
    assert!(metadata.contains("isDirectory"), "metadata={metadata}");
    assert!(!metadata.contains("true"));

    // 同一文件再次复制 → 去重 touch
    let again = db.create_item(file_item(&path)).unwrap();
    assert_eq!(item.id, again.id);
    assert_eq!(db.get_items(None, 100, 0).unwrap().len(), 1);

    // 文件内容变更（大小变化）后再复制 → 新条目
    std::fs::write(&path, b"changed content with different size").unwrap();
    let changed = db.create_item(file_item(&path)).unwrap();
    assert_ne!(item.id, changed.id);
    assert_eq!(db.get_items(None, 100, 0).unwrap().len(), 2);
}

#[test]
fn folder_items_are_detected_from_actual_filesystem() {
    let db = Database::open_in_memory().unwrap();
    let dir = tempfile::tempdir().unwrap();
    // Swift 侧即便误传 File 类型，Core 也按真实文件系统纠正为 Folder
    let item = db.create_item(file_item(dir.path())).unwrap();
    assert_eq!(item.item_type, ItemType::Folder);
    let metadata = item.metadata.as_deref().unwrap_or_default();
    assert!(
        metadata.contains("\"isDirectory\":true"),
        "metadata={metadata}"
    );
    assert_eq!(item.content_size, 0);
    assert!(item.title.as_deref().map(str::len).unwrap_or(0) > 0);
}

#[test]
fn missing_files_fail_without_creating_rows() {
    let db = Database::open_in_memory().unwrap();
    let missing = std::path::Path::new("/tmp/aidopaste-nonexistent-file-xyz");
    let result = db.create_item(file_item(missing));
    assert!(matches!(
        result,
        Err(aidopaste_core::AidoPasteError::FileSystem(_))
    ));
    assert_eq!(db.get_items(None, 100, 0).unwrap().len(), 0);
}
