import AppKit
import Combine
import Foundation
import Observation
import os

/// 操作反馈状态（需求 §18）：执行后必须有明确反馈，不静默。
enum OperationFeedback: Equatable {
    case idle
    case pasting
    /// 粘贴成功，附带目标应用名（如「已粘贴到 Safari」）。
    case pasted(String)
    case copied
    /// 通用成功提示（命名、编辑、软删除等）。
    case message(String)
    case failed(String)
}

/// 键盘左右导航方向（单行卡片流）。
enum ShelfDirection {
    case left, right
}

/// 剪贴板底部面板状态（§56）。
@MainActor
@Observable
final class ClipboardViewModel {
    // MARK: - 列表状态

    private(set) var entries: [ClipboardEntry] = []
    var selectionID: Int64?
    private(set) var isLoading = false
    private(set) var canLoadMore = false
    var errorMessage: String?
    /// Quick Paste 缺少辅助功能权限时弹出引导（需求 §15）。
    var showAccessibilityPrompt = false
    private(set) var feedback: OperationFeedback = .idle
    private var feedbackResetTask: Task<Void, Never>?

    /// 当前选中的条目。
    var selectedEntry: ClipboardEntry? {
        entries.first { $0.id == selectionID }
    }

    // MARK: - Pinboard 文件夹（需求：创建文件夹收藏剪贴板条目）

    /// 用户创建的文件夹；虚拟「剪贴板」不在其中（selectedBoardID == nil）。
    private(set) var boards: [Pinboard] = []
    /// 当前查看的文件夹；nil = 默认「剪贴板」（全部历史）。
    var selectedBoardID: Int64? {
        didSet {
            guard oldValue != selectedBoardID else { return }
            Task { await load(reset: true) }
        }
    }

    // MARK: - 粘贴默认操作（需求：设置界面可选）
    // 真相来源是 PasteSettings（UserDefaults）；操作时直接读取，VM 不另存副本。

    // MARK: - 搜索

