import Foundation

/// Swift → Rust 的统一剪贴板载荷（§16）。
/// 文本直接携带内容；图片按 §16 落临时文件、只传路径过 FFI，避免大块二进制多次复制。
struct ClipboardPayload: Sendable {
    enum Content: Sendable {
        case text(String)
        /// 图片暂存文件；Core 转存后由 Swift 负责删除临时文件。
        case image(tempFileURL: URL)
        // TODO(Phase 8): file([URL])
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
        case .text(let string):
            return Int64(string.utf8.count)
        case .image(let tempFileURL):
            let attributes = try? FileManager.default.attributesOfItem(atPath: tempFileURL.path)
            return (attributes?[.size] as? Int64) ?? 0
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
        case .image(let tempFileURL):
            entry.itemType = .image
            entry.imageSourcePath = tempFileURL.path
        }
        return entry
    }

    /// 图片载荷处理完毕后清理临时文件；其余载荷无副作用。
    func cleanupTemporaryFiles() {
        if case .image(let tempFileURL) = content {
            try? FileManager.default.removeItem(at: tempFileURL)
        }
    }
}
