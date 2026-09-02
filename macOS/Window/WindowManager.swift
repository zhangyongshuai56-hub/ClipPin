import AppKit
import SwiftUI

/// 窗口生命周期管理。仅在主线程访问。
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var clipboardWindow: ClipboardWindow?

    func showClipboardWindow(focusSearch: Bool = false) {
        let window = clipboardWindow ?? makeClipboardWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if focusSearch {
            // TODO(Phase 5): 聚焦搜索输入框
        }
    }

    /// 外观设置变化时同步到已创建窗口的标题栏。
    func applyAppearanceToAllWindows() {
        clipboardWindow?.appearance = AppearanceMode.stored.nsAppearance
    }

    private func makeClipboardWindow() -> ClipboardWindow {
        let window = ClipboardWindow(contentViewController: NSHostingController(rootView: ClipboardView()))
        clipboardWindow = window
        return window
    }
}