    var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleSearch()
        }
    }

    private var searchTask: Task<Void, Never>?
    private var monitorCancellable: AnyCancellable?
    /// 搜索框聚焦请求计数。
    private(set) var searchFocusRequest = 0

    /// 加载代数：防抖搜索与实时刷新并发时，只让最新一次的结果生效。
    private var loadGeneration = 0

    private let logger = Logger(subsystem: "com.aidopaste.app", category: "clipboard-ui")

    /// 分页（§58）。
    private let pageSize = 50

    private let repository: ClipboardRepository
    private let pasteService: PasteService

    init(repository: ClipboardRepository, pasteService: PasteService) {
        self.repository = repository
        self.pasteService = pasteService
        // 监听器入库新内容后刷新列表（防抖合并连续捕获）
        monitorCancellable = NotificationCenter.default
            .publisher(for: .clipboardMonitorDidSaveItem)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
    }

    // MARK: - 加载

    func loadInitial() async {
        await refreshBoards()
        await load(reset: true)
    }

    func loadNextPageIfNeeded() async {
        guard canLoadMore, !isLoading else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { isLoading = false }

        let offset = reset ? 0 : entries.count
        do {
            let page: [ClipboardEntry]
            if isSearchActive {
                page = try await repository.search(
                    searchText,
                    boardId: selectedBoardID,
                    limit: pageSize,
                    offset: offset
                )
            } else {
                page = try await repository.items(
                    boardId: selectedBoardID,
                    limit: pageSize,
                    offset: offset
                )
            }
            // 过期的加载（期间用户又输入了新词 / 切换了文件夹）直接丢弃
            guard generation == loadGeneration else { return }
            if reset {
                entries = page
            } else {
                entries += page
            }
            canLoadMore = page.count == pageSize
            fixSelection()
        } catch {
            guard generation == loadGeneration else { return }
            setError(error)
        }
    }

    /// 监听器新入库 / 复制 touch 后的刷新。
    func refresh() async {
        await load(reset: true)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        guard isSearchActive else {
            Task { await load(reset: true) }
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
    }

    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func fixSelection() {
        if let selectionID, entries.contains(where: { $0.id == selectionID }) { return }
        selectionID = entries.first?.id
    }

    // MARK: - 左右导航

    func moveInShelf(_ direction: ShelfDirection) {
        guard !entries.isEmpty else { return }
        guard let index = entries.firstIndex(where: { $0.id == selectionID }) else {
            selectionID = entries.first?.id
            return
        }
        let next = index + (direction == .right ? 1 : -1)
        guard entries.indices.contains(next) else { return }
        selectionID = entries[next].id
    }

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    // MARK: - Pinboard

    func refreshBoards() async {
        boards = (try? await repository.boards()) ?? []
    }

    func createBoard(named name: String) async {
        do {
            let board = try await repository.createBoard(name: name, color: "#4F8EF7")
            await refreshBoards()
            selectedBoardID = board.id
        } catch {
            setError(error)
        }
    }

    func deleteBoard(_ board: Pinboard) async {
        do {
            try await repository.deleteBoard(id: board.id)
            if selectedBoardID == board.id {
                selectedBoardID = nil
            }
            await refreshBoards()
            await load(reset: true)
        } catch {
            setError(error)
        }
    }

    /// 重命名文件夹（chip 右键「重命名…」）。
    func renameBoard(_ board: Pinboard, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try await repository.renameBoard(id: board.id, name: trimmed)
            await refreshBoards()
        } catch {
            setError(error)
        }
    }

    /// 把条目移入文件夹；boardID 为 nil 表示移回默认「剪贴板」。
    func move(_ entry: ClipboardEntry, toBoard boardID: Int64?) async {
        do {
            try await repository.setItemBoard(id: entry.id, boardId: boardID)
            await load(reset: true)
        } catch {
            setError(error)
        }
    }

    // MARK: - 动作（需求 §9/§10/§16 两操作严格分离；§17 默认操作可配置）

    /// Enter / 双击执行的默认操作。
    func performDefaultAction(_ entry: ClipboardEntry) async {
        switch PasteSettings.defaultAction {
        case .activeApp:
            await pasteToActiveApplication(entry)
        case .clipboard:
            copyToClipboard(entry)
        }
    }

    /// 操作 A：粘贴到当前活动应用（需求 §9、§12）。
    /// 编排（快照 / 写板 / 激活 / ⌘V / 恢复）收口在 PasteService；
    /// 这里只准备内容、翻译结果为 UI 反馈。
    func pasteToActiveApplication(_ entry: ClipboardEntry) async {
        guard pasteService.isAccessibilityTrusted else {
            showAccessibilityPrompt = true
            return
        }
        showFeedback(.pasting, autoClearAfter: nil)
        let outcome = await pasteService.runQuickPaste(
            write: { writeToPasteboard(entry, forcePlainText: PasteSettings.alwaysPlainText) },
            hideWindow: { WindowManager.shared.hideClipboardWindow() }
        )
        switch outcome {
        case .success(let targetName):
            showFeedback(.pasted(targetName ?? "当前应用"), autoClearAfter: .seconds(1))
            // 让目标应用完成粘贴后再收面板
            try? await Task.sleep(for: .milliseconds(900))
            WindowManager.shared.hideClipboardWindow()
        case .accessibilityDenied:
            showAccessibilityPrompt = true
        case .writeFailed:
            // writeToPasteboard 已设置 errorMessage，撤掉「粘贴中」
            showFeedback(.idle, autoClearAfter: nil)
        case .failed:
            showFeedback(.failed("无法粘贴到当前应用"), autoClearAfter: .seconds(3))
        }
    }

    /// 操作 B：复制到系统剪贴板（需求 §10）。不需要 Accessibility，不执行 ⌘V。
    func copyToClipboard(_ entry: ClipboardEntry) {
        guard writeToPasteboard(entry, forcePlainText: PasteSettings.alwaysPlainText) else { return }
        showFeedback(.copied, autoClearAfter: .seconds(1.5))
    }

    private func writeToPasteboard(_ entry: ClipboardEntry, forcePlainText: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success: Bool
        switch entry.itemType {
        case .text, .code, .richText, .url, .other:
            // 纯文本开关：URL / 富文本也只写纯文本
            if let text = entry.textContent ?? entry.url {
                success = pasteboard.setString(text, forType: .string)
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
            // 直接写原始图片字节，保留原格式（NSImage.writeObjects 会统一转成 TIFF）
            if forcePlainText {
                success = false
            } else if let path = entry.imagePath {
                let url = URL(fileURLWithPath: path)
                let type: NSPasteboard.PasteboardType =
                    url.pathExtension.lowercased() == "png" ? .png : .tiff
                if let data = try? Data(contentsOf: url) {
                    success = pasteboard.setData(data, forType: type)
                } else {
                    success = false
                }
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
            do {
                _ = try await repository.create(entry.toNewItem())
            } catch {
                // touch 失败只影响排序，不提示用户
                logger.error("touch on copy failed: \(error.localizedDescription, privacy: .public)")
            }
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

    /// 删除条目（需求：删除保留收藏）。
    /// 「剪贴板」视图：未收藏条目物理删除，已收藏条目软删除（历史移除、文件夹保留）；
    /// 文件夹视图：物理删除。
    func delete(_ entry: ClipboardEntry) async {
        do {
            if selectedBoardID != nil {
                try await repository.delete(id: entry.id)
            } else {
                let outcome = try await repository.removeFromHistory(id: entry.id)
                if outcome == .keptInBoard {
                    showFeedback(.message("已从剪贴板移除 · 文件夹收藏已保留"), autoClearAfter: .seconds(2.5))
                }
            }
            entries.removeAll { $0.id == entry.id }
            fixSelection()
        } catch {
            setError(error)
        }
    }

    /// 命名条目（⌘R / 右键「重命名…」）。
    func rename(_ entry: ClipboardEntry, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try await repository.renameItem(id: entry.id, title: trimmed)
            await load(reset: true)
            showFeedback(.message("已命名"), autoClearAfter: .seconds(1.2))
        } catch {
            setError(error)
        }
    }

    /// 编辑文本条目内容（⌘E / 右键「编辑内容…」）。
    /// 编辑后与已有记录完全相同时 Core 自动合并，此处给出对应反馈。
    func edit(_ entry: ClipboardEntry, text: String) async {
        do {
            let outcome = try await repository.editTextItem(id: entry.id, text: text)
            await load(reset: true)
            if outcome.merged {
                showFeedback(.message("与已有记录相同，已合并为一条"), autoClearAfter: .seconds(2.5))
            } else {
                showFeedback(.message("内容已更新"), autoClearAfter: .seconds(1.2))
            }
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

    // MARK: - 反馈（需求 §18）

    private func showFeedback(_ feedback: OperationFeedback, autoClearAfter: Duration?) {
        feedbackResetTask?.cancel()
        self.feedback = feedback
        guard let autoClearAfter else { return }
        feedbackResetTask = Task {
            try? await Task.sleep(for: autoClearAfter)
            guard !Task.isCancelled, self.feedback == feedback else { return }
            self.feedback = .idle
        }
    }


    private func setError(_ error: Error) {
        if let coreError = error as? AidoPasteError {
            errorMessage = UserFacingError(coreError).errorDescription
        } else {
            errorMessage = error.localizedDescription
        }
    }
}
