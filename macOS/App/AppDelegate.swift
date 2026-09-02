import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement 兜底：确保应用以菜单栏常驻方式运行，不占用 Dock
        NSApp.setActivationPolicy(.accessory)
        Task { await CoreStore.shared.bootstrap() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // TODO(Phase 10/61): 退出前停止剪贴板监听并 flush 数据库
        .terminateNow
    }
}
