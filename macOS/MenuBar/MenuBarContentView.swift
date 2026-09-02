import SwiftUI

/// 菜单栏图标的主菜单。
struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("打开剪贴板") {
            WindowManager.shared.showClipboardWindow()
        }
        Button("搜索剪贴板") {
            // TODO(Phase 5): 打开后聚焦搜索输入框
            WindowManager.shared.showClipboardWindow(focusSearch: true)
        }
        Divider()
        Button(appState.isPaused ? "恢复记录" : "暂停记录") {
            appState.togglePaused()
        }
        Divider()
        Button("设置…") {
            openSettings()
        }
        Button("退出 AidoPaste") {
            NSApp.terminate(nil)
        }
    }
}
