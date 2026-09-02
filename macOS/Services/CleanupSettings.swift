import Foundation

/// 清理相关设置（§32、§50）。Phase 11 设置页读写同一批 UserDefaults 键。
enum CleanupSettings {
    static let retentionKey = "autoCleanupRetention"
    static let historyLimitKey = "historyLimit"

    /// 历史保留时长，默认 30 天。
    static var retention: RetentionPolicy {
        let raw = UserDefaults.standard.string(forKey: retentionKey)
        return RetentionPolicy(rawValue: raw ?? "") ?? .thirtyDays
    }

    /// 历史条数上限（§50），默认 1000；0 表示不限制（Unlimited）。
    static var historyLimit: Int {
        guard UserDefaults.standard.object(forKey: historyLimitKey) != nil else {
            return 1000
        }
        return UserDefaults.standard.integer(forKey: historyLimitKey)
    }
}
