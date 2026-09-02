import AppKit
import Combine
import Foundation
import Observation

/// 侧栏历史分类（§22）。分类过滤为精确单类型；folder 等类型暂归"全部"显示。
enum ClipboardCategory: String, CaseIterable, Identifiable {
    case all
    case pinned
    case text
    case images
    case links
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .pinned: "置顶"
        case .text: "文本"
        case .images: "图片"
        case .links: "链接"
        case .files: "文件"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "tray.full"
        case .pinned: "pin"
        case .text: "doc.on.doc"
        case .images: "photo"
        case .links: "globe"
        case .files: "folder"
        }
    }

    /// 传给 Core 的类型过滤；nil 表示不过滤。
    var itemTypeFilter: ClipboardEntryType? {
        switch self {
        case .all, .pinned: nil
        case .text: .text
        case .images: .image
        case .links: .url
        case .files: .file
        }
    }
}

/// 剪贴板主界面状态（§56）。只管理列表 / 搜索 / 选择 / 动作，不含 UI 布局。
@MainActor
@Observable
final class ClipboardViewModel {
    // MARK: - 列表状态

    private(set) var entries: [ClipboardEntry] = []
    var selectionID: Int64?
    private(set) var isLoading = false
    private(set) var canLoadMore = false
    var errorMessage: String?
    /// Quick Paste 缺少辅助功能权限时弹出引导（§38）。
    var showAccessibilityPrompt = false

    /// 当前选中的条目。
    var selectedEntry: ClipboardEntry? {
        entries.first { $0.id == selectionID }
    }

    // MARK: - 分类与搜索（§29）

    var category: ClipboardCategory = .all {
        didSet {
            guard oldValue != category else { return }
            Task { await load(reset: true) }
        }
    }

