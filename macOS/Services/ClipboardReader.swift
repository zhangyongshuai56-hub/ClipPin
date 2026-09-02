import AppKit
import Foundation

/// 从 NSPasteboard 读取统一载荷（§15）。
/// NSPasteboard 线程安全，可在后台线程调用；Rust 侧永远不接触 NSPasteboard。
enum ClipboardReader {
    /// 读取当前剪贴板；无受支持内容或内容为空时返回 nil。
    static func read(sourceApp: String?, sourceAppName: String?) -> ClipboardPayload? {
        let pasteboard = NSPasteboard.general
        guard let types = pasteboard.types, types.contains(.string),
              let rawText = pasteboard.string(forType: .string)
        else { return nil }

        // 纯空白内容不记录
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // 文本原样保存（首尾空白属于真实内容）；空判断只用于过滤
        return ClipboardPayload(
            content: .text(rawText),
            uti: NSPasteboard.PasteboardType.string.rawValue,
            sourceApp: sourceApp,
            sourceAppName: sourceAppName,
            capturedAt: Date()
        )
    }
}
