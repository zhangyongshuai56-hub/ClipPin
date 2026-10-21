import Foundation
import CryptoKit

// MARK: - SQLite 数据库入口（port of storage/database.rs + search/search_engine.rs）
//
// schema 经 `PRAGMA user_version` 迁移框架演进，只追加迁移、不改历史（§47）。
// 访问由 ClipboardRepository actor 串行化；单连接 + WAL + busy_timeout。

/// 当前 schema 版本。
let pasteSchemaVersion = 5

/// 迁移 SQL 列表，下标 `i` 对应目标版本 `i + 1`。与 Rust 版逐行对齐，禁止修改历史条目。
private let pasteMigrations: [String] = [
    // v1：初始 schema（§14）。FTS5 external-content + trigram：中英文都能子串匹配（§29）。
    """
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
    """,
    // v2：Pinboard 文件夹。board_id 为 NULL 表示在默认「剪贴板」；加入文件夹的条目豁免自动清理。
    """
    CREATE TABLE boards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        color TEXT NOT NULL DEFAULT '#4F8EF7',
        position INTEGER NOT NULL DEFAULT 0
    );

    ALTER TABLE clipboard_items ADD COLUMN board_id INTEGER;

    CREATE INDEX idx_clipboard_items_board ON clipboard_items(board_id);
    """,
    // v3：content_hash 唯一约束——先清历史重复（保留 updated_at 最新，平局取 id 大），再建唯一索引。
    """
    DELETE FROM clipboard_items
    WHERE EXISTS (
        SELECT 1 FROM clipboard_items AS d
        WHERE d.content_hash = clipboard_items.content_hash
          AND (d.updated_at > clipboard_items.updated_at
               OR (d.updated_at = clipboard_items.updated_at AND d.id > clipboard_items.id))
    );

    DROP INDEX IF EXISTS idx_clipboard_items_content_hash;
    CREATE UNIQUE INDEX idx_clipboard_items_content_hash_unique ON clipboard_items(content_hash);
    """,
    // v4：删除保留收藏（removed_from_history）+ 记录命名（title_is_custom）。
    """
    ALTER TABLE clipboard_items ADD COLUMN removed_from_history INTEGER NOT NULL DEFAULT 0;

    ALTER TABLE clipboard_items ADD COLUMN title_is_custom INTEGER NOT NULL DEFAULT 0;
    """,
    // v5：FTS 更新触发器加 WHEN 限制——仅索引列（title/text_content/url/file_path/
    // source_app_name）变化时才重建 trigram 索引行。dedup touch、pin、移动文件夹等
    // 高频 UPDATE 只改非索引列，此前每次都白做一次与文本长度正相关的索引重写。
    """
    DROP TRIGGER IF EXISTS clipboard_items_fts_au;

    CREATE TRIGGER clipboard_items_fts_au AFTER UPDATE ON clipboard_items
    WHEN old.title IS NOT new.title
        OR old.text_content IS NOT new.text_content
        OR old.url IS NOT new.url
        OR old.file_path IS NOT new.file_path
        OR old.source_app_name IS NOT new.source_app_name
    BEGIN
        INSERT INTO clipboard_fts(clipboard_fts, rowid, title, text_content, url, file_path, source_app_name)
        VALUES ('delete', old.id, old.title, old.text_content, old.url, old.file_path, old.source_app_name);
        INSERT INTO clipboard_fts(rowid, title, text_content, url, file_path, source_app_name)
        VALUES (new.id, new.title, new.text_content, new.url, new.file_path, new.source_app_name);
    END;
    """,
]

/// 单次查询返回的最大条数，防御一次性加载过多数据（§57）。
private let maxPageSize = 1000

final class PasteDatabase {
    private let connection: SQLiteDatabase
    private let imageStore: ImageStore
    /// 内存库（自测）的临时图片目录；deinit 时删除，不在 /tmp 遗留垃圾。
    private let transientStorageRoot: URL?

    deinit {
        if let transientStorageRoot {
            try? FileManager.default.removeItem(at: transientStorageRoot)
        }
    }

    /// 打开（或创建）数据库文件；存储根目录取数据库文件的祖父目录（§20）。
    convenience init(path: String) throws {
        let databaseURL = URL(fileURLWithPath: path)
        // .../Paste/Database/clipboard.db → .../Paste
        let storageRoot = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
        try self.init(databasePath: path, storageRoot: storageRoot)
    }

    /// 内存数据库（":memory:" 必须以字符串直传；经 URL 转换会变成当前目录下的真实文件）。
    convenience init(inMemoryForTesting: Bool) throws {
        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-images-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try self.init(databasePath: ":memory:", storageRoot: storageRoot, transientStorageRoot: storageRoot)
    }

    private init(databasePath: String, storageRoot: URL, transientStorageRoot: URL? = nil) throws {
        connection = try SQLiteDatabase(path: databasePath)
        imageStore = try ImageStore(storageRoot: storageRoot)
        self.transientStorageRoot = transientStorageRoot
        try runMigrations(connection)
    }

    func schemaVersion() throws -> Int {
        Int(try connection.userVersion())
    }