    var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleSearch()
        }
    }

    private var searchTask: Task<Void, Never>?
    private var monitorCancellable: AnyCancellable?
    /// 搜索框聚焦请求计数；SearchBar 观察该值变化后聚焦。
    private(set) var searchFocusRequest = 0

    /// 分页（§58）。
    private let pageSize = 50

    private let repository: ClipboardRepository

    init(repository: ClipboardRepository) {
        self.repository = repository
        // 监听器入库新内容后刷新列表（防抖合并连续捕获）
        monitorCancellable = NotificationCenter.default
            .publisher(for: .clipboardMonitorDidSaveItem)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.load(reset: true) }
            }
    }

    // MARK: - 加载

    /// 首次显示窗口时加载。
    func loadInitial() async {
        await load(reset: true)
    }

    /// 滚动到底部时加载下一页（§58）。
    func loadNextPageIfNeeded() async {
        guard canLoadMore, !isLoading else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let offset = reset ? 0 : entries.count
        do {
            let page: [ClipboardEntry]
            if isSearchActive {
                page = try await repository.search(
                    searchText,
                    type: category.itemTypeFilter,
                    limit: pageSize,
                    offset: offset
                )
            } else if category == .pinned {
                page = try await repository.pinnedItems(limit: pageSize, offset: offset)
            } else {
                page = try await repository.items(
                    type: category.itemTypeFilter,
                    limit: pageSize,
                    offset: offset
                )
            }
            if reset {
                entries = page
            } else {
                entries += page
            }
            canLoadMore = page.count == pageSize
            fixSelection()
        } catch {
            setError(error)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard isSearchActive else {
            // 搜索词清空后立即恢复完整列表
            Task { await load(reset: true) }
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
    }

    /// 当前是否处于搜索状态。
    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func fixSelection() {
        if let selectionID, entries.contains(where: { $0.id == selectionID }) { return }
        selectionID = entries.first?.id
    }

    // MARK: - 键盘导航（§28）

    /// ↑/↓ 移动选择；direction 为 +1（下）/ -1（上）。
    func moveSelection(_ direction: Int) {
        guard !entries.isEmpty else { return }
        let currentIndex = entries.firstIndex { $0.id == selectionID }
        let nextIndex: Int
        switch currentIndex {
        case .some(let index): nextIndex = min(max(index + direction, 0), entries.count - 1)
        case nil: nextIndex = direction >= 0 ? 0 : entries.count - 1
        }
        selectionID = entries[nextIndex].id
    }

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    // MARK: - 动作（§28、§31、§37、§66）

    /// 复制条目到剪贴板（§28 Enter）。
    func copyToPasteboard(_ entry: ClipboardEntry) {
        writeToPasteboard(entry)
    }

    /// Quick Paste（§37、§28 ⌘Enter）：复制 → 隐藏窗口 → 激活之前的应用 → ⌘V → 恢复原剪贴板。
    /// 缺少辅助功能权限时弹出引导，不静默失败。
    func copyAndPaste(_ entry: ClipboardEntry) async {
        guard PasteService.shared.isAccessibilityTrusted else {
            showAccessibilityPrompt = true
            return
        }
        // 先快照用户原剪贴板，粘贴完成后恢复（§37）
        let snapshot = PasteService.shared.captureCurrentContents()
        guard writeToPasteboard(entry) else { return }
        let pasted = await PasteService.shared.pasteToPreviousApp {
            WindowManager.shared.hideClipboardWindow()
        }
        guard pasted else {
            errorMessage = "未能自动粘贴：无法激活之前的应用。"
            return
        }
        // 给目标应用完成粘贴的时间，再恢复用户原剪贴板
        try? await Task.sleep(for: .milliseconds(600))
        PasteService.shared.restore(snapshot)
    }

    @discardableResult
    private func writeToPasteboard(_ entry: ClipboardEntry) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success: Bool
        switch entry.itemType {
        case .text, .code, .richText, .other:
            if let text = entry.textContent {
                success = pasteboard.setString(text, forType: .string)
            } else {
                success = false
            }
        case .url:
            if let url = entry.url {
                success = pasteboard.setString(url, forType: .string)
            } else {
                success = false
            }
        case .file, .folder:
            // §60：文件以 File URL 交给目标 App，不复制文件本体
            if let path = entry.filePath {
                let url = NSURL(fileURLWithPath: path)
                success = pasteboard.writeObjects([url])
            } else {
                success = false
            }
        case .image:
            // 写回图片（TIFF 形式），可粘贴到任何接受图片的应用
            if let path = entry.imagePath, let image = NSImage(contentsOfFile: path) {
                success = pasteboard.writeObjects([image])
            } else {
                success = false
            }
        }
        guard success else {
            errorMessage = "该内容暂不支持复制。"
            return false
        }
        // §18：自家写入不再被监听捕获；同时通过去重 touch 刷新最近使用时间
        ClipboardChangeGate.shared.suppress(pasteboard.changeCount)
        Task {
            _ = try? await repository.create(entry.toNewItem())
            await load(reset: true)
        }
        return true
    }

    func togglePin(_ entry: ClipboardEntry) async {
        do {
            if entry.isPinned {
                try await repository.unpin(id: entry.id)
            } else {
                try await repository.pin(id: entry.id)
            }
            await load(reset: true)
        } catch {
            setError(error)
        }
    }

    func delete(_ entry: ClipboardEntry) async {
        do {
            try await repository.delete(id: entry.id)
            entries.removeAll { $0.id == entry.id }
            fixSelection()
        } catch {
            setError(error)
        }
    }

    /// 在 Finder 中显示文件 / 文件夹（§66）。
    func revealInFinder(_ entry: ClipboardEntry) {
        guard let path = entry.filePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }

    /// 打开链接（§66）。
    func openLink(_ entry: ClipboardEntry) {
        guard let urlText = entry.url ?? entry.textContent, let url = URL(string: urlText) else { return }
        NSWorkspace.shared.open(url)
    }

    private func setError(_ error: Error) {
        if let coreError = error as? AidoPasteError {
            errorMessage = UserFacingError(coreError).errorDescription
        } else {
            errorMessage = error.localizedDescription
        }
    }
}
