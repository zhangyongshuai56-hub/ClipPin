import SwiftUI

/// 搜索栏（§22、§29）：输入实时搜索，由 ViewModel 防抖后调用 Core。
struct SearchBar: View {
    @Bindable var viewModel: ClipboardViewModel
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("搜索剪贴板")
                .onExitCommand {
                    // Esc：搜索时先清空搜索词，无搜索词则关闭窗口（§28）
                    if viewModel.searchText.isEmpty {
                        WindowManager.shared.hideClipboardWindow()
                    } else {
                        viewModel.searchText = ""
                    }
                }
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
            Divider()
                .frame(height: 14)
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onChange(of: viewModel.searchFocusRequest) {
            searchFocused = true
        }
    }
}
