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
        "com.apple.Passwords",
        "org.keepassx.keepassxc",
        "com.bitwarden.desktop",
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

    // MARK: - 管理（§39，设置页调用）

    /// Bundle ID 基本格式校验：字母 / 数字 / 连字符 / 点，至少两段（含一个点）。
    static func isValidBundleID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("."), !trimmed.hasPrefix("."), !trimmed.hasSuffix(".") else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        return trimmed.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// 添加自定义排除项；格式非法或已存在时不写入（调用方先用 isValidBundleID 控制 UI 状态）。
    static func addUser(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidBundleID(trimmed), !all.contains(trimmed) else { return }
        var list = userDefined
        list.insert(trimmed)
        UserDefaults.standard.set(list.sorted(), forKey: storageKey)
    }

    static func removeUser(_ bundleID: String) {
        var list = userDefined
        list.remove(bundleID)
        UserDefaults.standard.set(list.sorted(), forKey: storageKey)
    }
}
