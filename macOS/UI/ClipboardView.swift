import AppKit
import SwiftUI

/// 剪贴板底部快速操作面板（需求 §2、§20）：
/// 搜索栏 → 分类 tabs → 卡片网格 → 快捷键提示条；呼出后搜索框默认聚焦（需求 §7）。
struct ClipboardView: View {
    @State private var viewModel: ClipboardViewModel
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    /// 键盘事件监听（§28、需求 §8/§19）：不依赖焦点状态，面板为 key 时统一接管。
    @State private var keyMonitor: Any?
    /// 网格区域实际宽度 → 列数。
    @State private var gridColumns: Int = 4

    init(viewModel: ClipboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(viewModel: viewModel)
            CategoryTabs(viewModel: viewModel)
            Divider()
            gridArea
            Divider()
            StatusFooter(viewModel: viewModel)
        }
        .frame(minWidth: ClipboardWindow.minContentSize.width, minHeight: ClipboardWindow.minContentSize.height)
        .preferredColorScheme(appearance.colorScheme)
        .task { await viewModel.loadInitial() }
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

    // MARK: - 卡片网格（需求 §2、§8）

    private var gridArea: some View {
        GeometryReader { geometry in
            Group {
                if viewModel.entries.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(
                                columns: Array(
                                    repeating: GridItem(.flexible(), spacing: 10),
                                    count: gridColumns
                                ),
                                spacing: 10
                            ) {
                                ForEach(viewModel.entries) { entry in
                                    card(entry)
                                }
                            }
                            .padding(14)
                            if viewModel.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(8)
                            }
                        }
                        .onChange(of: viewModel.selectionID) { _, newID in
                            guard let newID else { return }
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: geometry.size.width) { _, width in
                applyGridColumns(width: width)
            }
            .onAppear {
                applyGridColumns(width: geometry.size.width)
            }
        }
    }

    /// 卡片宽约 226pt（+10 间距），列数随面板宽度自适应（需求 §3 可调宽）。
    /// 列数不变时不写 @Observable 属性，避免拖拽调宽时每帧触发全网格重排（卡顿根因）。
    private func applyGridColumns(width: CGFloat) {
        let columns = max(1, Int((width - 28 + 10) / 236))
        guard columns != gridColumns else { return }
        gridColumns = columns
        viewModel.gridColumns = columns
    }

    private func card(_ entry: ClipboardEntry) -> some View {
        ClipboardCard(entry: entry, isSelected: viewModel.selectionID == entry.id)
            .id(entry.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // 双击执行默认操作：粘贴到当前应用（需求 §8、§17）
                Task { await viewModel.pasteToActiveApplication(entry) }
            }
            .onTapGesture {
                viewModel.selectionID = entry.id
            }
            .contextMenu { contextMenu(for: entry) }
            // §36：拖拽导出 —— 图片/文件/文本/链接以系统标准形式交给目标 App
            .onDrag { dragProvider(for: entry) }
            .onAppear {
                // 滚动到最后一张时加载下一页（§58）
                if entry.id == viewModel.entries.last?.id {
                    Task { await viewModel.loadNextPageIfNeeded() }
                }
            }
    }

    /// 右键菜单（§66）：两操作明确区分（需求 §11）。
    @ViewBuilder
    private func contextMenu(for entry: ClipboardEntry) -> some View {
        Button("粘贴到当前应用") {
            Task { await viewModel.pasteToActiveApplication(entry) }
        }
        Button("复制到剪贴板") { viewModel.copyToClipboard(entry) }
        Divider()
        Button(entry.isPinned ? "取消收藏" : "收藏") {
            Task { await viewModel.togglePin(entry) }
        }
        if entry.itemType == .file || entry.itemType == .folder {
            Button("在 Finder 中显示") { viewModel.revealInFinder(entry) }
        }
        if entry.itemType == .url {
            Button("打开链接") { viewModel.openLink(entry) }
        }
        if entry.itemType == .file || entry.itemType == .folder || entry.itemType == .url {
            Divider()
        }
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
        } else if viewModel.category == .pinned {
            ContentUnavailableView {
                Label("还没有收藏内容", systemImage: "pin")
            } description: {
                Text("选中条目按 ⌘P 即可收藏，收藏内容不会被自动清理。")
            }
        } else {
            ContentUnavailableView {
                Label("还没有剪贴板记录", systemImage: "doc.on.clipboard")
            } description: {
                Text("复制一些文字、图片或文件，它们会自动出现在这里。")
            }
        }
    }

    // MARK: - 键盘（§28、需求 §8/§19）

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

    /// 键盘优先操作。返回 nil 表示事件已被消费。
    /// 搜索框输入的普通字符不接管；⌘C 在搜索框存在选中文本时放行给系统。
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let window = NSApp.keyWindow, window is ClipboardWindow else { return event }

        let commandPressed = event.modifierFlags.contains(.command)
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()

        switch event.keyCode {
        case 125: // ↓
            viewModel.moveInGrid(.down)
            return nil
        case 126: // ↑
            viewModel.moveInGrid(.up)
            return nil
        case 123: // ←
            viewModel.moveInGrid(.left)
            return nil
        case 124: // →
            viewModel.moveInGrid(.right)
            return nil
        case 36, 76: // Enter / ⌘Enter：粘贴到当前活动应用（需求 §17 默认操作）
            guard let entry = viewModel.selectedEntry else { return event }
            Task { await viewModel.pasteToActiveApplication(entry) }
            return nil
        case 8: // ⌘C：复制到系统剪贴板（需求 §10）
            guard commandPressed, let entry = viewModel.selectedEntry else { return event }
            viewModel.copyToClipboard(entry)
            return nil
        case 35: // ⌘P：收藏 / 取消收藏
            guard commandPressed, let entry = viewModel.selectedEntry else { return event }
            Task { await viewModel.togglePin(entry) }
            return nil
        case 51, 117: // Delete / Forward delete：删除
            guard let entry = viewModel.selectedEntry else { return event }
            Task { await viewModel.delete(entry) }
            return nil
        case 53: // Esc：有搜索词先清空，否则关闭面板（需求 §6）
            if viewModel.searchText.isEmpty {
                WindowManager.shared.hideClipboardWindow()
            } else {
                viewModel.searchText = ""
            }
            return nil
        default:
            return event
        }
    }
}

/// 底部快捷键提示条（需求 §20）。
struct StatusFooter: View {
    var viewModel: ClipboardViewModel

    var body: some View {
        HStack(spacing: 14) {
            shortcut("↩", "粘贴到当前应用")
            shortcut("⌘C", "复制到剪贴板")
            shortcut("⌘P", "收藏")
            shortcut("⌫", "删除")
            shortcut("Esc", "关闭")
            Spacer(minLength: 0)
            if let total = viewModel.categoryCounts[.all] {
                Text("\(total) 条记录")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func shortcut(_ key: String, _ action: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Text(action)
        }
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


/// 分类横排 tabs（需求 §2）：全部 / 收藏 / 文本 / 图片 / 链接 / 文件，带计数角标。
struct CategoryTabs: View {
    var viewModel: ClipboardViewModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ClipboardCategory.allCases) { category in
                let isActive = category == viewModel.category
                Button {
                    viewModel.category = category
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: category.symbolName)
                            .font(.system(size: 10.5))
                        Text(category.title)
                            .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        if let count = viewModel.categoryCounts[category] {
                            Text("\(count)")
                                .font(.system(size: 10.5))
                                .opacity(0.6)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        isActive ? Color.accentColor.opacity(0.13) : Color.clear,
                        in: Capsule()
                    )
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(category.title)分类")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
