import AppKit
import Foundation

/// 从 NSPasteboard 读取统一载荷（§15）。
/// NSPasteboard 线程安全，可在后台线程调用；Rust 侧永远不接触 NSPasteboard。
enum ClipboardReader {
    /// 读取当前剪贴板；无受支持内容或内容为空时返回 nil。
    static func read(sourceApp: String?, sourceAppName: String?) -> ClipboardPayload? {
        let pasteboard = NSPasteboard.general
        guard let types = pasteboard.types, !types.isEmpty else { return nil }

        // 文本优先（含 URL 字符串；类型细分由 Rust 分类器完成）
        if types.contains(.string), let payload = readText(pasteboard, sourceApp: sourceApp, sourceAppName: sourceAppName) {
            return payload
        }

        // 图片（Phase 7）：PNG / TIFF。
        // Finder 复制文件时也会带 TIFF（文件图标），必须排除，留待 Phase 8 文件支持处理。
        if !types.contains(.fileURL), let payload = readImage(pasteboard, sourceApp: sourceApp, sourceAppName: sourceAppName) {
            return payload
        }

        return nil
    }

    private static func readText(
        _ pasteboard: NSPasteboard,
        sourceApp: String?,
        sourceAppName: String?
    ) -> ClipboardPayload? {
        guard let rawText = pasteboard.string(forType: .string),
              !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        // 文本原样保存（首尾空白属于真实内容）；空判断只用于过滤
        return ClipboardPayload(
            content: .text(rawText),
            uti: NSPasteboard.PasteboardType.string.rawValue,
            sourceApp: sourceApp,
            sourceAppName: sourceAppName,
            capturedAt: Date()
        )
    }

    /// §16：把图片字节写入临时文件，仅传路径给 Core。
    private static func readImage(
        _ pasteboard: NSPasteboard,
        sourceApp: String?,
        sourceAppName: String?
    ) -> ClipboardPayload? {
        let pngData = pasteboard.data(forType: .png)
        let imageData = pngData ?? pasteboard.data(forType: .tiff)
        guard let imageData, !imageData.isEmpty else { return nil }

        let ext = pngData != nil ? "png" : "tiff"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aidopaste-capture-\(UUID().uuidString).\(ext)")
        do {
            try imageData.write(to: tempURL)
        } catch {
            return nil
        }
        return ClipboardPayload(
            content: .image(tempFileURL: tempURL),
            uti: pngData != nil ? "public.png" : "public.tiff",
            sourceApp: sourceApp,
            sourceAppName: sourceAppName,
            capturedAt: Date()
        )
    }
}
