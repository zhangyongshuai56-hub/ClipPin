import Foundation

/// 清理相关设置（§32、§50）。Phase 11 设置页读写同一批 UserDefaults 键。
enum CleanupSettings {
    static let retentionKey = "autoCleanupRetention"
    static let historyLimitKey = "historyLimit"
    static let intervalValueKey = "cleanupIntervalValue"
    static let intervalUnitKey = "cleanupIntervalUnit"

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

    // MARK: - 清理执行频率（数值 + 单位，用户可自定义）

    /// 清理执行周期单位。
    enum IntervalUnit: String, CaseIterable {
        case minutes
        case hours
        case days

        var title: String {
            switch self {
            case .minutes: "分钟"
            case .hours: "小时"
            case .days: "天"
            }
        }

        /// 换算为分钟；按单位给出合法数值上限。
        var minutesPerUnit: Int {
            switch self {
            case .minutes: 1
            case .hours: 60
            case .days: 24 * 60
            }
        }

        var maxValue: Int {
            switch self {
            case .minutes: 59
            case .hours: 23
            case .days: 365
            }
        }
    }

    /// 频率数值，默认 1；随单位钳制在 1...maxValue。
    static var intervalValue: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: intervalValueKey) != nil else {
            return 1
        }
        let value = defaults.integer(forKey: intervalValueKey)
        let unit = intervalUnit
        return min(max(value, 1), unit.maxValue)
    }

    /// 频率单位，默认小时。
    static var intervalUnit: IntervalUnit {
        IntervalUnit(rawValue: UserDefaults.standard.string(forKey: intervalUnitKey) ?? "") ?? .hours
    }

    /// 清理执行周期（分钟），默认 1 小时。
    static var intervalMinutes: Int {
        intervalValue * intervalUnit.minutesPerUnit
    }

    static func setInterval(value: Int, unit: IntervalUnit) {
        let defaults = UserDefaults.standard
        defaults.set(unit.rawValue, forKey: intervalUnitKey)
        defaults.set(min(max(value, 1), unit.maxValue), forKey: intervalValueKey)
    }
}
