import Foundation

/// Core 仓储层（§54、§55）：所有数据库访问经由它，ViewModel 与 UI 不接触 FFI。
/// SQLite 操作都是微秒级同步调用，actor 串行化即可满足需求；Phase 12 再按测量结果优化。
actor ClipboardRepository {
    private let database: AidoPasteDatabase

    init(databasePath: String) throws {
        database = try AidoPasteDatabase.open(path: databasePath)
    }

    /// 内存数据库，仅供 Swift 单元测试。
    init(inMemoryForTesting: Bool) throws {
        database = try AidoPasteDatabase.openInMemory()
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
    func items(type: ClipboardEntryType? = nil, limit: Int = 50, offset: Int = 0) throws -> [ClipboardEntry] {
        try database
            .getItems(filter: type.map(\.ffi), limit: Int64(limit), offset: Int64(offset))
            .map(ClipboardEntry.init)
    }

    func pinnedItems(limit: Int = 50, offset: Int = 0) throws -> [ClipboardEntry] {
        try database
            .getPinnedItems(limit: Int64(limit), offset: Int64(offset))
            .map(ClipboardEntry.init)
    }

    /// 全文搜索（§29、§30）。
    func search(_ query: String, type: ClipboardEntryType? = nil, limit: Int = 50, offset: Int = 0) throws -> [ClipboardEntry] {
        try database
            .searchItems(query: query, filter: type.map(\.ffi), limit: Int64(limit), offset: Int64(offset))
            .map(ClipboardEntry.init)
    }

    func delete(id: Int64) throws {
        try database.deleteItem(id: id)
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
