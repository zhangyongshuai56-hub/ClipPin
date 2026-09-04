import AppKit
import SwiftUI

/// 剪贴板底部快速操作面板（需求 §20，参考 Paste 界面）：
/// 顶部栏（搜索按钮 + Pinboard 文件夹 chips + 新建）→ 单行卡片流 → 快捷键提示条。
struct ClipboardView: View {
    @State private var viewModel: ClipboardViewModel
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    /// 键盘事件监听（§28、需求 §8/§19）。
    @State private var keyMonitor: Any?
    /// 搜索模式：点击 🔍 后展开输入框（需求：搜索精简为按钮）。
    @State private var isSearching = false
    /// 新建文件夹弹窗。
    @State private var isCreatingBoard = false
    @State private var newBoardName = ""

    init(viewModel: ClipboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            shelfArea
        }
        .preferredColorScheme(appearance.colorScheme)
        .task {
            await viewModel.loadInitial()
            viewModel.requestSearchFocus()
        }
        .onAppear { installKeyboardMonitor() }
        .onDisappear { removeKeyboardMonitor() }
        .overlay(alignment: .topTrailing) {
            if viewModel.feedback != .idle {
                FeedbackToast(feedback: viewModel.feedback)
                    .padding(.top, 58)
                    .padding(.trailing, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewModel.feedback)
        .alert("新建文件夹", isPresented: $isCreatingBoard) {
            TextField("文件夹名称", text: $newBoardName)
            Button("创建") {
                let name = newBoardName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await viewModel.createBoard(named: name) }
                newBoardName = ""
            }
            Button("取消", role: .cancel) { newBoardName = "" }
        } message: {
            Text("创建后可把剪贴板条目收藏到这个文件夹。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert(
            "需要辅助功能权限",
            isPresented: Binding(
                get: { viewModel.showAccessibilityPrompt },
                set: { viewModel.showAccessibilityPrompt = $0 }
            )
        ) {
            Button("打开系统设置") {
                PasteService.shared.openAccessibilitySettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("自动粘贴需要「辅助功能」权限。授权后重新按 ↩ 即可粘贴。")
        }
    }

    // MARK: - 顶部栏（需求：搜索精简为按钮 + Pinboard chips）

    private var topBar: some View {
        HStack(spacing: 8) {
            if isSearching {
                SearchField(viewModel: viewModel) {
                    isSearching = false
                }
            } else {
                Button {
                    isSearching = true
                    viewModel.requestSearchFocus()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
                .keyboardShortcut("f", modifiers: .command)
            }

            boardChips

            Spacer(minLength: 0)

            Button {
                isCreatingBoard = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建文件夹")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// 板 chips：默认「剪贴板」+ 用户创建的文件夹。
    private var boardChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                boardChip(
                    title: "剪贴板",
                    color: nil,
                    isSelected: viewModel.selectedBoardID == nil,
                    boardID: nil
                )
                ForEach(viewModel.boards) { board in
                    boardChip(
                        title: board.name,
                        color: Color(hex: board.color),
                        isSelected: viewModel.selectedBoardID == board.id,
                        boardID: board.id
                    )
                }
            }
        }
        .scrollDisabled(viewModel.boards.count < 3)
    }

    private func boardChip(title: String, color: Color?, isSelected: Bool, boardID: Int64?) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color ?? Color.accentColor)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
            in: Capsule()
        )
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.75))
        .contentShape(Capsule())
        .onTapGesture { viewModel.selectedBoardID = boardID }
        .contextMenu {
            if boardID != nil {
                Button("删除文件夹", role: .destructive) {
                    if let board = viewModel.boards.first(where: { $0.id == boardID }) {
                        Task { await viewModel.deleteBoard(board) }
                    }
                }
            }
        }
        .accessibilityLabel("\(title)文件夹")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 卡片流（需求 §2：单行横向，参考 Paste）

    private var shelfArea: some View {
        Group {
            if viewModel.entries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(viewModel.entries) { entry in
                                card(entry)
                            }
                            if viewModel.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 60)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: viewModel.selectionID) { _, newID in
                        guard let newID else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func card(_ entry: ClipboardEntry) -> some View {
        ClipboardCard(entry: entry, isSelected: viewModel.selectionID == entry.id)
            .id(entry.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // 双击执行默认操作（需求 §8、§17）
                Task { await viewModel.performDefaultAction(entry) }
            }
            .onTapGesture {
                viewModel.selectionID = entry.id
            }
            .contextMenu { contextMenu(for: entry) }
            // §36：拖拽导出
            .onDrag { dragProvider(for: entry) }
            .onAppear {
                if entry.id == viewModel.entries.last?.id {
                    Task { await viewModel.loadNextPageIfNeeded() }
                }
            }
    }

    /// 右键菜单（需求 §9/§10/§66 + 文件夹收藏）。
    @ViewBuilder
    private func contextMenu(for entry: ClipboardEntry) -> some View {
        Button("粘贴到当前应用") {
            Task { await viewModel.pasteToActiveApplication(entry) }
        }
        Button("复制到剪贴板") { viewModel.copyToClipboard(entry) }
        Divider()
        if let currentBoard = viewModel.selectedBoardID {
            Button("移出当前文件夹") {
                Task { await viewModel.move(entry, toBoard: nil) }
            }
        }
        Menu("移入文件夹") {
            ForEach(viewModel.boards) { board in
                Button(board.name) {
                    Task { await viewModel.move(entry, toBoard: board.id) }
                }
            }
            if viewModel.boards.isEmpty {
                Text("暂无文件夹，点 + 创建")
            }
        }
        Divider()
        Button("在 Finder 中显示") { viewModel.revealInFinder(entry) }
            .disabled(entry.itemType != .file && entry.itemType != .folder)
        Button("打开链接") { viewModel.openLink(entry) }
            .disabled(entry.itemType != .url)
        Divider()
        Button("删除", role: .destructive) {
            Task { await viewModel.delete(entry) }
        }
    }

    /// 拖拽数据源（§36、§60）：文件给 File URL、图片给图像对象、文本给字符串。
    private func dragProvider(for entry: ClipboardEntry) -> NSItemProvider {
        switch entry.itemType {
        case .image:
            if let path = entry.imagePath, let image = NSImage(contentsOfFile: path) {
                return NSItemProvider(object: image)
            }
        case .file, .folder:
            if let path = entry.filePath {
                return NSItemProvider(object: NSURL(fileURLWithPath: path))
            }
        case .url:
            if let urlText = entry.url, let url = URL(string: urlText) {
                return NSItemProvider(object: url as NSURL)
            }
        default:
            if let text = entry.textContent ?? entry.preview {
                return NSItemProvider(object: text as NSString)
            }
        }
        return NSItemProvider()
    }

    // MARK: - 空状态（§52）

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isSearchActive {
            ContentUnavailableView.search(text: viewModel.searchText)
        } else if viewModel.selectedBoardID != nil {
            ContentUnavailableView {
                Label("文件夹是空的", systemImage: "folder")
            } description: {
                Text("右键点击剪贴板条目，选择「移入文件夹」即可收藏到这里。")
            }
        } else {
            ContentUnavailableView {
                Label("还没有剪贴板记录", systemImage: "doc.on.clipboard")
            } description: {
                Text("复制一些文字、图片或文件，它们会自动出现在这里。")
            }
        }
    }

    // MARK: - 键盘（§28、需求 §19）

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handleKeyDown)
    }

    private func removeKeyboardMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let window = NSApp.keyWindow, window is ClipboardWindow else { return event }

        let commandPressed = event.modifierFlags.contains(.command)
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()

        switch event.keyCode {
        case 123: // ←
            viewModel.moveInShelf(.left)
            return nil
        case 124: // →
            viewModel.moveInShelf(.right)
            return nil
        case 36, 76: // Enter：默认操作；⌘Enter：始终粘贴到当前应用
            guard let entry = viewModel.selectedEntry else { return event }
            if commandPressed {
                Task { await viewModel.pasteToActiveApplication(entry) }
            } else {
                Task { await viewModel.performDefaultAction(entry) }
            }
            return nil
        case 8: // ⌘C：复制到系统剪贴板（需求 §10）
            guard commandPressed, let entry = viewModel.selectedEntry else { return event }
            viewModel.copyToClipboard(entry)
            return nil
        case 51, 117: // Delete：删除
            guard let entry = viewModel.selectedEntry else { return event }
            Task { await viewModel.delete(entry) }
            return nil
        case 53: // Esc：搜索中先清空 → 退出搜索 → 关闭面板
            if !viewModel.searchText.isEmpty {
                viewModel.searchText = ""
            } else if isSearching {
                isSearching = false
            } else {
                WindowManager.shared.hideClipboardWindow()
            }
            return nil
        default:
            return event
        }
    }
}

