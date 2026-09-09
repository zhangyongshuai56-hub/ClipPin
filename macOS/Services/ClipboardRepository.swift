import Foundation

/// Core 仓储层（§54、§55）：所有数据库访问经由它，ViewModel 与 UI 不接触 FFI。
/// SQLite 操作都是微秒级同步调用，actor 串行化即可满足需求；Phase 12 再按测量结果优化。
actor ClipboardRepository {
    private let database: PasteDatabase

    init(databasePath: String) throws {
        database = try PasteDatabase.open(path: databasePath)
    }

    /// 内存数据库，仅供 Swift 单元测试。
    init(inMemoryForTesting: Bool) throws {
        database = try PasteDatabase.openInMemory()
    }

    func schemaVersion() -> Int {
        guard let version = try? database.schemaVersion() else { return 0 }
        return Int(version)
    }

    /// 创建条目（Core 自动去重，§17）。
    func create(_ entry: NewClipboardEntry) throws -> ClipboardEntry {
        ClipboardEntry(try database.createItem(newItem: entry.toFfi()))
    }

    func item(id: Int64) throws -> ClipboardEntry {
        ClipboardEntry(try database.getItem(id: id))
    }

    /// 分页列出：置顶在前，其余按最近使用排序。
    /// 分页列出。boardId 为 nil 表示默认「剪贴板」（全部历史）。
    func items(boardId: Int64? = nil, limit: Int = 50, offset: Int = 0) throws -> [ClipboardEntry] {
        try database
            .getItems(filter: nil, boardId: boardId, limit: Int64(limit), offset: Int64(offset))
            .map(ClipboardEntry.init)
    }

    func pinnedItems(limit: Int = 50, offset: Int = 0) throws -> [ClipboardEntry] {
        try database
            .getPinnedItems(limit: Int64(limit), offset: Int64(offset))
            .map(ClipboardEntry.init)
    }

    /// 全文搜索（§29、§30）。
    /// 全文搜索。boardId 为 nil 表示全部。
    func search(_ query: String, boardId: Int64? = nil, limit: Int = 50, offset: Int = 0) throws -> [ClipboardEntry] {
        try database
            .searchItems(query: query, filter: nil, boardId: boardId, limit: Int64(limit), offset: Int64(offset))
            .map(ClipboardEntry.init)
    }

    // MARK: - Pinboard 文件夹

    func boards() throws -> [Pinboard] {
        try database.listBoards().map(Pinboard.init)
    }

    func createBoard(name: String, color: String) throws -> Pinboard {
        Pinboard(try database.createBoard(name: name, color: color))
    }

    func deleteBoard(id: Int64) throws {
        try database.deleteBoard(id: id)
    }

    /// 重命名文件夹。
    func renameBoard(id: Int64, name: String) throws {
        try database.renameBoard(id: id, name: name)
    }

    /// 移入文件夹；nil 表示移回默认「剪贴板」。
    func setItemBoard(id: Int64, boardId: Int64?) throws {
        try database.setItemBoard(id: id, boardId: boardId)
    }

    func delete(id: Int64) throws {
        try database.deleteItem(id: id)
    }

    /// 从「剪贴板」历史移除（需求：删除保留收藏）。
    /// 未收藏条目物理删除；已收藏条目软删除，继续保留在所属文件夹中。
    func removeFromHistory(id: Int64) throws -> ItemRemovalOutcome {
        ItemRemovalOutcome(try database.removeItemFromHistory(id: id))
    }

    /// 编辑文本条目（重分类；与已有记录重复时自动合并）。
    func editTextItem(id: Int64, text: String) throws -> ItemEditOutcome {
        let outcome = try database.editTextItem(id: id, newText: text)
        return ItemEditOutcome(entry: ClipboardEntry(outcome.item), merged: outcome.merged)
    }

    /// 命名条目：标题记为用户自定义，后续内容变更不再覆盖。
    func renameItem(id: Int64, title: String) throws {
        try database.renameItem(id: id, title: title)
    }

    /// 设置「从历史移除」软删除标记（导入备份时还原状态用）。
    func setRemovedFromHistory(id: Int64, removed: Bool) throws {
        try database.setItemRemovedFromHistory(id: id, removed: removed)
    }

    func delete(ids: [Int64]) throws -> Int {
        Int(try database.deleteItems(ids: ids))
    }

    func pin(id: Int64) throws {
        try database.pinItem(id: id)
    }

    func unpin(id: Int64) throws {
        try database.unpinItem(id: id)
    }

    /// 过期清理（§32），返回删除条数。
    func cleanupExpired(retention: RetentionPolicy) throws -> Int {
        Int(try database.cleanupExpired(retention: retention.ffi))
    }

    /// 历史条数上限（§50），返回清理条数。调用方须保证 maxCount > 0（0 表示不限制）。
    func enforceHistoryLimit(_ maxCount: Int) throws -> Int {
        Int(try database.enforceHistoryLimit(maxCount: Int64(maxCount)))
    }

    /// 孤儿图片文件清扫（§48），返回删除数。
    func sweepOrphanArtifacts() throws -> Int {
        Int(try database.sweepOrphanArtifacts())
    }

    func statistics() throws -> ClipboardStatistics {
        ClipboardStatistics(try database.getStatistics())
    }
}