    private func runMigrations(_ connection: SQLiteDatabase) throws {
        let current = try connection.userVersion()
        for (index, sql) in pasteMigrations.enumerated() {
            let target = index + 1
            guard Int32(current) < target else { continue }
            do {
                try connection.transaction {
                    try connection.executeBatch(sql)
                    try connection.setUserVersion(Int32(target))
                }
            } catch {
                throw PasteError.migration(target: target, message: String(describing: error))
            }
        }
        assert(pasteMigrations.count == pasteSchemaVersion)
    }

    // MARK: - 条目

    /// 创建条目（§54 create_item）。相同 content_hash 不重复入库（§17）：
    /// 仅刷新 updated_at 并更新来源，保留 created_at 与 Pin 状态。
    /// 返回 isNew 显式区分「新插入」与「命中已有记录」，调用方不必靠字段值反推。
    func createItem(_ entry: NewClipboardEntry) throws -> CreateItemOutcome {
        let resolved = try resolveNewItem(entry)
        let effective = resolved.effective
        let now = nowMillis()
        let createdAtMillis = entry.createdAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? now
        let title = entry.title ?? deriveTitle(for: effective)
        let preview = derivePreview(for: effective)

        var isNew = true
        let id: Int64 = try connection.transaction {
            if let existing = try connection.queryFirst(
                "SELECT id, removed_from_history FROM clipboard_items WHERE content_hash = ?1",
                [.text(resolved.contentHash)],
                map: { (id: try $0.int("id"), removed: try $0.bool("removed_from_history")) }) {
                // 重新复制曾从历史移除、仅收藏在文件夹中的内容时恢复其在历史中的可见性，
                // 否则用户视角下「再次复制」毫无反应（唯一索引保证同 hash 至多一行）。
                if existing.removed {
                    try connection.run(
                        "UPDATE clipboard_items SET updated_at = ?2, removed_from_history = 0, source_app = COALESCE(?3, source_app), source_app_name = COALESCE(?4, source_app_name) WHERE id = ?1",
                        [.int(existing.id), .int(now), .textOrNil(entry.sourceApp), .textOrNil(entry.sourceAppName)])
                } else {
                    try connection.run(
                        "UPDATE clipboard_items SET updated_at = ?2, source_app = COALESCE(?3, source_app), source_app_name = COALESCE(?4, source_app_name) WHERE id = ?1",
                        [.int(existing.id), .int(now), .textOrNil(entry.sourceApp), .textOrNil(entry.sourceAppName)])
                }
                isNew = false
                return existing.id
            }
            // 新图片：先转存文件拿到路径，再入库；转存失败则整体失败，不落脏行
            var imagePath: String?
            var thumbnailPath: String?
            if let source = effective.imageSourcePath {
                let stored = try imageStore.store(source: URL(fileURLWithPath: source), contentHash: resolved.contentHash)
                imagePath = stored.imagePath
                thumbnailPath = stored.thumbnailPath
            }
            try connection.run(
                """
                INSERT INTO clipboard_items
                    (type, created_at, updated_at, title, preview, text_content, url,
                     file_path, image_path, thumbnail_path, source_app, source_app_name,
                     content_size, uti, content_hash, is_pinned, metadata)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, 0, ?16)
                """,
                [
                    .text(effective.itemType.databaseKey),
                    .int(createdAtMillis),
                    .int(now),
                    .textOrNil(title),
                    .textOrNil(preview),
                    .textOrNil(effective.textContent),
                    .textOrNil(effective.url),
                    .textOrNil(effective.filePath),
                    .textOrNil(imagePath),
                    .textOrNil(thumbnailPath),
                    .textOrNil(effective.sourceApp),
                    .textOrNil(effective.sourceAppName),
                    .int(resolved.contentSize),
                    .textOrNil(effective.uti),
                    .text(resolved.contentHash),
                    .textOrNil(effective.metadata),
                ])
            return connection.lastInsertRowID
        }
        return CreateItemOutcome(entry: try getItem(id: id), isNew: isNew)
    }

    /// 读取单条。
    func getItem(id: Int64) throws -> ClipboardEntry {
        guard let entry = try connection.queryFirst(
            "SELECT * FROM clipboard_items WHERE id = ?1", [.int(id)], map: Self.makeEntry)
        else { throw PasteError.notFound(id) }
        return entry
    }

    /// 分页列出（§58）：置顶在前，其余按最近使用排序。limit 超过上限自动截断。
    func getItems(filter: ClipboardEntryType?, boardId: Int64?, limit: Int, offset: Int) throws -> [ClipboardEntry] {
        guard limit >= 0, offset >= 0 else {
            throw PasteError.invalidInput("page range out of range: limit=\(limit) offset=\(offset)")
        }
        return try listItems(filter: filter, boardId: boardId, limit: min(limit, maxPageSize), offset: offset)
    }

    /// 纯历史条目（board_id IS NULL 且未软删除），供全库导出的「剪贴板历史」容器。
    /// 与默认「剪贴板」视图不同——视图按设计包含文件夹成员；文件夹成员随所在文件夹导出。
    func getHistoryOnlyItems(limit: Int, offset: Int) throws -> [ClipboardEntry] {
        guard limit >= 0, offset >= 0 else {
            throw PasteError.invalidInput("page range out of range: limit=\(limit) offset=\(offset)")
        }
        return try connection.query(
            "SELECT * FROM clipboard_items WHERE board_id IS NULL AND removed_from_history = 0 ORDER BY updated_at DESC, id DESC LIMIT ? OFFSET ?",
            [.int(Int64(min(limit, maxPageSize))), .int(Int64(offset))],
            map: Self.makeEntry)
    }

