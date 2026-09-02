import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var clipboardMonitor: ClipboardMonitor?
    private let globalShortcutManager = GlobalShortcutManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement 兜底：确保应用以菜单栏常驻方式运行，不占用 Dock
        NSApp.setActivationPolicy(.accessory)
        Task {
            await CoreStore.shared.bootstrap()
            // bootstrap 失败时 repository 为 nil，错误已由 CoreStore 记录并在设置页呈现
            guard let repository = CoreStore.shared.repository else { return }
            let monitor = ClipboardMonitor(appState: appState, repository: repository)
            monitor.start()
            clipboardMonitor = monitor

            registerGlobalShortcut()

            // 调试 / 自动化测试钩子：传入 -AidoPasteShowWindowOnLaunch 时启动即显示主窗口
            if ProcessInfo.processInfo.arguments.contains("-AidoPasteShowWindowOnLaunch") {
                WindowManager.shared.showClipboardWindow()
            }
        }
    }

    /// 注册全局快捷键（§26，默认 ⌘⇧V）。失败可见：记录日志，设置页将展示错误（Phase 11）。
    private func registerGlobalShortcut() {
        do {
            try globalShortcutManager.register(.defaultOpenClipboard) {
                WindowManager.shared.toggleClipboardWindow()
            }
        } catch {
            // 不中断启动；错误信息已由 manager 记录
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // §61：退出时先停止监听；仓储操作都是同步落库，无需额外 flush
        clipboardMonitor?.stop()
        return .terminateNow
    }
}