/// 搜索输入框（点击 🔍 后展开）。
struct SearchField: View {
    @Bindable var viewModel: ClipboardViewModel
    var onExitSearch: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .accessibilityLabel("搜索剪贴板")
            Button {
                viewModel.searchText = ""
                onExitSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出搜索")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { searchFocused = true }
        .onChange(of: viewModel.searchFocusRequest) {
            searchFocused = true
        }
    }
}

extension Color {
    /// "#RRGGBB" → Color；非法输入回退为强调色。
    init(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("#"), value.count == 7,
              let rgb = Int(value.dropFirst(), radix: 16)
        else {
            self = .accentColor
            return
        }
        self = Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}


/// 操作反馈 toast（需求 §18）。
struct FeedbackToast: View {
    let feedback: OperationFeedback

    var body: some View {
        switch feedback {
        case .idle:
            EmptyView()
        case .pasting:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("正在粘贴…")
            }
            .foregroundStyle(.white)
            .toastStyle()
        case .pasted(let app):
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                Text("已粘贴到 \(app)")
            }
            .foregroundStyle(.white)
            .toastStyle(background: Color.green.opacity(0.92))
        case .copied:
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                Text("已复制到剪贴板")
            }
            .foregroundStyle(.white)
            .toastStyle(background: Color.green.opacity(0.92))
        case .failed(let message):
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message)
            }
            .foregroundStyle(.white)
            .toastStyle(background: Color.orange.opacity(0.94))
        }
    }
}

extension View {
    func toastStyle(background: Color = Color.accentColor.opacity(0.95)) -> some View {
        font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(background, in: Capsule())
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }
}
