import SwiftUI

/// 剪贴板历史主界面。Phase 1 仅包含空状态，列表 / 搜索 / 预览在 Phase 5 实现。
struct ClipboardView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(appearance.colorScheme)
    }
}
