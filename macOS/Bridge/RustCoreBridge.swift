import Foundation

// 说明：UniFFI 生成的 AidoPasteCore.swift 与本文件同属 app target（fileSystemSynchronizedGroups），
// 其类型无需 import 即可直接使用；AidoPasteCoreFFI 头文件经 SWIFT_INCLUDE_PATHS 提供给生成代码。
// MARK: - Swift 领域模型（§55：UI 与 ViewModel 不接触 FFI 类型）

/// 剪贴板条目类型。
enum ClipboardEntryType: Hashable, Sendable, CaseIterable {
    case text
    case url
    case image
    case file
    case folder
    case richText
    case code
    case other

    init(_ ffi: ItemType) {
        switch ffi {
        case .text: self = .text
        case .url: self = .url
        case .image: self = .image
        case .file: self = .file
        case .folder: self = .folder
        case .richText: self = .richText
        case .code: self = .code
        case .other: self = .other
        }
    }

    var ffi: ItemType {
        switch self {
        case .text: .text
        case .url: .url
        case .image: .image
        case .file: .file
        case .folder: .folder
        case .richText: .richText
        case .code: .code
        case .other: .other
        }
    }
}

/// 历史保留时长（§32）。rawValue 持久化于 UserDefaults。
enum RetentionPolicy: String, Hashable, Sendable, CaseIterable {
    case oneDay
    case sevenDays
    case thirtyDays
    case ninetyDays
    case never

    var ffi: Retention {
        switch self {
        case .oneDay: .oneDay
        case .sevenDays: .sevenDays
        case .thirtyDays: .thirtyDays
        case .ninetyDays: .ninetyDays
        case .never: .never
        }
    }
}

/// 已持久化的剪贴板条目。
struct ClipboardEntry: Identifiable, Hashable, Sendable {
    let id: Int64
    let itemType: ClipboardEntryType
    let createdAt: Date
    let updatedAt: Date
    let title: String?
    let preview: String?
    let textContent: String?
    let url: String?
    let filePath: String?
    let imagePath: String?
    let thumbnailPath: String?
    let sourceApp: String?
    let sourceAppName: String?
    let contentSize: Int64
    let uti: String?
    let isPinned: Bool
    /// metadata 原始 JSON；派生信息（如代码语言）按需解析。
    let metadata: String?

    /// 分类器检测到的代码语言（仅 code 类型可能有）。
    var codeLanguage: String? {
        guard let metadata, let data = metadata.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["language"] as? String
    }
}

extension ClipboardEntry {
    /// 从 UniFFI 生成的记录转换（同 target，无需模块限定）。
    init(_ item: ClipboardItem) {
        id = item.id
        itemType = ClipboardEntryType(item.itemType)
        createdAt = Date(timeIntervalSince1970: Double(item.createdAt) / 1000)
        updatedAt = Date(timeIntervalSince1970: Double(item.updatedAt) / 1000)
        title = item.title
        preview = item.preview
        textContent = item.textContent
        url = item.url
        filePath = item.filePath
        imagePath = item.imagePath
        thumbnailPath = item.thumbnailPath
        sourceApp = item.sourceApp
        sourceAppName = item.sourceAppName
        contentSize = item.contentSize
        uti = item.uti
        isPinned = item.isPinned
        metadata = item.metadata
    }

    /// 以既有内容再次构造输入：提交给 Core 后经 content_hash 去重只刷新最近使用时间（§17）。
    func toNewItem() -> NewClipboardEntry {
        var item = NewClipboardEntry()
        item.itemType = itemType
        item.textContent = textContent
        item.url = url
        item.filePath = filePath
        item.imageSourcePath = nil
        item.uti = uti
        item.createdAt = createdAt
        item.metadata = metadata
        return item
    }
}

extension ClipboardEntryType {
    var title: String {
        switch self {
        case .text: "文本"
        case .url: "链接"
        case .image: "图片"
        case .file: "文件"
        case .folder: "文件夹"
        case .richText: "富文本"
        case .code: "代码"
        case .other: "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .text: "doc.on.doc"
        case .url: "globe"
        case .image: "photo"
        case .file: "doc"
        case .folder: "folder"
        case .richText: "doc.richtext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc.plaintext"
        }
    }
}

/// 新条目输入（§16 方向：Swift → Rust）。
struct NewClipboardEntry: Sendable {
    var itemType: ClipboardEntryType = .text
    var textContent: String?
    var url: String?
    var filePath: String?
    /// 图片暂存文件路径（§16：Core 按内容哈希转存后由调用方清理临时文件）。
    var imageSourcePath: String?
    var uti: String?
    var sourceApp: String?
    var sourceAppName: String?
    var title: String?
    var metadata: String?
    /// 捕获时间；nil 表示使用当前时间。
    var createdAt: Date?

    func toFfi() -> NewClipboardItem {
        NewClipboardItem(
            itemType: itemType.ffi,
            textContent: textContent,
            url: url,
            filePath: filePath,
            imageSourcePath: imageSourcePath,
            uti: uti,
            sourceApp: sourceApp,
            sourceAppName: sourceAppName,
            title: title,
            metadata: metadata,
            createdAt: createdAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        )
    }
}

/// 统计信息。
struct ClipboardStatistics: Hashable, Sendable {
    let totalCount: Int
    let pinnedCount: Int
    let totalContentSize: Int64
    let byType: [ClipboardEntryType: Int]

    init(_ stats: Statistics) {
        totalCount = Int(stats.totalCount)
        pinnedCount = Int(stats.pinnedCount)
        totalContentSize = stats.totalContentSize
        var counts: [ClipboardEntryType: Int] = [:]
        for entry in stats.byType {
            counts[ClipboardEntryType(entry.itemType)] = Int(entry.count)
        }
        byType = counts
    }
}

// MARK: - 用户可读错误（§82）

/// 把核心错误转换为用户可读文案；UI 一律展示这里的内容。
enum UserFacingError: LocalizedError, Sendable {
    case database(String)
    case storage(String)
    case invalidInput(String)
    case notFound(Int64)
    case permissionDenied(String)
    case fileSystem(String)
    case migration(String)

    init(_ error: AidoPasteError) {
        switch error {
        case .Database(let message): self = .database(message)
        case .Storage(let message): self = .storage(message)
        case .InvalidInput(let message): self = .invalidInput(message)
        case .NotFound(let id): self = .notFound(id)
        case .PermissionDenied(let message): self = .permissionDenied(message)
        case .FileSystem(let message): self = .fileSystem(message)
        case .Migration(_, let message): self = .migration(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .database: "数据库读写出现问题，请重启应用再试。"
        case .storage: "本地存储出现问题，请检查磁盘空间与权限。"
        case .invalidInput: "该内容无法保存，格式不受支持。"
        case .notFound: "该条目已被删除或不存在。"
        case .permissionDenied: "缺少必要的系统权限，请在系统设置中授权。"
        case .fileSystem: "文件访问出现问题，请确认文件仍然存在。"
        case .migration: "数据库升级失败，原有数据未被修改。"
        }
    }
}