    /// 置顶条目（§31），按最近使用排序。
    func getPinnedItems(limit: Int, offset: Int) throws -> [ClipboardEntry] {
        guard limit >= 0, offset >= 0 else {
            throw PasteError.invalidInput("page range out of range: limit=\(limit) offset=\(offset)")
        }
        return try connection.query(
            "SELECT * FROM clipboard_items WHERE is_pinned = 1 AND removed_from_history = 0 ORDER BY updated_at DESC, id DESC LIMIT ?1 OFFSET ?2",
            [.int(Int64(min(limit, maxPageSize))), .int(Int64(offset))],
            map: Self.makeEntry)
    }

    /// 全文搜索（§29、§30）。空查询等价于 getItems。
    func searchItems(_ query: String, filter: ClipboardEntryType?, boardId: Int64?, limit: Int, offset: Int) throws -> [ClipboardEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit >= 0, offset >= 0 else {
            throw PasteError.invalidInput("page range out of range: limit=\(limit) offset=\(offset)")
        }
        if trimmed.isEmpty {
            return try listItems(filter: filter, boardId: boardId, limit: min(limit, maxPageSize), offset: offset)
        }
        if trimmed.count >= 3 {
            return try searchFullText(trimmed, filter: filter, boardId: boardId, limit: min(limit, maxPageSize), offset: offset)
        }
        return try searchLike(trimmed, filter: filter, boardId: boardId, limit: min(limit, maxPageSize), offset: offset)
    }

    /// 删除单条，并同步清理图片产物文件（§32）。
    func deleteItem(id: Int64) throws {
        let artifacts = try fetchArtifacts(ids: [id])
        let changed = try connection.run("DELETE FROM clipboard_items WHERE id = ?1", [.int(id)])
        if changed == 0 {
            throw PasteError.notFound(id)
        }
        artifacts.forEach { imageStore.remove(imagePath: $0.0, thumbnailPath: $0.1) }
    }

