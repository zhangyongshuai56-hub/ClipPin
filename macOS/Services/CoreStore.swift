import Foundation
import os

/// 应用级 Core 环境（§20、§61）：负责数据库目录与共享仓储的生命周期。
@MainActor
final class CoreStore {
    static let shared = CoreStore()

    private let logger = Logger(subsystem: "com.paste.app", category: "core")

    private(set) var repository: ClipboardRepository?
    private(set) var startupError: UserFacingError?

    /// 数据库目录：~/Library/Application Support/Paste/Database（§20）。
    static var databaseDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Paste/Database", isDirectory: true)
    }

    /// 初始化 Core。失败必须可见：记录 startupError 供设置页展示，不静默降级（§53）。
    /// 建库与 schema 迁移可能耗时（老库升级做全表去重、异常退出后的 WAL 恢复），
    /// 放到主线程之外执行，避免升级后的首次启动冻住 UI。
    func bootstrap() async {
        guard repository == nil else { return }
        do {
            let directory = Self.databaseDirectoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // 剪贴板历史天然含敏感内容：目录 0700、库与 WAL 0600，本机其他用户不可读（尽力而为）
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let databasePath = directory.appendingPathComponent("clipboard.db").path
            let repository = try await Task.detached(priority: .userInitiated) {
                try ClipboardRepository(databasePath: databasePath)
            }.value
            self.repository = repository
            for path in [databasePath, databasePath + "-wal", databasePath + "-shm"] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            let version = await repository.schemaVersion()
            // 日志不记录剪贴板内容（§84）
            logger.info("core ready schema=\(version, privacy: .public)")
        } catch {
            let userFacing: UserFacingError
            if let coreError = error as? PasteError {
                userFacing = UserFacingError(coreError)
            } else {
                userFacing = .storage(error.localizedDescription)
            }
            startupError = userFacing
            logger.error("core bootstrap failed: \(userFacing.errorDescription ?? "unknown", privacy: .public)")
        }
    }
}
