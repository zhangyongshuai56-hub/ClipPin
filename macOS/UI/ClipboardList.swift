import SwiftUI
import os

/// 历史列表（§57、§58）：LazyVStack 懒加载 + 滚动到底部分页 + 键盘优先操作（§28）。
struct ClipboardList: View {
    var viewModel: ClipboardViewModel
    /// 键盘事件监听（§28）：不依赖 SwiftUI 焦点状态，剪贴板窗口为 key 时统一接管。
    @State private var keyMonitor: Any?
    private let logger = Logger(subsystem: "com.aidopaste.app", category: "clipboard")

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if viewModel.entries.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(viewModel.entries) { entry in
                                row(entry)
                            }
                            if viewModel.isLoading {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                .padding(8)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .onChange(of: viewModel.selectionID) { _, newID in
                guard let newID else { return }
                proxy.scrollTo(newID, anchor: .center)
            }
        }
        .onAppear {
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handleKeyDown)
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
        .accessibilityLabel("剪贴板历史")
    }

    // MARK: - 键盘（§28）

    /// 键盘优先操作。返回 nil 表示事件已被消费。
    /// 文本编辑中（搜索框输入）的按键不接管，Esc 由搜索框自行处理。
    /// 方向 / 回车 / 删除 / Esc 按键码匹配；字母快捷键按字符匹配（兼容不同键盘布局与合成事件）。
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let window = NSApp.keyWindow, window is ClipboardWindow else { return event }
        if window.firstResponder is NSTextView { return event }

        let commandPressed = event.modifierFlags.contains(.command)
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()

        switch event.keyCode {
        case 125: // ↓
            viewModel.moveSelection(1)
            return nil
        case 126: // ↑
            viewModel.moveSelection(-1)
            return nil
        case 36, 76: // Enter：复制；⌘Enter：复制并粘贴（§28、§37）
            guard let entry = viewModel.selectedEntry else { return event }
            if commandPressed {
                Task { await viewModel.copyAndPaste(entry) }
            } else {
                viewModel.copyToPasteboard(entry)
            }
            return nil
        case 51, 117: // Delete / Forward delete：删除
            guard let entry = viewModel.selectedEntry else { return event }
            Task { await viewModel.delete(entry) }
            return nil
        case 53: // Esc：关闭窗口
            WindowManager.shared.hideClipboardWindow()
            return nil
        default:
            break
        }

        guard commandPressed else { return event }
        switch characters {
        case "p": // ⌘P：Pin / Unpin
            guard let entry = viewModel.selectedEntry else { return event }
            Task { await viewModel.togglePin(entry) }
            return nil
        case "f": // ⌘F：聚焦搜索框
            viewModel.requestSearchFocus()
            return nil
        default:
            logger.debug("key not handled: cmd+\(characters, privacy: .public) keyCode=\(event.keyCode)")
            return event
        }
    }

    // MARK: - 行

    private func row(_ entry: ClipboardEntry) -> some View {
        ClipboardRow(entry: entry, isSelected: viewModel.selectionID == entry.id)
            .id(entry.id)
            .contentShape(Rectangle())
            .onTapGesture { viewModel.selectionID = entry.id }
            .contextMenu { contextMenu(for: entry) }
            // §36：拖拽导出 —— 图片/文件/文本/链接以系统标准形式交给目标 App
            .onDrag { dragProvider(for: entry) }
            .onAppear {
                // 滚动到最后一条时加载下一页（§58）
                if entry.id == viewModel.entries.last?.id {
                    Task { await viewModel.loadNextPageIfNeeded() }
                }
            }
    }

    /// 拖拽数据源（§36、§60）：文件给 File URL、图片给图像对象、文本给字符串，不做整文件复制。
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

    /// 右键菜单（§66）。
    @ViewBuilder
    private func contextMenu(for entry: ClipboardEntry) -> some View {
        Button("复制") { viewModel.copyToPasteboard(entry) }
        Button("复制并粘贴") {
            Task { await viewModel.copyAndPaste(entry) }
        }
        Divider()
        Button(entry.isPinned ? "取消 Pin" : "Pin") {
            Task { await viewModel.togglePin(entry) }
        }
        .keyboardShortcut("p", modifiers: .command)
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

    // MARK: - 空状态（§52）

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.isSearchActive {
            ContentUnavailableView.search(text: viewModel.searchText)
        } else if viewModel.category == .pinned {
            ContentUnavailableView {
                Label("还没有置顶内容", systemImage: "pin")
            } description: {
                Text("选中条目按 ⌘P 即可置顶，置顶内容不会被自动清理。")
            }
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView {
                    Label("还没有剪贴板记录", systemImage: "doc.on.clipboard")
                } description: {
                    Text("复制一些文字、图片或文件，它们会自动出现在这里。")
                }
                Label("⌘ ⇧ V 打开剪贴板", systemImage: "keyboard")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
