import Foundation
import os

/// 一次性迁移：AidoPaste → Paste（0.2.0 改名）。
/// 首次启动时执行：整体搬迁数据目录（数据库 + 图片），并从旧的偏好域接管用户设置。
/// 两项迁移都幂等，旧数据不被删除（迁移失败时数据库将在新目录以空历史启动，不影响稳定性）。
enum LegacyMigrator {
    private static let logger = Logger(subsystem: "com.paste.app", category: "migrate")
    /// 改名前的应用标识与数据目录名。
    private static let legacySuiteName = "com.aidopaste.app"
    private static let legacyDirectoryName = "AidoPaste"
    /// 旧偏好域中需要保留的用户设置键。
    private static let preferenceKeys = [
        "appearance", "isPaused", "panelSize",
        "hotKeyCode", "hotKeyModifiers",
        "defaultPasteAction", "pastePlainText",
        "autoCleanupRetention", "historyLimit",
        "saveImages", "saveFiles", "saveURLs", "maxItemSize",
        "excludedApps",
    ]

    static func migrateIfNeeded() {
        migrateSupportDirectory()
        migratePreferences()
    }

    /// ~/Library/Application Support/AidoPaste → Paste（数据库、WAL 与图片整体搬迁）。
    private static func migrateSupportDirectory() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        let new = support.appendingPathComponent("Paste", isDirectory: true)
        guard FileManager.default.fileExists(atPath: old.path),
              !FileManager.default.fileExists(atPath: new.path)
        else { return }
        do {
            try FileManager.default.moveItem(at: old, to: new)
            logger.info("migrated data directory AidoPaste → Paste")
        } catch {
            logger.error("data directory migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 从旧的 UserDefaults 域接管用户设置。
    /// 仅当当前域还没有任何已知设置键（全新安装域）时执行，绝不覆盖用户已改过的值。
    private static func migratePreferences() {
        let standard = UserDefaults.standard
        guard preferenceKeys.allSatisfy({ standard.object(forKey: $0) == nil }) else { return }
        guard let legacy = UserDefaults(suiteName: legacySuiteName) else { return }
        var migrated = 0
        for key in preferenceKeys {
            guard let value = legacy.object(forKey: key) else { continue }
            standard.set(value, forKey: key)
            migrated += 1
        }
        if migrated > 0 {
            logger.info("migrated \(migrated, privacy: .public) preference keys from AidoPaste")
        }
    }
}
