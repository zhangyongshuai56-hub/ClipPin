import Foundation

/// 排除应用（§39）：这些应用处于前台时不记录剪贴板。
/// 第一版按 Bundle ID 匹配；列表管理 UI 在 Phase 11 设置页提供。
enum ExcludedApps {
    static let storageKey = "excludedApps"

    /// 出厂默认：常见密码管理器与钥匙串，避免敏感内容入库。
    static let builtIn: Set<String> = [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword8",
        "com.apple.KeychainAccess",
    ]

    /// 用户自定义列表（持久化于 UserDefaults，Phase 11 提供 UI）。
    static var userDefined: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    static var all: Set<String> {
        builtIn.union(userDefined)
    }

    static func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return all.contains(bundleID)
    }
}
