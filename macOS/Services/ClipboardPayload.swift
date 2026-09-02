import Foundation

/// Swift → Rust 的统一剪贴板载荷（§16）。
/// Phase 4 仅实现文本；图片 / 文件载荷在 Phase 7、8 扩展（大图将走临时文件，避免 FFI 多次复制）。
struct ClipboardPayload: Sendable {
    enum Content: Sendable {
        case text(String)
    }

    let content: Content
    let uti: String?
    let sourceApp: String?
    let sourceAppName: String?
    /// 捕获时间（读取到内容的时间）。
    let capturedAt: Date

    /// 单条内容大小上限（§51，默认 50MB；设置项在 Phase 11 接入）。
    static let maxItemSize: Int64 = 50 * 1024 * 1024

    var byteSize: Int64 {
        switch content {
        case .text(let string): Int64(string.utf8.count)
        }
    }

    /// 超限内容不保存（§51：不导致内存暴涨、App 卡死、SQLite 爆炸）。
    var isWithinSizeLimit: Bool {
        byteSize <= Self.maxItemSize
    }

    /// 转为仓储输入。文本统一以 text 类型提交，URL / Code 细分由 Rust 分类器完成（§19）。
    func toNewItem() -> NewClipboardEntry {
        var entry = NewClipboardEntry()
        entry.createdAt = capturedAt
        entry.sourceApp = sourceApp
        entry.sourceAppName = sourceAppName
        entry.uti = uti
        switch content {
        case .text(let string):
            entry.itemType = .text
            entry.textContent = string
        }
        return entry
    }
}
