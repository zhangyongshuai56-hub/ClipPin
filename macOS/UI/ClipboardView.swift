import SwiftUI

/// 剪贴板主界面（§22）：侧栏分类 + 列表 + 详情预览。
struct ClipboardView: View {
    @State private var viewModel: ClipboardViewModel
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    init(viewModel: ClipboardViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $viewModel.category)
                .frame(width: 176)
            Divider()
                .ignoresSafeArea()
            VStack(spacing: 0) {
                SearchBar(viewModel: viewModel)
                Divider()
                ClipboardList(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let entry = viewModel.selectedEntry {
                Divider()
                    .ignoresSafeArea()
                ClipboardPreview(entry: entry, viewModel: viewModel)
                    .frame(width: 280)
            }
        }
        .frame(minWidth: 760, minHeight: 470)
        .preferredColorScheme(appearance.colorScheme)
        .task { await viewModel.loadInitial() }
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
            Text("自动粘贴需要「辅助功能」权限。授权后重新按 ⌘↩ 即可粘贴。")
        }
    }
}
