import Foundation

// MARK: - Swift 领域模型（§55：UI 与 ViewModel 不接触存储层类型）
// 原生 Swift 实现：无 FFI；存储层（PasteDatabase）直接产出 / 消费这些类型。

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

/// 历史保留时长（§32）。rawValue 持久化于 UserDefaults。
enum RetentionPolicy: String, Hashable, Sendable, CaseIterable, Identifiable {
    case oneDay
    case sevenDays
    case thirtyDays
    case ninetyDays
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneDay: "1 天"
        case .sevenDays: "7 天"
        case .thirtyDays: "30 天"
        case .ninetyDays: "90 天"
        case .never: "永不"
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
    /// 已从「剪贴板」历史软删除；收藏条目保留在文件夹中。
    let removedFromHistory: Bool
    /// 标题由用户命名，内容变更不覆盖。
    let titleIsCustom: Bool

    /// 分类器检测到的代码语言（仅 code 类型可能有）。
    var codeLanguage: String? {
        guard let metadata, let data = metadata.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["language"] as? String
    }

    /// 以既有内容再次构造输入：提交给存储层后经 content_hash 去重只刷新最近使用时间（§17）。
    func toNewItem() -> NewClipboardEntry {
        var item = NewClipboardEntry()
        item.itemType = itemType
        item.textContent = textContent
        item.url = url
        item.filePath = filePath
        // 存储层校验要求至少一种载荷；图片条目传已存原图路径，
        // 存储层按图片字节重算哈希即可命中已有条目走去重 touch（不会重复转存）
        item.imageSourcePath = itemType == .image ? imagePath : nil
        item.uti = uti
        item.createdAt = createdAt
        item.metadata = metadata
        return item
    }

    /// 仅文本类记录可编辑内容；图片 / 文件不支持。
    var isTextEditable: Bool {
        switch itemType {
        case .text, .code, .url, .richText, .other: true
        case .image, .file, .folder: false
        }
    }
}

/// 从「剪贴板」历史移除条目的结果。
enum ItemRemovalOutcome {
    /// 未收藏：已物理删除。
    case deleted
    /// 已收藏：软删除，条目继续保留在所属文件夹中。
    case keptInBoard
}

/// 编辑文本条目的结果。
struct ItemEditOutcome {
    /// 编辑后（或合并目标）的条目。
    let entry: ClipboardEntry
    /// 编辑后内容与库中已有记录相同，已合并为一条。
    let merged: Bool
}

/// 创建条目的结果：entry 为库中最终生效的行（去重命中时是已存在的记录）。
struct CreateItemOutcome {
    let entry: ClipboardEntry
    /// true = 新插入；false = 命中同 content_hash 的已有记录（仅 touch）。
    let isNew: Bool
}

/// 新条目输入（§16 方向：UI → 存储层）。
struct NewClipboardEntry: Sendable {
    var itemType: ClipboardEntryType = .text
    var textContent: String?
    var url: String?
    var filePath: String?
    /// 图片暂存文件路径（§16：存储层按内容哈希转存后由调用方清理临时文件）。
    var imageSourcePath: String?
    var uti: String?
    var sourceApp: String?
    var sourceAppName: String?
    var title: String?
    var metadata: String?
    /// 捕获时间；nil 表示使用当前时间。
    var createdAt: Date?
}

/// 统计信息。
struct ClipboardStatistics: Hashable, Sendable {
    let totalCount: Int
    let pinnedCount: Int
    let totalContentSize: Int64
    let byType: [ClipboardEntryType: Int]
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

    init(_ error: PasteError) {
        switch error {
        case .database(let message): self = .database(message)
        case .storage(let message): self = .storage(message)
        case .invalidInput(let message): self = .invalidInput(message)
        case .notFound(let id): self = .notFound(id)
        case .permissionDenied(let message): self = .permissionDenied(message)
        case .fileSystem(let message): self = .fileSystem(message)
        case .migration(let target, let message): self = .migration("schema v\(target): \(message)")
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

// MARK: - Pinboard 文件夹与粘贴设置

/// Pinboard 文件夹（用户创建，用于收藏组织剪贴板条目）。
struct Pinboard: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let color: String
    let position: Int
}

/// 粘贴项目默认操作（需求：设置界面可选）。
enum DefaultPasteAction: String, CaseIterable, Sendable {
    case activeApp
    case clipboard

    var title: String {
        switch self {
        case .activeApp: "到当前活动应用"
        case .clipboard: "到剪贴板"
        }
    }

    var detail: String {
        switch self {
        case .activeApp: "将选定的项目直接粘贴到您当前正在使用的应用程序中。"
        case .clipboard: "将选定的项目复制到系统剪贴板，以便稍后手动粘贴。"
        }
    }
}

/// 粘贴项目设置（需求：默认操作 + 纯文本开关）。
/// 读取经这里；写入走 SettingsView 的 @AppStorage（同一个 UserDefaults 键），
/// 两侧共享键名，不另设 setter，避免双份真相。
enum PasteSettings {
    static let defaultActionKey = "defaultPasteAction"
    static let plainTextKey = "pastePlainText"

    /// Enter 与双击卡片共用的默认操作，默认粘贴到当前活动应用。
    static var defaultAction: DefaultPasteAction {
        DefaultPasteAction(rawValue: UserDefaults.standard.string(forKey: defaultActionKey) ?? "")
            ?? .activeApp
    }

    /// 始终以纯文本粘贴。
    static var alwaysPlainText: Bool {
        UserDefaults.standard.bool(forKey: plainTextKey)
    }
}
