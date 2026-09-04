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
            // 打开窗口并聚焦搜索框
            WindowManager.shared.showClipboardWindow(focusSearch: true)
        }
        Divider()
        Button(appState.isPaused ? "恢复记录" : "暂停记录") {
            appState.togglePaused()
        }
        Divider()
        Button("设置…") {
            openSettings()
            // accessory 应用打开窗口不会自动置前：显式激活，否则设置窗口会被
            // 当前前台应用的窗口盖住（且无 Dock 图标、不在 ⌘Tab 里，难以找回）
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("退出 Paste") {
            NSApp.terminate(nil)
        }
    }
}
