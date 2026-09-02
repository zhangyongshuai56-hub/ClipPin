import Foundation
import os

/// 应用级 Core 环境（§20、§61）：负责数据库目录与共享仓储的生命周期。
@MainActor
final class CoreStore {
    static let shared = CoreStore()

    private let logger = Logger(subsystem: "com.aidopaste.app", category: "core")

    private(set) var repository: ClipboardRepository?
    private(set) var startupError: UserFacingError?

    /// 数据库目录：~/Library/Application Support/AidoPaste/Database（§20）。
    static var databaseDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AidoPaste/Database", isDirectory: true)
    }

    /// 初始化 Core。失败必须可见：记录 startupError 供设置页展示，不静默降级（§53）。
    func bootstrap() async {
        guard repository == nil else { return }
        do {
            let directory = Self.databaseDirectoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let databasePath = directory.appendingPathComponent("clipboard.db").path
            let repository = try ClipboardRepository(databasePath: databasePath)
            self.repository = repository
            let version = await repository.schemaVersion()
            // 日志不记录剪贴板内容（§84）
            logger.info("rust core ready schema=\(version, privacy: .public)")
        } catch {
            let userFacing: UserFacingError
            if let coreError = error as? AidoPasteError {
                userFacing = UserFacingError(coreError)
            } else {
                userFacing = .storage(error.localizedDescription)
            }
            startupError = userFacing
            logger.error("core bootstrap failed: \(userFacing.errorDescription ?? "unknown", privacy: .public)")
        }
    }
}
