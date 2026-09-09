import Foundation

// MARK: - 导出文档模型（v1）

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

    var message: String {
        var text = "已导入 \(boardCount) 个文件夹、\(itemCount) 条记录"
        var notes: [String] = []
        if mergedCount > 0 { notes.append("合并 \(mergedCount) 条已有记录") }
        if skippedFileCount > 0 { notes.append("跳过 \(skippedFileCount) 条文件记录（原文件不在这台电脑上）") }
        if skippedBrokenCount > 0 { notes.append("跳过 \(skippedBrokenCount) 条无法解析的记录") }
        if !notes.isEmpty { text += "（" + notes.joined(separator: "，") + "）" }
        return text + "。"
    }
}

enum LibraryTransferError: LocalizedError {
    case invalidDocument
    case coreUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "不是有效的 Paste 导出文件。"
        case .coreUnavailable: "数据库尚未就绪，请稍后重试。"
        }
    }
}

/// 全库导入 / 导出（需求：文件夹与记录迁移到另一台电脑）。
/// 导出为单文件 JSON（.pasteexport，图片 base64 内嵌）；
/// 导入复用仓储 API：create（自动去重）→ rename（命名标记）→ setItemBoard → pin。
enum LibraryTransfer {
    static let formatIdentifier = "paste-export"

    // MARK: - 导出

    static func exportAll(to url: URL, repository: ClipboardRepository) async throws -> ExportSummary {
        let boards = try await repository.boards()
        var exportBoards: [ExportBoard] = []
        var totalItems = 0
        var skippedBroken = 0
        for board in boards {
            // 分页读取：Core 单次查询有 1000 条硬上限，不分页会静默截断大文件夹
            var items: [ClipboardEntry] = []
            let pageSize = 500
            var offset = 0
            while true {
                let page = try await repository.items(boardId: board.id, limit: pageSize, offset: offset)
                items.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += pageSize
            }
            var exportItems: [ExportItem] = []
            for entry in items {
                if let item = exportItem(from: entry) {
                    exportItems.append(item)
                    totalItems += 1
                } else {
                    skippedBroken += 1
                }
            }
            exportBoards.append(ExportBoard(
                name: board.name,
                color: board.color,
                position: Int64(board.position),
                items: exportItems
            ))
        }
        let document = ExportDocument(
            format: formatIdentifier,
            version: 1,
            exportedAt: Date(),
            boards: exportBoards
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
        return ExportSummary(
            boardCount: boards.count,
            itemCount: totalItems,
            skippedBrokenCount: skippedBroken
        )
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

        var summary = ImportSummary()
        // 同名文件夹合并（决策：重复导入不产生重名文件夹）
        var boardIDByName: [String: Int64] = [:]
        for board in try await repository.boards() {
            boardIDByName[board.name] = board.id
        }
        for exportBoard in document.boards {
            let boardID: Int64
            if let existing = boardIDByName[exportBoard.name] {
                boardID = existing
            } else {
                let created = try await repository.createBoard(name: exportBoard.name, color: exportBoard.color)
                boardID = created.id
                boardIDByName[created.name] = created.id
            }
            summary.boardCount += 1
            for exportItem in exportBoard.items {
                switch try await importItem(exportItem, boardID: boardID, repository: repository) {
                case .imported(let merged):
                    summary.itemCount += 1
                    if merged { summary.mergedCount += 1 }
                case .skippedFile:
                    summary.skippedFileCount += 1
                case .skippedBroken:
                    summary.skippedBrokenCount += 1
                }
            }
        }
        return summary
    }

    private enum ItemImportResult {
        case imported(merged: Bool)
        case skippedFile
        case skippedBroken
    }

    private static func importItem(
        _ item: ExportItem,
        boardID: Int64,
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
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("paste-import-\(UUID().uuidString).\(image.ext)")
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

        let created = try await repository.create(entry)
        // 命名标题经 rename 恢复，确保 title_is_custom 标记生效
        if item.titleIsCustom, let title = item.title,
           !title.trimmingCharacters(in: .whitespaces).isEmpty {
            try await repository.renameItem(id: created.id, title: title)
        }
        // 已有记录也会被移入导入的文件夹，保证「导出的记录在这台机器出现」
        try await repository.setItemBoard(id: created.id, boardId: boardID)
        if item.isPinned {
            try await repository.pin(id: created.id)
        }
        // 还原「从历史移除」状态：该记录只出现在文件夹里，不重新回到历史列表
        if item.removedFromHistory == true {
            try await repository.setRemovedFromHistory(id: created.id, removed: true)
        }
        // create 对已存在内容只 touch（保留其原 created_at）；
        // 返回的 created_at 与导出值不一致 ⇒ 命中了已有记录（合并）
        let merged = Int64(created.createdAt.timeIntervalSince1970 * 1000) != item.createdAt
        return .imported(merged: merged)
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
