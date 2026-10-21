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
    /// 可撤销的操作提示（删除）：toast 上带「撤销」按钮。
    case undoable(String)
    case failed(String)

    /// VoiceOver 播报文本（视觉 toast 对读屏用户不可感知）。
    var announcementText: String? {
        switch self {
        case .idle: nil
        case .pasting: "正在粘贴"
        case .pasted(let app): "已粘贴到\(app)"
        case .copied: "已复制到剪贴板"
        case .message(let text), .undoable(let text), .failed(let text): text
        }
    }
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
            // 视图语义切换后，待删条目的撤销（按原索引放回）不再成立：立即提交
            flushPendingDeletes()
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
    private var cleanupCancellable: AnyCancellable?
    private var libraryChangeCancellable: AnyCancellable?
    /// 搜索框聚焦请求计数。
    private(set) var searchFocusRequest = 0

    /// 加载代数：防抖搜索与实时刷新并发时，只让最新一次的结果生效。
    private var loadGeneration = 0

    private let logger = Logger(subsystem: "com.paste.app", category: "clipboard-ui")

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
        // 自动清理删除数据后刷新列表（此前清理结果不反映在面板上）
        cleanupCancellable = NotificationCenter.default
            .publisher(for: .cleanupSchedulerDidCleanup)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
        // 导入备份等批量变更后面板立即刷新（此前要等下一次捕获才看到导入结果）
        libraryChangeCancellable = NotificationCenter.default
            .publisher(for: .pasteLibraryDidChange)
            .sink { [weak self] _ in
                Task {
                    await self?.refreshBoards()
                    await self?.refresh()
                }
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

        // 仓储里待删条目尚未移除：偏移量要计入它们，否则翻页会把已展示的
        // 尾部条目再返回一遍（重复 id 破坏 ScrollViewReader 与选中态）。
        // 极端情况下捕获 touch 重排会残余少量误差，属可接受的次级折衷。
        let offset = reset ? 0 : entries.count + pendingDeletes.count
        do {
            var page: [ClipboardEntry]
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
            canLoadMore = page.count == pageSize
            // 待提交删除的条目在仓储里还没删，过滤掉，
            // 否则监听器触发的刷新会把它提前「复活」
            if !pendingDeletes.isEmpty {
                let ids = Set(pendingDeletes.map(\.entry.id))
                page = page.filter { !ids.contains($0.id) }
            }
            if reset {
                entries = page
            } else {
                entries += page
            }
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

    /// Quick Paste 的目标应用名（图例条「↩ 粘贴到 Safari」用）。
    var pasteTargetHint: String? {
        pasteService.previousAppName
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

    /// 注意：文件夹删除只有「延迟 4 秒可撤销」一条路径（deleteBoard(_:)）。
    /// 不要另加 async 立即删除重载——调用点 `Task { await deleteBoard(...) }`
    /// 的重载决议会优先选中 async 版本，让撤销机制静默失效（历史教训）。

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

    /// Enter / 双击执行的默认操作（共用「默认操作」设置）。
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
            write: { writeToPasteboard(entry, forcePlainText: PasteSettings.alwaysPlainText) }
        )
        switch outcome {
        case .success(let targetName):
            // 成功 toast 画在本面板上，面板必须保持可见直到展示完毕
            // （先收面板反馈就没人看得见了）；期间用户有新操作则不再代收面板
            let pasted = OperationFeedback.pasted(targetName ?? "当前应用")
            showFeedback(pasted, autoClearAfter: nil)
            try? await Task.sleep(for: .milliseconds(1200))
            guard feedback == pasted else { return }
            WindowManager.shared.hideClipboardWindow()
            feedback = .idle
        case .accessibilityDenied:
            showAccessibilityPrompt = true
        case .writeFailed:
            // writeToPasteboard 已设置 errorMessage，撤掉「粘贴中」
            showFeedback(.idle, autoClearAfter: nil)
        case .failed:
            showFeedback(.failed("无法粘贴到当前应用"), autoClearAfter: .seconds(3))
        case .inProgress:
            // 已有一次粘贴在编排中：忽略本次触发，不打断进行中的反馈
            break
        }
    }

    /// 操作 B：复制到系统剪贴板（需求 §10；双击同样走这里）。
    /// 不需要 Accessibility，不执行 ⌘V。「始终以纯文本」是粘贴设置，
    /// 不约束复制——否则开启后复制图片会误报“暂不支持复制”。
    func copyToClipboard(_ entry: ClipboardEntry) {
        guard writeToPasteboard(entry, forcePlainText: false) else { return }
        showFeedback(.copied, autoClearAfter: .seconds(1.5))
    }

    private func writeToPasteboard(_ entry: ClipboardEntry, forcePlainText: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        // 先备妥载荷、确认可写，再清板：clearContents 一旦执行，用户当前剪贴板
        // 即被销毁。图片读不出 / 文件已消失 / 纯文本开关下的图片等失败路径
        // 必须在清板前判定，否则一次失败的复制会静默毁掉用户正在使用的内容。
        var write: (() -> Bool)?
        switch entry.itemType {
        case .text, .code, .richText, .url, .other:
            // 纯文本开关：URL / 富文本也只写纯文本
            if let text = entry.textContent ?? entry.url {
                write = { pasteboard.setString(text, forType: .string) }
            }
        case .file, .folder:
            // §60：文件以 File URL 交给目标 App，不复制文件本体
            if let path = entry.filePath,
               FileManager.default.fileExists(atPath: path) {
                let url = NSURL(fileURLWithPath: path)
                write = { pasteboard.writeObjects([url]) }
            }
        case .image:
            // 直接写原始图片字节，保留原格式（NSImage.writeObjects 会统一转成 TIFF）
            if !forcePlainText, let path = entry.imagePath {
                let url = URL(fileURLWithPath: path)
                let type: NSPasteboard.PasteboardType =
                    url.pathExtension.lowercased() == "png" ? .png : .tiff
                if let data = try? Data(contentsOf: url) {
                    write = { pasteboard.setData(data, forType: type) }
                }
            }
        }
        guard let write else {
            errorMessage = "该内容暂不支持复制。"
            return false
        }
        pasteboard.clearContents()
        guard write() else {
            // 载荷已备妥仍写入失败（罕见）；板已被清空，Quick Paste 路径
            // 由 PasteService.runQuickPaste 的 writeFailed 分支恢复快照兜底。
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

    /// 待提交的删除：界面已移除，仓储删除延迟执行，等待可能的「撤销」。
    /// 多次删除累积在同一窗口（滚动 4 秒），撤销一次全部恢复——
    /// 不能因新删除而提前提交旧删除（否则连续 ⌦ 只能撤销最后一条）。
    private struct PendingDelete {
        let entry: ClipboardEntry
        /// 在删除前列表中的位置，撤销时放回原位。
        let index: Int
        let run: () async -> Void
    }

    private var pendingDeletes: [PendingDelete] = []
    private var pendingDeleteTask: Task<Void, Never>?
    /// 待提交的文件夹删除（同一撤销模式；与条目删除互斥挂起）。
    private var pendingBoardDelete: Pinboard?
    private var boardDeleteTask: Task<Void, Never>?

    /// 删除条目（需求：删除保留收藏）。界面立即移除，真正的删除延迟 4 秒提交，
    /// 期间 toast 上可「撤销」——宽恕（易撤销）优于确认框。
    /// 「剪贴板」视图移除收藏条目 = 软删除（历史移除、文件夹保留）；
    /// 文件夹视图内 = 物理删除。
    func delete(_ entry: ClipboardEntry) {
        flushPendingBoardDelete()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries.remove(at: index)
        // 选中落到同位置的下一张：连续 ⌦ 可逐张向后删
        selectionID = entries.isEmpty ? nil : entries[min(index, entries.count - 1)].id
        let boardView = selectedBoardID != nil
        let id = entry.id
        pendingDeletes.append(PendingDelete(entry: entry, index: index) { [weak self] in
            guard let self else { return }
            do {
                if boardView {
                    try await self.repository.delete(id: id)
                } else {
                    _ = try await self.repository.removeFromHistory(id: id)
                }
            } catch {
                self.setError(error)
                await self.refresh()
            }
        })
        restartPendingDeleteTimer()
        showUndoFeedback()
    }

    /// toast「撤销」入口：同一时刻至多一种待撤销操作。
    func undoPendingAction() {
        if pendingBoardDelete != nil {
            undoPendingBoardDelete()
        } else {
            undoPendingDeletes()
        }
    }

    /// 撤销窗口内的全部待删条目：真正的删除尚未发生，按原位放回即可。
    private func undoPendingDeletes() {
        guard !pendingDeletes.isEmpty else { return }
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        let mostRecent = pendingDeletes.last
        // 降序插回：连续 ⌦ 的每条记录都在收缩后的同一 index（删除后选中项落回
        // 同位置），升序插入会把顺序颠倒（[A,B,C,D] 连删 B/C/D 撤销得 [A,D,C,B]）；
        // 降序在同 index 与混合 index 场景均可精确还原删除前的顺序。
        let restores = pendingDeletes.sorted { $0.index > $1.index }
        pendingDeletes.removeAll()
        for pending in restores {
            let index = min(pending.index, entries.count)
            entries.insert(pending.entry, at: index)
        }
        if let mostRecent {
            selectionID = entries.first(where: { $0.id == mostRecent.entry.id })?.id
        }
        feedback = .idle
    }

    /// 提交全部待删条目（撤销窗口结束）。
    private func flushPendingDeletes() {
        guard !pendingDeletes.isEmpty else { return }
        let toCommit = pendingDeletes
        pendingDeletes.removeAll()
        pendingDeleteTask?.cancel()
        pendingDeleteTask = nil
        if case .undoable = feedback { feedback = .idle }
        Task {
            for pending in toCommit { await pending.run() }
        }
    }

    private func restartPendingDeleteTimer() {
        pendingDeleteTask?.cancel()
        pendingDeleteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.flushPendingDeletes()
        }
    }

    private func showUndoFeedback() {
        let noun = selectedBoardID != nil ? "已删除" : "已从剪贴板移除"
        let text = pendingDeletes.count > 1 ? "\(noun) \(pendingDeletes.count) 条" : noun
        showFeedback(.undoable(text), autoClearAfter: nil)
    }

    // MARK: - 文件夹删除（可撤销）

    /// 删除文件夹：chip 立即移除，真正的删除延迟 4 秒提交，期间可撤销。
    /// 提交前的窗口期内文件夹与成员都原封未动，撤销即零成本复原。
    func deleteBoard(_ board: Pinboard) {
        flushPendingDeletes()
        boards.removeAll { $0.id == board.id }
        if selectedBoardID == board.id {
            // didSet 负责切回「剪贴板」并重载列表
            selectedBoardID = nil
        }
        pendingBoardDelete = board
        restartBoardDeleteTimer()
        showFeedback(.undoable("已删除文件夹「\(board.name)」"), autoClearAfter: nil)
    }

    private func undoPendingBoardDelete() {
        guard let board = pendingBoardDelete else { return }
        boardDeleteTask?.cancel()
        boardDeleteTask = nil
        pendingBoardDelete = nil
        if !boards.contains(where: { $0.id == board.id }) {
            boards.append(board)
            boards.sort { $0.position < $1.position }
        }
        feedback = .idle
    }

    private func flushPendingBoardDelete() {
        guard let board = pendingBoardDelete else { return }
        pendingBoardDelete = nil
        boardDeleteTask?.cancel()
        boardDeleteTask = nil
        if case .undoable = feedback { feedback = .idle }
        Task { [weak self] in
            do {
                try await self?.repository.deleteBoard(id: board.id)
            } catch {
                self?.setError(error)
            }
            await self?.refreshBoards()
        }
    }

    private func restartBoardDeleteTimer() {
        boardDeleteTask?.cancel()
        boardDeleteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.flushPendingBoardDelete()
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
        // 撤销模型 = 「撤销提示可见才能撤销」：非撤销反馈出现即提交待删，
        // 不允许 toast 被顶掉后后台还在静默提交的不一致状态
        if case .undoable = feedback {} else {
            flushPendingDeletes()
            flushPendingBoardDelete()
        }
        feedbackResetTask?.cancel()
        self.feedback = feedback
        // VoiceOver 用户感知不到视觉 toast，逐条播报
        if let text = feedback.announcementText {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: NSAttributedString(string: text)]
            )
        }
        guard let autoClearAfter else { return }
        feedbackResetTask = Task {
            try? await Task.sleep(for: autoClearAfter)
            guard !Task.isCancelled, self.feedback == feedback else { return }
            self.feedback = .idle
        }
    }


    private func setError(_ error: Error) {
        if let coreError = error as? PasteError {
            errorMessage = UserFacingError(coreError).errorDescription
        } else {
            errorMessage = error.localizedDescription
        }
    }
}
