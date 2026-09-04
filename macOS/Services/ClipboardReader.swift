import AppKit
import Foundation

/// 从 NSPasteboard 读取统一载荷（§15）。
/// NSPasteboard 线程安全，可在后台线程调用；Rust 侧永远不接触 NSPasteboard。
enum ClipboardReader {
    /// 读取当前剪贴板；无受支持内容或内容为空时返回 nil。
    static func read(sourceApp: String?, sourceAppName: String?) -> ClipboardPayload? {
        let pasteboard = NSPasteboard.general
        guard let types = pasteboard.types, !types.isEmpty else { return nil }

        // 文件 / 文件夹（Phase 8）最先判定：Finder 复制文件时会同时携带
        // file-url、TIFF 图标与路径文本，必须优先命中，避免误存为图片或文本。
        if types.contains(.fileURL), CaptureSettings.saveFiles,
           let payload = readFileURLs(pasteboard, sourceApp: sourceApp, sourceAppName: sourceAppName)
        {
            return payload
        }

        // 文本（含 URL 字符串；类型细分由 Rust 分类器完成；URL 保存开关在此过滤）
        if types.contains(.string),
           let payload = readText(pasteboard, sourceApp: sourceApp, sourceAppName: sourceAppName)
        {
            if case .text(let text) = payload.content,
               CaptureSettings.looksLikeURL(text), !CaptureSettings.saveURLs
            {
                return nil
            }
            return payload
        }

        // 图片（Phase 7）：PNG / TIFF
        if CaptureSettings.saveImages,
           let payload = readImage(pasteboard, sourceApp: sourceApp, sourceAppName: sourceAppName)
        {
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
            .appendingPathComponent("paste-capture-\(UUID().uuidString).\(ext)")
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

    /// §21、§60：只读取 File URL 引用与类型信息，绝不复制文件本体。
    private static func readFileURLs(
        _ pasteboard: NSPasteboard,
        sourceApp: String?,
        sourceAppName: String?
    ) -> ClipboardPayload? {
        guard
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL],
            !urls.isEmpty
        else { return nil }

        let items: [FileItem] = urls.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
            return FileItem(
                url: url,
                isDirectory: values?.isDirectory ?? false,
                uti: values?.contentType?.identifier
            )
        }
        return ClipboardPayload(
            content: .files(items),
            uti: nil,
            sourceApp: sourceApp,
            sourceAppName: sourceAppName,
            capturedAt: Date()
        )
    }
}
