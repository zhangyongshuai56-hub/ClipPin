import Foundation
import SQLite3

// MARK: - SQLite 参数值

/// 绑定参数 / 行取值的轻量值类型（对齐 Rust 侧 rusqlite::Value 的使用面）。
enum SQLValue {
    case text(String)
    case textOrNil(String?)
    case int(Int64)
    case intOrNil(Int64?)
}

// SQLITE_TRANSIENT：让 SQLite 自行拷贝绑定值的生命周期
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 行访问器

/// 一行查询结果；按列名取值。
struct SQLRow {
    private let handle: OpaquePointer
    private let columnIndex: [String: Int32]

    fileprivate init(handle: OpaquePointer) {
        self.handle = handle
        var index: [String: Int32] = [:]
        let count = sqlite3_column_count(handle)
        for i in 0..<count {
            if let name = sqlite3_column_name(handle, i) {
                index[String(cString: name)] = i
            }
        }
        columnIndex = index
    }

    /// 列缺失一律抛错（schema 漂移 / 列名笔误不该崩溃进程）；
    /// 调用方 map 闭包本身是 throws，错误沿查询路径上抛为 PasteError.database。
    private func assert(_ name: String) throws -> Int32 {
        guard let i = columnIndex[name] else {
            throw PasteError.database("SQL row column not found: \(name)")
        }
        return i
    }

    func int(_ name: String) throws -> Int64 { sqlite3_column_int64(handle, try assert(name)) }

    func int(_ index: Int) -> Int64 { sqlite3_column_int64(handle, Int32(index)) }

    func string(_ index: Int) -> String {
        guard let cString = sqlite3_column_text(handle, Int32(index)) else { return "" }
        return String(cString: cString)
    }

    func intOrNil(_ name: String) throws -> Int64? {
        sqlite3_column_type(handle, try assert(name)) == SQLITE_NULL ? nil : try int(name)
    }

    func string(_ name: String) throws -> String {
        guard let cString = sqlite3_column_text(handle, try assert(name)) else { return "" }
        return String(cString: cString)
    }

    func stringOrNil(_ name: String) throws -> String? {
        sqlite3_column_type(handle, try assert(name)) == SQLITE_NULL ? nil : try string(name)
    }

    func bool(_ name: String) throws -> Bool { try int(name) != 0 }
}

// MARK: - SQLite 连接封装

/// 系统 libsqlite3 的最小封装：单连接、WAL、busy_timeout、事务。
/// 访问由 ClipboardRepository actor 串行化；线程安全交给调用方。
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    /// 连接错误统一映射为 PasteError.database（§82 错误模型）。
    private func fail(_ context: String) -> PasteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return .database("\(context): \(message)")
    }

    /// 打开（或创建）数据库文件，并应用与 Rust 版一致的连接参数。
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let error = fail("open \(path)")
            sqlite3_close_v2(handle)
            handle = nil
            throw error
        }
        // WAL + NORMAL：崩溃不丢已提交事务，写入开销低（§48）
        try run("PRAGMA journal_mode=WAL")
        try run("PRAGMA synchronous=NORMAL")
        try run("PRAGMA busy_timeout=5000")
    }

    /// 内存数据库（自测用）。
    static func inMemory() throws -> SQLiteDatabase {
        try self.init(path: ":memory:")
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: - 基础操作

    /// 执行无结果语句（PRAGMA / UPDATE / DELETE / INSERT），返回受影响行数。
    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw fail("prepare: \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        try bind(params, to: statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            if status == SQLITE_ROW { continue }  // 部分 PRAGMA 返回当前值
            throw fail("step: \(sql)")
        }
        return Int(sqlite3_changes(handle))
    }

    /// 执行多语句批处理（迁移脚本）。单连接下无并发问题。
    func executeBatch(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw PasteError.database(message)
        }
    }

    /// 查询多行。
    func query<T>(_ sql: String, _ params: [SQLValue] = [], map: (SQLRow) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw fail("prepare: \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        try bind(params, to: statement)
        var rows: [T] = []
        while true {
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else {
                throw fail("step: \(sql)")
            }
            if status == SQLITE_DONE { break }
            rows.append(try map(SQLRow(handle: statement)))
        }
        return rows
    }

    /// 查询单行（无结果返回 nil，语义对齐 rusqlite optional()）。
    func queryFirst<T>(_ sql: String, _ params: [SQLValue] = [], map: (SQLRow) throws -> T) throws -> T? {
        try query(sql, params, map: map).first
    }

    /// 单值整数查询（COUNT / SUM / PRAGMA 等）。
    func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        try queryFirst(sql, params) { $0.int(0) } ?? 0
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func userVersion() throws -> Int32 {
        Int32(try scalarInt("PRAGMA user_version"))
    }

    func setUserVersion(_ version: Int32) throws {
        try run("PRAGMA user_version=\(version)")
    }

    /// 事务：body 抛错即回滚，成功才提交。
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try body()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    // MARK: - 绑定

    private func bind(_ params: [SQLValue], to statement: OpaquePointer?) throws {
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text):
                status = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .textOrNil(let text):
                if let text {
                    status = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
                } else {
                    status = sqlite3_bind_null(statement, index)
                }
            case .int(let number):
                status = sqlite3_bind_int64(statement, index, number)
            case .intOrNil(let number):
                if let number {
                    status = sqlite3_bind_int64(statement, index, number)
                } else {
                    status = sqlite3_bind_null(statement, index)
                }
            }
            guard status == SQLITE_OK else {
                throw fail("bind index \(index)")
            }
        }
    }
}
