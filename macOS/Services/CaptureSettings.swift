import Foundation

/// 捕获相关设置（§49 Clipboard 页、§51）。读取即时生效，Phase 11 设置页读写同键。
enum CaptureSettings {
    static let maxItemSizeKey = "maxItemSize"
    static let saveImagesKey = "saveImages"
    static let saveFilesKey = "saveFiles"
    static let saveURLsKey = "saveURLs"

    /// 单条内容大小上限（§51），默认 50MB。
    static var maxItemSize: Int64 {
        guard UserDefaults.standard.object(forKey: maxItemSizeKey) != nil else {
            return 50 * 1024 * 1024
        }
        return Int64(UserDefaults.standard.integer(forKey: maxItemSizeKey))
    }

    /// 是否保存图片（§49），默认开。
    static var saveImages: Bool {
        UserDefaults.standard.object(forKey: saveImagesKey) as? Bool ?? true
    }

    /// 是否保存文件 / 文件夹（§49），默认开。
    static var saveFiles: Bool {
        UserDefaults.standard.object(forKey: saveFilesKey) as? Bool ?? true
    }

    /// 是否保存 URL 文本（§49），默认开。
    static var saveURLs: Bool {
        UserDefaults.standard.object(forKey: saveURLsKey) as? Bool ?? true
    }

    /// 轻量 URL 判定（与 Rust 分类器同规则），用于 URL 保存开关的过滤。
    static func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https://") {
            return hostPartIsValid(String(trimmed.dropFirst(8)))
        }
        if lower.hasPrefix("http://") {
            return hostPartIsValid(String(trimmed.dropFirst(7)))
        }
        return false
    }

    private static func hostPartIsValid(_ rest: String) -> Bool {
        guard let host = rest.split(whereSeparator: { "/?#".contains($0) }).first else { return false }
        return !host.isEmpty && host.contains(".")
    }
}
