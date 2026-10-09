import Foundation

// MARK: - 导出文档模型（v1；history 为向后兼容的扩展字段）

struct ExportImage: Codable {
    /// 原图字节（base64）。
    var data: String
    /// 扩展名（png / tiff…），导入时决定临时文件后缀。
    var ext: String
}

struct ExportItem: Codable {
    var type: String
    var textContent: String?
    var url: String?
    var uti: String?
    var title: String?
    var titleIsCustom: Bool
    var isPinned: Bool
    /// 捕获时间（毫秒），导入时保留原值。
    var createdAt: Int64
    var metadata: String?
    /// 「从历史移除」软删除标记（收藏保留语义）；旧版本导出文件无此字段视为 false。
    var removedFromHistory: Bool?
    /// 图片载荷（仅图片记录携带）。
    var image: ExportImage?
}

struct ExportBoard: Codable {
    var name: String
    var color: String
    var position: Int64
    var items: [ExportItem]
}

struct ExportDocument: Codable {
    var format: String
    var version: Int
    var exportedAt: Date
    /// 默认「剪贴板」历史（不含文件夹成员）。旧版本导出文件无此字段，解码为 nil。
    var history: [ExportItem]?
    var boards: [ExportBoard]
}

// MARK: - 结果摘要

struct ExportSummary {
    let boardCount: Int
    let itemCount: Int
    /// 本地图片文件缺失而跳过的记录数。
    let skippedBrokenCount: Int

    var message: String {
        var text = "已导出 \(boardCount) 个文件夹、\(itemCount) 条记录"
        if skippedBrokenCount > 0 {
            text += "（\(skippedBrokenCount) 条因本地图片缺失已跳过）"
        }
        return text + "。"
    }
}

struct ImportSummary {
    var boardCount = 0
    var itemCount = 0
    /// 内容与已有记录相同而合并的条数。
    var mergedCount = 0
    /// 文件 / 文件夹类记录（引用路径在本机无效）跳过数。
    var skippedFileCount = 0
    /// 图片数据缺失等损坏记录跳过数。
    var skippedBrokenCount = 0
    /// 读写或数据库错误导致失败的记录数；其余记录继续导入，不做整体中止。
    var failedCount = 0

    var message: String {
        var text = "已导入 \(boardCount) 个文件夹、\(itemCount) 条记录"
        var notes: [String] = []
        if mergedCount > 0 { notes.append("合并 \(mergedCount) 条已有记录") }
        if skippedFileCount > 0 { notes.append("跳过 \(skippedFileCount) 条文件记录（原文件不在这台电脑上）") }
        if skippedBrokenCount > 0 { notes.append("跳过 \(skippedBrokenCount) 条无法解析的记录") }
        if failedCount > 0 { notes.append("失败 \(failedCount) 条") }
        if !notes.isEmpty { text += "（" + notes.joined(separator: "，") + "）" }
        return text + "。"
    }
}

enum LibraryTransferError: LocalizedError {
    case invalidDocument
    case unsupportedVersion(Int)
    case fileTooLarge(Int64)
    case coreUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "不是有效的 Paste 导出文件。"
        case .unsupportedVersion(let version): "导出文件版本过新（v\(version)），请先升级 Paste 再导入。"
        case .fileTooLarge(let size): "导出文件过大（\(size / 1_048_576) MB），超过导入上限。"
        case .coreUnavailable: "数据库尚未就绪，请稍后重试。"
        }
    }
}

extension Notification.Name {
    /// 导入（或批量修改库）完成后发出；已打开的面板据此重新加载。
    static let pasteLibraryDidChange = Notification.Name("com.paste.library.didChange")
}

/// 全库导入 / 导出（需求：文件夹与记录迁移到另一台电脑）。
/// 导出为单文件 JSON（.pasteexport，图片 base64 内嵌），逐条流式写盘，
/// 避免大库（数千张图片）导出时全部 base64 常驻内存；
/// 导入复用仓储 API：create（自动去重）→ rename（命名标记）→ setItemBoard → pin。
enum LibraryTransfer {
    static let formatIdentifier = "paste-export"
    /// 当前导出格式版本。v1 内只做向后兼容的字段追加（可选字段），不递增。
    static let formatVersion = 1
    /// 导入文件大小上限：base64 内嵌图片的合理上界，防止一次性读入超大文件。
    private static let maxImportFileBytes: Int64 = 1 << 30 // 1 GB