    /// 批量删除，返回实际删除数。删除的条目若带图片产物，文件一并清理（§32）。
    /// 全部 chunk 在同一事务内执行：任一 chunk 失败整体回滚，不留部分删除。
    func deleteItems(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var deleted = 0
        var artifacts: [(String?, String?)] = []
        try connection.transaction {
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                artifacts += try fetchArtifacts(ids: chunk)
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                deleted += try connection.run(
                    "DELETE FROM clipboard_items WHERE id IN (\(placeholders))",
                    chunk.map { .int($0) })
            }
        }
        artifacts.forEach { imageStore.remove(imagePath: $0.0, thumbnailPath: $0.1) }
        return deleted
    }

    /// Pin / Unpin（§31、§54）。
    func pinItem(id: Int64) throws { try setPinned(id: id, pinned: true) }

    func unpinItem(id: Int64) throws { try setPinned(id: id, pinned: false) }

    /// 从「剪贴板」历史移除条目（需求：删除保留收藏）。
    /// 未收藏条目物理删除（图片产物一并清理）；已收藏条目软删除（removed_from_history = 1
    /// 并取消置顶），继续保留在文件夹中；文件夹视图内的删除才是真删除。
    /// 查询归属与 UPDATE/DELETE 同事务：中途崩溃不会留下半程状态。
    func removeItemFromHistory(id: Int64) throws -> ItemRemovalOutcome {
        var artifacts: [(String?, String?)] = []
        let outcome: ItemRemovalOutcome = try connection.transaction {
            let boardId: Int64?? = try connection.queryFirst(
                "SELECT board_id FROM clipboard_items WHERE id = ?1",
                [.int(id)]) { try $0.intOrNil("board_id") }
            guard let boardId else { throw PasteError.notFound(id) }
            if boardId != nil {
                try connection.run(
                    "UPDATE clipboard_items SET removed_from_history = 1, is_pinned = 0 WHERE id = ?1",
                    [.int(id)])
                return .keptInBoard
            }
            artifacts = try fetchArtifacts(ids: [id])
            try connection.run("DELETE FROM clipboard_items WHERE id = ?1", [.int(id)])
            return .deleted
        }
        artifacts.forEach { imageStore.remove(imagePath: $0.0, thumbnailPath: $0.1) }
        return outcome
    }

    /// 设置条目的「从历史移除」标记（导入备份时还原软删除状态）。
    func setRemovedFromHistory(id: Int64, removed: Bool) throws {
        let changed = try connection.run(
            "UPDATE clipboard_items SET removed_from_history = ?2 WHERE id = ?1",
            [.int(id), .int(removed ? 1 : 0)])
        if changed == 0 {
            throw PasteError.notFound(id)
        }
    }

    /// 编辑文本条目内容（需求：编辑记录；仅文本类可编辑）。
    /// 重跑分类并重算内容指纹；命名过的标题保留。编辑后与已有记录完全相同时自动合并。
    func editTextItem(id: Int64, newText: String) throws -> ItemEditOutcome {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw PasteError.invalidInput("edited text must not be empty")
        }
        guard let existing = try connection.queryFirst(
            "SELECT * FROM clipboard_items WHERE id = ?1", [.int(id)], map: Self.makeEntry)
        else { throw PasteError.notFound(id) }
        switch existing.itemType {
        case .text, .url, .code, .richText, .other: break
        case .image, .file, .folder:
            throw PasteError.invalidInput("only text-like items can be edited")
        }

        let classified = classifyText(text)
        let url: String? = classified == .url ? text : nil
        let metadata: String?
        if let language = detectCodeLanguage(text) {
            metadata = Self.withLanguage(existing.metadata, language: language)
        } else {
            metadata = Self.withoutMetadataKey(existing.metadata, key: "language")
        }
        let title = existing.titleIsCustom ? existing.title : deriveTitle(
            type: classified, url: url, filePath: nil, textContent: text)
        let preview = derivePreview(type: classified, url: url, filePath: nil, textContent: text)
        let contentHash = try hashForItem(content: text)
        let now = nowMillis()

        // 与已有记录重复 → 合并：本条删除（防御性清理产物），组织信息归并到目标条目。
        // 归并规则：任一侧 Pin 则 Pin；任一侧在历史可见则可见；文件夹归属优先保留目标侧，
        // 目标侧无文件夹时继承本条；创建时间取更早者。
        var mergedId: Int64?
        var mergedArtifacts: [(String?, String?)] = []
        try connection.transaction {
            if let kept = try connection.queryFirst(
                "SELECT id, board_id FROM clipboard_items WHERE content_hash = ?1 AND id != ?2",
                [.text(contentHash), .int(id)],
                map: { (id: try $0.int("id"), boardId: try $0.intOrNil("board_id")) }) {
                // ?5 必须绑定被编辑条目（本行，尚未删除）的 board_id——
                // 归并规则「目标侧无文件夹时继承本条」；绑成目标行自己的值
                // 会让 COALESCE 变成 no-op，继承永远不生效。
                let editedBoardId: Int64?? = try connection.queryFirst(
                    "SELECT board_id FROM clipboard_items WHERE id = ?1",
                    [.int(id)]) { try $0.intOrNil("board_id") }
                mergedArtifacts = try fetchArtifacts(ids: [id])
                try connection.run(
                    """
                    UPDATE clipboard_items
                    SET updated_at = ?2,
                        is_pinned = MAX(is_pinned, ?3),
                        removed_from_history = MIN(removed_from_history, ?4),
                        board_id = COALESCE(board_id, ?5),
                        created_at = MIN(created_at, ?6)
                    WHERE id = ?1
                    """,
                    [
                        .int(kept.id),
                        .int(now),
                        .int(existing.isPinned ? 1 : 0),
                        .int(existing.removedFromHistory ? 1 : 0),
                        .intOrNil(editedBoardId ?? nil),
                        .int(Int64(existing.createdAt.timeIntervalSince1970 * 1000)),
                    ])
                try connection.run("DELETE FROM clipboard_items WHERE id = ?1", [.int(id)])
                mergedId = kept.id
            } else {
                try connection.run(
                    """
                    UPDATE clipboard_items
                    SET type = ?2, text_content = ?3, url = ?4, title = ?5, preview = ?6,
                        metadata = ?7, content_size = ?8, content_hash = ?9, updated_at = ?10
                    WHERE id = ?1
                    """,
                    [
                        .int(id),
                        .text(classified.databaseKey),
                        .text(text),
                        .textOrNil(url),
                        .textOrNil(title),
                        .textOrNil(preview),
                        .textOrNil(metadata),
                        .int(Int64(text.utf8.count)),
                        .text(contentHash),
                        .int(now),
                    ])
            }
        }
        mergedArtifacts.forEach { imageStore.remove(imagePath: $0.0, thumbnailPath: $0.1) }
        if let mergedId {
            let item = try getItem(id: mergedId)
            return ItemEditOutcome(entry: item, merged: true)
        }
        let item = try getItem(id: id)
        return ItemEditOutcome(entry: item, merged: false)
    }

    /// 命名条目：标题记为用户自定义，内容编辑 / 重新捕获不再覆盖。
    func renameItem(id: Int64, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PasteError.invalidInput("title must not be empty")
        }
        let changed = try connection.run(
            "UPDATE clipboard_items SET title = ?2, title_is_custom = 1, updated_at = ?3 WHERE id = ?1",
            [.int(id), .text(trimmed), .int(nowMillis())])
        if changed == 0 {
            throw PasteError.notFound(id)
        }
    }

    private func setPinned(id: Int64, pinned: Bool) throws {
        let changed = try connection.run(
            "UPDATE clipboard_items SET is_pinned = ?2 WHERE id = ?1",
            [.int(id), .int(pinned ? 1 : 0)])
        if changed == 0 {
            throw PasteError.notFound(id)
        }
    }

    // MARK: - 清理（§32、§50、§48）

    /// 删除过期未 Pin 且未收藏条目，图片产物文件一并清理。
    func cleanupExpired(retention: RetentionPolicy, nowMillis: Int64) throws -> Int {
        guard let days = retention.retentionDays else { return 0 }
        let cutoff = nowMillis - Int64(days) * 86_400_000
        let criteria = "WHERE is_pinned = 0 AND board_id IS NULL AND updated_at < ?1"
        var artifacts: [(String?, String?)] = []
        var deleted = 0
        try connection.transaction {
            artifacts = try fetchArtifacts(whereClause: criteria, params: [.int(cutoff)])
            deleted = try connection.run("DELETE FROM clipboard_items \(criteria)", [.int(cutoff)])
        }
        artifacts.prefix(deleted).forEach { imageStore.remove(imagePath: $0.0, thumbnailPath: $0.1) }
        return deleted
    }

    /// 历史条数上限（§50）：超出部分从最旧的非 Pin 条目删起，图片产物一并清理。
    /// maxCount <= 0 直接返回（0 表示不限制）；防御调用方误传参清空全部历史。
    func enforceHistoryLimit(_ maxCount: Int) throws -> Int {
        guard maxCount > 0 else { return 0 }
        let selection = """
        WHERE is_pinned = 0 AND board_id IS NULL AND id IN (
            SELECT id FROM clipboard_items WHERE is_pinned = 0 AND board_id IS NULL
            ORDER BY updated_at DESC, id DESC
            LIMIT -1 OFFSET ?1
        )
        """
        var artifacts: [(String?, String?)] = []
        var deleted = 0
        try connection.transaction {
            artifacts = try fetchArtifacts(whereClause: selection, params: [.int(Int64(maxCount))])
            deleted = try connection.run("DELETE FROM clipboard_items \(selection)", [.int(Int64(maxCount))])
        }
        artifacts.prefix(deleted).forEach { imageStore.remove(imagePath: $0.0, thumbnailPath: $0.1) }
        return deleted
    }

    /// 清扫孤儿图片产物（§48）：数据库不再引用的 Images / Thumbnails 文件。
    /// 两个目录的引用集合分开维护：原图与缩略图同名（同哈希）时互不清除。
    func sweepOrphanArtifacts() throws -> Int {
        let rows = try connection.query(
            "SELECT image_path, thumbnail_path FROM clipboard_items WHERE image_path IS NOT NULL OR thumbnail_path IS NOT NULL") { row in
                (try row.stringOrNil("image_path"), try row.stringOrNil("thumbnail_path"))
            }
        var referencedImages = Set<String>()
        var referencedThumbnails = Set<String>()
        for (imagePath, thumbnailPath) in rows {
            if let imagePath {
                referencedImages.insert(URL(fileURLWithPath: imagePath).lastPathComponent)
            }
            if let thumbnailPath {
                referencedThumbnails.insert(URL(fileURLWithPath: thumbnailPath).lastPathComponent)
            }
        }
        return try imageStore.sweepOrphans(
            referencedImageNames: referencedImages, referencedThumbnailNames: referencedThumbnails)
    }

    // MARK: - Pinboard 文件夹

    func createBoard(name: String, color: String) throws -> Pinboard {
        let maxPosition = try connection.scalarInt("SELECT COALESCE(MAX(position), 0) FROM boards")
        try connection.run(
            "INSERT INTO boards (name, color, position) VALUES (?1, ?2, ?3)",
            [.text(name), .text(color), .int(maxPosition + 1)])
        let id = connection.lastInsertRowID
        return Pinboard(id: id, name: name, color: color, position: Int(maxPosition + 1))
    }

    /// 删除文件夹：其余条目回到默认「剪贴板」（board_id 置空），条目本身不删除。
    /// 已软删除（removed_from_history = 1）的条目移出文件夹后不再可见于任何视图，
    /// 直接物理删除（与 setItemBoard(→nil) 语义一致），图片产物一并清理。
    /// 条目释放与文件夹删除同事务，失败整体回滚。
    func deleteBoard(id: Int64) throws {
        var artifacts: [(String?, String?)] = []
        try connection.transaction {
            artifacts = try fetchArtifacts(whereClause: "WHERE board_id = ?1 AND removed_from_history = 1", params: [.int(id)])
            try connection.run(
                "DELETE FROM clipboard_items WHERE board_id = ?1 AND removed_from_history = 1", [.int(id)])
            try connection.run(
                "UPDATE clipboard_items SET board_id = NULL WHERE board_id = ?1", [.int(id)])
            let changed = try connection.run("DELETE FROM boards WHERE id = ?1", [.int(id)])
            if changed == 0 {
                throw PasteError.notFound(id)
            }
        }
        artifacts.forEach { imageStore.remove(imagePath: $0.0, thumbnailPath: $0.1) }
    }

    /// 全部文件夹（按创建顺序）。
    func listBoards() throws -> [Pinboard] {
        try connection.query("SELECT id, name, color, position FROM boards ORDER BY position, id") { row in
            Pinboard(
                id: try row.int("id"), name: try row.string("name"),
                color: try row.string("color"), position: Int(try row.int("position")))
        }
    }

    /// 把条目移入文件夹（boardId = nil 表示移回默认「剪贴板」）。
    /// 移出文件夹时若条目此前已从历史软删除，将不再出现在任何视图，物理删除之。
    /// UPDATE 与条件物理删除同事务：中途崩溃不会留下「已移出文件夹却仍存在」的幽灵行。
    func setItemBoard(id: Int64, boardId: Int64?) throws {
        if let boardId {
            let exists = try connection.scalarInt("SELECT COUNT(*) FROM boards WHERE id = ?1", [.int(boardId)])
            guard exists > 0 else { throw PasteError.notFound(boardId) }
        }
        var removedArtifacts: [(String?, String?)] = []
        try connection.transaction {
            let changed = try connection.run(
                "UPDATE clipboard_items SET board_id = ?2 WHERE id = ?1",
                [.int(id), .intOrNil(boardId)])
            if changed == 0 {
                throw PasteError.notFound(id)
            }
            if boardId == nil {
                let removed = try connection.scalarInt(
                    "SELECT removed_from_history FROM clipboard_items WHERE id = ?1", [.int(id)]) != 0
                if removed {
                    removedArtifacts = try fetchArtifacts(ids: [id])
                    try connection.run("DELETE FROM clipboard_items WHERE id = ?1", [.int(id)])
                }
            }
        }
        removedArtifacts.forEach { imageStore.remove(imagePath: $0.0, thumbnailPath: $0.1) }
    }

    /// 重命名文件夹（需求：文件夹重命名）。
    func renameBoard(id: Int64, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PasteError.invalidInput("board name must not be empty")
        }
        let changed = try connection.run(
            "UPDATE boards SET name = ?2 WHERE id = ?1", [.int(id), .text(trimmed)])
        if changed == 0 {
            throw PasteError.notFound(id)
        }
    }

    // MARK: - 统计

    func statistics() throws -> ClipboardStatistics {
        let totals = try connection.queryFirst(
            "SELECT COUNT(*), COALESCE(SUM(content_size), 0), COALESCE(SUM(is_pinned), 0) FROM clipboard_items") { row in
                (row.int(0), row.int(1), row.int(2))
            }
        let pairs = try connection.query("SELECT type, COUNT(*) FROM clipboard_items GROUP BY type") { row in
            (ClipboardEntryType(databaseKey: row.string(0)), row.int(1))
        }
        var counts: [ClipboardEntryType: Int] = [:]
        for (type, count) in pairs { counts[type] = Int(count) }
        return ClipboardStatistics(
            totalCount: Int(totals?.0 ?? 0),
            pinnedCount: Int(totals?.2 ?? 0),
            totalContentSize: totals?.1 ?? 0,
            byType: counts)
    }

    // MARK: - 私有：查询构造

    /// 按类型分页列出：置顶在前，其余按最近使用排序。
    /// 默认「剪贴板」视图（boardId = nil）排除已软删除的收藏条目（文件夹视图内仍可见）。
    private func listItems(filter: ClipboardEntryType?, boardId: Int64?, limit: Int, offset: Int) throws -> [ClipboardEntry] {
        var sql = "SELECT * FROM clipboard_items"
        var params: [SQLValue] = []
        var clauses: [String] = []
        if let filter {
            clauses.append("type = ?")
            params.append(.text(filter.databaseKey))
        }
        if let boardId {
            clauses.append("board_id = ?")
            params.append(.int(boardId))
        } else {
            clauses.append("removed_from_history = 0")
        }
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY is_pinned DESC, updated_at DESC, id DESC LIMIT ? OFFSET ?"
        params.append(.int(Int64(limit)))
        params.append(.int(Int64(offset)))
        return try connection.query(sql, params, map: Self.makeEntry)
    }

    /// FTS5 trigram 全文搜索。短语引号转义后整体作为一个 phrase，子串语义。
    /// bm25 越小相关性越高。
    private func searchFullText(_ query: String, filter: ClipboardEntryType?, boardId: Int64?, limit: Int, offset: Int) throws -> [ClipboardEntry] {
        let matchQuery = "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
        var sql = """
        SELECT clipboard_items.* FROM clipboard_items
        JOIN clipboard_fts ON clipboard_fts.rowid = clipboard_items.id
        WHERE clipboard_fts MATCH ?1
        """
        var params: [SQLValue] = [.text(matchQuery)]
        if let filter {
            sql += " AND clipboard_items.type = ?2"
            params.append(.text(filter.databaseKey))
        }
        if let boardId {
            sql += " AND clipboard_items.board_id = ?\(params.count + 1)"
            params.append(.int(boardId))
        } else {
            sql += " AND clipboard_items.removed_from_history = 0"
        }
        sql += " ORDER BY bm25(clipboard_fts), clipboard_items.updated_at DESC, clipboard_items.id DESC LIMIT ? OFFSET ?"
        params.append(.int(Int64(limit)))
        params.append(.int(Int64(offset)))
        return try connection.query(sql, params, map: Self.makeEntry)
    }

    /// 短查询（1–2 字符）的 LIKE 回退，覆盖 title / 正文 / URL / 文件路径 / 来源应用。
    private func searchLike(_ query: String, filter: ClipboardEntryType?, boardId: Int64?, limit: Int, offset: Int) throws -> [ClipboardEntry] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        var sql = """
        SELECT * FROM clipboard_items WHERE (
            COALESCE(title, '') LIKE ?1 ESCAPE '\\'
            OR COALESCE(text_content, '') LIKE ?1 ESCAPE '\\'
            OR COALESCE(url, '') LIKE ?1 ESCAPE '\\'
            OR COALESCE(file_path, '') LIKE ?1 ESCAPE '\\'
            OR COALESCE(source_app_name, '') LIKE ?1 ESCAPE '\\'
        )
        """
        var params: [SQLValue] = [.text("%\(escaped)%")]
        if let filter {
            sql += " AND type = ?2"
            params.append(.text(filter.databaseKey))
        }
        if let boardId {
            sql += " AND board_id = ?\(params.count + 1)"
            params.append(.int(boardId))
        } else {
            sql += " AND removed_from_history = 0"
        }
        sql += " ORDER BY updated_at DESC, id DESC LIMIT ? OFFSET ?"
        params.append(.int(Int64(limit)))
        params.append(.int(Int64(offset)))
        return try connection.query(sql, params, map: Self.makeEntry)
    }

    /// 查询指定 id 列表的图片产物路径，供删除后清理文件（§32）。
    private func fetchArtifacts(ids: [Int64]) throws -> [(String?, String?)] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        return try fetchArtifacts(whereClause: "WHERE id IN (\(placeholders))", params: ids.map { .int($0) })
    }

    private func fetchArtifacts(whereClause: String, params: [SQLValue]) throws -> [(String?, String?)] {
        try connection.query(
            "SELECT image_path, thumbnail_path FROM clipboard_items \(whereClause)", params) { row in
                (try row.stringOrNil("image_path"), try row.stringOrNil("thumbnail_path"))
            }
    }

    private static func makeEntry(_ row: SQLRow) throws -> ClipboardEntry {
        ClipboardEntry(
            id: try row.int("id"),
            itemType: ClipboardEntryType(databaseKey: try row.string("type")),
            createdAt: Date(timeIntervalSince1970: Double(try row.int("created_at")) / 1000),
            updatedAt: Date(timeIntervalSince1970: Double(try row.int("updated_at")) / 1000),
            title: try row.stringOrNil("title"),
            preview: try row.stringOrNil("preview"),
            textContent: try row.stringOrNil("text_content"),
            url: try row.stringOrNil("url"),
            filePath: try row.stringOrNil("file_path"),
            imagePath: try row.stringOrNil("image_path"),
            thumbnailPath: try row.stringOrNil("thumbnail_path"),
            sourceApp: try row.stringOrNil("source_app"),
            sourceAppName: try row.stringOrNil("source_app_name"),
            contentSize: try row.int("content_size"),
            uti: try row.stringOrNil("uti"),
            isPinned: try row.bool("is_pinned"),
            metadata: try row.stringOrNil("metadata"),
            removedFromHistory: try row.bool("removed_from_history"),
            titleIsCustom: try row.bool("title_is_custom"))
    }

    // MARK: - 私有：载荷解析（§16-§21，port of resolve_new_item）

    private struct ResolvedNewItem {
        var effective: NewClipboardEntry
        var contentHash: String
        var contentSize: Int64
    }

    /// 按载荷类别解析：
    /// 1. 图片：哈希基于图片字节，强制 Image 类型；
    /// 2. 文件 / 文件夹：只读元数据不复制本体，类型按实际文件性质判定，
    ///    哈希 = 规范路径 + 大小 + mtime；目录大小为 0；
    /// 3. 文本：走规则分类器细分，URL 规范化到 url 字段（text_content 保留供搜索）。
    private func resolveNewItem(_ entry: NewClipboardEntry) throws -> ResolvedNewItem {
        var effective = entry

        if let source = entry.imageSourcePath {
            effective.itemType = .image
            let url = URL(fileURLWithPath: source)
            // 分块流式哈希：不整读文件进内存（单图上限 50MB，重复捕获路径会反复执行）
            let (hash, byteCount): (String, Int64)
            do {
                (hash, byteCount) = try Self.streamedSHA256(at: url)
            } catch let error as PasteError {
                throw error
            } catch {
                throw PasteError.fileSystem(String(describing: error))
            }
            return ResolvedNewItem(
                effective: effective,
                contentHash: hash,
                contentSize: byteCount)
        }

        if (entry.itemType == .file || entry.itemType == .folder),
           let path = entry.filePath {
            let fileURL = URL(fileURLWithPath: path)
            let fileManager = FileManager.default
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
                throw PasteError.fileSystem("file not accessible: \(path)")
            }
            let isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            let size: Int64 = isDirectory ? 0 : (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let mtimeMillis: Int64 = {
                guard let date = attributes[.modificationDate] as? Date else { return 0 }
                return Int64(date.timeIntervalSince1970 * 1000)
            }()
            // 规范路径（符号链接 / ../ 解析），失败退回原路径
            let canonical = (path as NSString).resolvingSymlinksInPath
            effective.itemType = isDirectory ? .folder : .file
            effective.metadata = Self.withMetadataFlag(entry.metadata, key: "isDirectory", value: isDirectory)
            let hashSource = "file\0\(canonical)\0\(size)\0\(mtimeMillis)"
            return ResolvedNewItem(
                effective: effective,
                contentHash: sha256Hex(Data(hashSource.utf8)),
                contentSize: size)
        }

        // 文本载荷：Text 类型走规则分类器细分；检测到代码语言时写入 metadata.language
        var itemType = entry.itemType
        var metadata = entry.metadata
        if itemType == .text, let text = entry.textContent {
            let classified = classifyText(text)
            if classified != .text {
                itemType = classified
                if let language = detectCodeLanguage(text) {
                    metadata = Self.withLanguage(metadata, language: language)
                }
            }
        }
        effective.itemType = itemType
        effective.metadata = metadata
        // 被识别为 URL 时，把内容规范化到 url 字段
        if itemType == .url, effective.url == nil {
            effective.url = effective.textContent.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let content = effective.textContent ?? effective.url ?? effective.filePath ?? ""
        guard !content.isEmpty else {
            throw PasteError.invalidInput("clipboard item requires non-empty text, url, file_path or image")
        }
        let contentSize = Int64(content.utf8.count)
        return ResolvedNewItem(
            effective: effective,
            contentHash: try hashForItem(content: content),
            contentSize: contentSize)
    }

    // MARK: - 私有：派生字段（port of model.rs derive_title / derive_preview）

    /// 推导标题：URL 取域名，文件取文件名，文本取首个非空行。
    private func deriveTitle(for entry: NewClipboardEntry) -> String? {
        deriveTitle(type: entry.itemType, url: entry.url, filePath: entry.filePath, textContent: entry.textContent)
    }

    private func deriveTitle(type: ClipboardEntryType, url: String?, filePath: String?, textContent: String?) -> String? {
        switch type {
        case .url:
            return url.flatMap(urlHost)
        case .file, .folder:
            return filePath.flatMap(lastPathComponent)
        case .image:
            return nil
        default:
            return textContent.flatMap(firstNonEmptyLine).map { truncateChars($0, 80) }
        }
    }

    /// 推导预览：列表页展示的短文本。
    private func derivePreview(for entry: NewClipboardEntry) -> String? {
        derivePreview(type: entry.itemType, url: entry.url, filePath: entry.filePath, textContent: entry.textContent)
    }

    private func derivePreview(type: ClipboardEntryType, url: String?, filePath: String?, textContent: String?) -> String? {
        switch type {
        case .url:
            return url
        case .file, .folder:
            return filePath
        case .image:
            return nil
        default:
            guard let textContent else { return nil }
            let collapsed = textContent.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return truncateWithEllipsis(collapsed, 280)
        }
    }

    // MARK: - 私有：metadata JSON 操作

    /// 分块流式计算文件 SHA-256 与字节数；哈希结果与整读 sha256Hex 完全一致（dedup 依赖）。
    private static func streamedSHA256(at url: URL) throws -> (hash: String, byteCount: Int64) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PasteError.fileSystem("cannot open image: \(url.path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (hash, total)
    }

    /// 在 metadata JSON 中写入（或覆盖）language 字段；原 metadata 非法时重建对象。
    private static func withLanguage(_ metadata: String?, language: String) -> String {
        var object = metadataJSON(metadata)
        object["language"] = language
        return serializeJSON(object)
    }

    /// 从 metadata JSON 中移除键；原 metadata 非法 / 缺失时原样保留。
    private static func withoutMetadataKey(_ metadata: String?, key: String) -> String? {
        guard let raw = metadata else { return nil }
        guard let data = raw.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return raw }
        object.removeValue(forKey: key)
        return serializeJSON(object)
    }

    /// 在 metadata JSON 中写入布尔标志（原 metadata 非法时重建对象）。
    private static func withMetadataFlag(_ metadata: String?, key: String, value: Bool) -> String {
        var object = metadataJSON(metadata)
        object[key] = value
        return serializeJSON(object)
    }

    private static func metadataJSON(_ metadata: String?) -> [String: Any] {
        guard let metadata,
              let data = metadata.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func serializeJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}