    // MARK: - 导出

    static func exportAll(to url: URL, repository: ClipboardRepository) async throws -> ExportSummary {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".pasteexport-tmp-\(UUID().uuidString)")
        // 流式写出器：逐条编码写盘，任意时刻内存里只有一条记录的 base64
        let writer = try JSONStreamWriter(url: temporaryURL)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]

            // 根对象的标量字段手工拼装（formatIdentifier 为常量、version 为整数，
            // 无转义风险；exportedAt 用与导入侧 .iso8601 策略一致的 ISO8601 字符串）
            try writer.writeRaw("{")
            try writer.writeRaw("\"format\":\"\(formatIdentifier)\",\"version\":\(formatVersion),\"exportedAt\":\"\(ISO8601DateFormatter().string(from: Date()))\"")
            try writer.beginArray(key: "history")
            var totalItems = 0
            var skippedBroken = 0
            // 纯历史条目（board_id IS NULL，不含文件夹成员；成员随所在文件夹导出，避免重复）
            let history = try await streamItems(fetch: {
                try await repository.historyItems(limit: $0, offset: $1)
            }, writer: writer, encoder: encoder)
            totalItems += history.exported
            skippedBroken += history.skipped
            try writer.endArray()
            let boards = try await repository.boards()
            try writer.beginArray(key: "boards")
            for board in boards {
                // 文件夹对象：标量字段编码后拼进 items 数组 {"name":...,"position":N,"items":[…]}
                try writer.beginElement()
                let header = String(decoding: try encoder.encode(ExportBoardHeader(
                    name: board.name, color: board.color, position: Int64(board.position))), as: UTF8.self)
                try writer.writeRaw(header.dropLast())
                try writer.writeRaw(",\"items\":")
                try writer.beginArray(key: nil)
                let boardItems = try await streamItems(fetch: {
                    try await repository.items(boardId: board.id, limit: $0, offset: $1)
                }, writer: writer, encoder: encoder)
                totalItems += boardItems.exported
                skippedBroken += boardItems.skipped
                try writer.endArray()
                try writer.writeRaw("}")
            }
            try writer.endArray()
            try writer.writeRaw("}")
            try writer.finish()
            // 全部写完再原子换名；中途失败不留半截导出文件
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: url)
            return ExportSummary(
                boardCount: boards.count,
                itemCount: totalItems,
                skippedBrokenCount: skippedBroken
            )
        } catch {
            writer.abort()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// 分页流式写出一个视图的全部条目；返回（成功导出条数, 损坏跳过条数）。
    /// Core 单次查询有 1000 条硬上限，不分页会静默截断大文件夹。
    private static func streamItems(
        fetch: (Int, Int) async throws -> [ClipboardEntry],
        writer: JSONStreamWriter,
        encoder: JSONEncoder
    ) async throws -> (exported: Int, skipped: Int) {
        let pageSize = 500
        var offset = 0
        var exported = 0
        var skipped = 0
        while true {
            let page = try await fetch(pageSize, offset)
            for entry in page {
                try autoreleasepool {
                    guard let item = exportItem(from: entry) else {
                        skipped += 1
                        return
                    }
                    try writer.writeElement(of: item, encoder: encoder)
                    exported += 1
                }
            }
            if page.count < pageSize { break }
            offset += pageSize
        }
        return (exported, skipped)
    }

    struct ExportBoardHeader: Codable {
        var name: String
        var color: String
        var position: Int64
    }

    private static func exportItem(from entry: ClipboardEntry) -> ExportItem? {
        var image: ExportImage?
        if entry.itemType == .image {
            // 原图字节内嵌；文件缺失视为损坏记录跳过（导出不完整图片没有意义）
            guard let path = entry.imagePath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            else { return nil }
            let ext = (path as NSString).pathExtension.lowercased()
            image = ExportImage(data: data.base64EncodedString(), ext: ext.isEmpty ? "png" : ext)
        }
        return ExportItem(
            type: entry.itemType.wireName,
            textContent: entry.textContent,
            url: entry.url,
            uti: entry.uti,
            title: entry.title,
            titleIsCustom: entry.titleIsCustom,
            isPinned: entry.isPinned,
            createdAt: Int64(entry.createdAt.timeIntervalSince1970 * 1000),
            metadata: entry.metadata,
            removedFromHistory: entry.removedFromHistory,
            image: image
        )
    }

    // MARK: - 导入

    static func importDocument(from url: URL, repository: ClipboardRepository) async throws -> ImportSummary {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int64, size > maxImportFileBytes {
            throw LibraryTransferError.fileTooLarge(size)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: ExportDocument
        do {
            document = try decoder.decode(ExportDocument.self, from: try Data(contentsOf: url))
        } catch {
            throw LibraryTransferError.invalidDocument
        }
        guard document.format == formatIdentifier else {
            throw LibraryTransferError.invalidDocument
        }
        guard document.version <= formatVersion else {
            throw LibraryTransferError.unsupportedVersion(document.version)
        }

        var summary = ImportSummary()
        // 默认「剪贴板」历史（旧版本导出文件无此字段）
        for exportItem in document.history ?? [] {
            await importOne(exportItem, boardID: nil, repository: repository, into: &summary)
        }
        // 同名文件夹合并（决策：重复导入不产生重名文件夹）
        var boardIDByName: [String: Int64] = [:]
        if let existingBoards = try? await repository.boards() {
            for board in existingBoards {
                boardIDByName[board.name] = board.id
            }
        }
        for exportBoard in document.boards {
            let boardID: Int64
            if let existing = boardIDByName[exportBoard.name] {
                boardID = existing
            } else {
                do {
                    let created = try await repository.createBoard(name: exportBoard.name, color: exportBoard.color)
                    boardID = created.id
                    boardIDByName[created.name] = created.id
                } catch {
                    // 建夹失败：该文件夹的记录按失败计，不中止其余文件夹
                    summary.failedCount += exportBoard.items.count
                    continue
                }
            }
            summary.boardCount += 1
            for exportItem in exportBoard.items {
                await importOne(exportItem, boardID: boardID, repository: repository, into: &summary)
            }
        }
        if summary.itemCount > 0 || summary.mergedCount > 0 {
            NotificationCenter.default.post(name: .pasteLibraryDidChange, object: nil)
        }
        return summary
    }

    /// 导入单条；任何一步失败只计一条，不影响其余导入。
    private static func importOne(
        _ item: ExportItem,
        boardID: Int64?,
        repository: ClipboardRepository,
        into summary: inout ImportSummary
    ) async {
        do {
            switch try await importItem(item, boardID: boardID, repository: repository) {
            case .imported(let merged):
                summary.itemCount += 1
                if merged { summary.mergedCount += 1 }
            case .skippedFile:
                summary.skippedFileCount += 1
            case .skippedBroken:
                summary.skippedBrokenCount += 1
            }
        } catch {
            summary.failedCount += 1
        }
    }

    private enum ItemImportResult {
        case imported(merged: Bool)
        case skippedFile
        case skippedBroken
    }

    private static func importItem(
        _ item: ExportItem,
        boardID: Int64?,
        repository: ClipboardRepository
    ) async throws -> ItemImportResult {
        let entryType = ClipboardEntryType(wireName: item.type)
        // 决策：文件 / 文件夹类记录只存引用不存本体，跨机器路径无效，跳过并计数
        if entryType == .file || entryType == .folder {
            return .skippedFile
        }

        var entry = NewClipboardEntry()
        var tempImageURL: URL?
        defer {
            if let tempImageURL {
                try? FileManager.default.removeItem(at: tempImageURL)
            }
        }

        switch entryType {
        case .image:
            guard let image = item.image, let data = Data(base64Encoded: image.data) else {
                return .skippedBroken
            }
            // 导出文件不可信：扩展名白名单校验，防路径穿越写到临时目录之外
            let ext = sanitizedImageExtension(image.ext) ?? "png"
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("paste-import-\(UUID().uuidString).\(ext)")
            do {
                try data.write(to: temp)
            } catch {
                return .skippedBroken
            }
            tempImageURL = temp
            // §16：经临时文件路径交 Core 转存（重算哈希 / 缩略图 / 去重）
            entry.imageSourcePath = temp.path
        case .url:
            let text = item.textContent ?? item.url
            guard item.url?.isEmpty == false || text?.isEmpty == false else {
                return .skippedBroken
            }
            entry.textContent = text
            entry.url = item.url ?? item.textContent
        default:
            guard let text = item.textContent, !text.isEmpty else {
                return .skippedBroken
            }
            entry.textContent = text
        }
        entry.itemType = entryType
        entry.uti = item.uti
        entry.title = item.title
        entry.metadata = item.metadata
        entry.createdAt = Date(timeIntervalSince1970: Double(item.createdAt) / 1000)

        let outcome = try await repository.create(entry)
        let created = outcome.entry
        // 命名标题经 rename 恢复，确保 title_is_custom 标记生效
        if item.titleIsCustom, let title = item.title,
           !title.trimmingCharacters(in: .whitespaces).isEmpty {
            try await repository.renameItem(id: created.id, title: title)
        }
        if let boardID {
            // 已有记录也会被移入导入的文件夹，保证「导出的记录在这台机器出现」
            try await repository.setItemBoard(id: created.id, boardId: boardID)
        }
        if item.isPinned {
            try await repository.pin(id: created.id)
        }
        // 还原「从历史移除」状态：该记录只出现在文件夹里，不重新回到历史列表
        if item.removedFromHistory == true {
            try await repository.setRemovedFromHistory(id: created.id, removed: true)
        }
        // create 显式返回 isNew；旧版本导出文件按原时间戳启发式兜底（已含 createdAt 时不可靠）
        let merged = !outcome.isNew
        return .imported(merged: merged)
    }

    /// 扩展名白名单：1–8 位字母 / 数字。
    private static func sanitizedImageExtension(_ raw: String) -> String? {
        let ext = raw.lowercased()
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return ext
    }
}

// MARK: - 流式 JSON 写出

/// 手工拼装 JSON 文档的流式写出器：数组元素逐个编码、逐个写盘。
/// 只负责结构拼装（逗号 / 方括号），元素文本由 JSONEncoder 产出，转义正确性不受影响。
/// 嵌套数组用状态栈各自追踪「是否首个元素」。
private final class JSONStreamWriter {
    private var handle: FileHandle?
    /// 每个[未关闭数组]一个状态：true = 尚未写过元素（下一元素前不需要逗号）。
    private var firstElementStack: [Bool] = []

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func writeRaw(_ raw: some StringProtocol) throws {
        try handle?.write(contentsOf: Data(String(raw).utf8))
    }

    /// 编码并写出一个完整 JSON 值（对象 / 数组文本）。
    func writeJSON(_ value: some Encodable, encoder: JSONEncoder) throws {
        try writeRaw(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    /// 开始一个键下的数组（自动补成员逗号）；key 为 nil 时由调用方已写出键名。
    func beginArray(key: String?) throws {
        if let key {
            try writeRaw(",\"\(key)\":")
        }
        firstElementStack.append(true)
        try writeRaw("[")
    }

    /// 当前（栈顶）数组中开始一个手工拼装的元素（自动补逗号）。
    func beginElement() throws {
        guard !firstElementStack.isEmpty else { return }
        try writeRaw(firstElementStack[firstElementStack.count - 1] ? "" : ",")
        firstElementStack[firstElementStack.count - 1] = false
    }

    /// 写入当前数组的一个元素（自动补逗号）。
    func writeElement(of value: some Encodable, encoder: JSONEncoder) throws {
        try beginElement()
        try writeJSON(value, encoder: encoder)
    }

    func endArray() throws {
        firstElementStack.removeLast()
        try writeRaw("]")
    }

    func finish() throws {
        try handle?.close()
        handle = nil
    }

    /// 异常路径：关句柄，临时文件由调用方删除。
    func abort() {
        try? handle?.close()
        handle = nil
    }
}

// MARK: - 类型 wire 名称（与 Rust ItemType::as_str 对齐）

extension ClipboardEntryType {
    var wireName: String {
        switch self {
        case .text: "text"
        case .url: "url"
        case .image: "image"
        case .file: "file"
        case .folder: "folder"
        case .richText: "rich_text"
        case .code: "code"
        case .other: "other"
        }
    }

    /// 未知标识（更高版本导出）回退为 other，保证向前兼容。
    init(wireName: String) {
        self = switch wireName {
        case "text": .text
        case "url": .url
        case "image": .image
        case "file": .file
        case "folder": .folder
        case "rich_text": .richText
        case "code": .code
        default: .other
        }
    }
}