// MARK: - 通用小工具

func nowMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

/// 截断到指定字符数。
private func truncateChars(_ text: String, _ max: Int) -> String {
    String(text.prefix(max))
}

/// 截断到指定字符数并带省略号。
private func truncateWithEllipsis(_ text: String, _ max: Int) -> String {
    if text.count <= max { return text }
    return String(text.prefix(max)) + "…"
}

/// 首个非空行（按行切分并 trim）。
private func firstNonEmptyLine(_ text: String) -> String? {
    text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty }
}

/// URL 取主机名：去 scheme 后取到 / ? # 之前的部分。
private func urlHost(_ url: String) -> String? {
    guard let separatorRange = url.range(of: "://") else { return nil }
    let rest = url[separatorRange.upperBound...]
    let host = rest.prefix { !["/", "?", "#"].contains($0) }
    return host.isEmpty ? nil : String(host)
}

/// 路径取最后一个组件（忽略尾部斜杠）。
private func lastPathComponent(_ path: String) -> String? {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    let component = URL(fileURLWithPath: trimmed).lastPathComponent
    return component.isEmpty || component == "/" ? nil : component
}

extension ClipboardEntryType {
    /// 数据库存储标识（与 Rust ItemType::as_str 一致；未知标识回退 Other 向前兼容）。
    init(databaseKey: String) {
        switch databaseKey {
        case "text": self = .text
        case "url": self = .url
        case "image": self = .image
        case "file": self = .file
        case "folder": self = .folder
        case "rich_text": self = .richText
        case "code": self = .code
        default: self = .other
        }
    }

    var databaseKey: String {
        switch self {
        case .text: "text"
        case .url: "url"
        case .image: "image"
        case .file: "file"
        case .folder: "folder"
        case .richText: "rich_text"
        case .code: "code"
        case .other: "other"
        }
    }
}

extension RetentionPolicy {
    /// 对应保留天数；never 为 nil。
    var retentionDays: Int? {
        switch self {
        case .oneDay: 1
        case .sevenDays: 7
        case .thirtyDays: 30
        case .ninetyDays: 90
        case .never: nil
        }
    }
}
