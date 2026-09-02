import AppKit
import SwiftUI
import os

/// 窗口生命周期管理。仅在主线程访问。
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private let logger = Logger(subsystem: "com.aidopaste.app", category: "window")

    private var clipboardWindow: ClipboardWindow?
    /// 窗口内容使用的 ViewModel；随窗口内容一起释放。
    private weak var viewModel: ClipboardViewModel?

    /// 显示剪贴板窗口（§26）。Core 未就绪时记录错误并忽略，不崩溃。
    func showClipboardWindow(focusSearch: Bool = false) {
        guard let repository = CoreStore.shared.repository else {
            logger.error("clipboard window requested before core is ready")
            return
        }
        let window = clipboardWindow ?? makeClipboardWindow(repository: repository)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if focusSearch {
            viewModel?.requestSearchFocus()
        }
    }

    /// 隐藏剪贴板窗口（Esc，§28）。窗口保留状态，下次显示更快。
    func hideClipboardWindow() {
        clipboardWindow?.orderOut(nil)
    }

    /// 外观设置变化时同步到已创建窗口的标题栏。
    func applyAppearanceToAllWindows() {
        clipboardWindow?.appearance = AppearanceMode.stored.nsAppearance
    }

    private func makeClipboardWindow(repository: ClipboardRepository) -> ClipboardWindow {
        let viewModel = ClipboardViewModel(repository: repository)
        self.viewModel = viewModel
        let window = ClipboardWindow(
            contentViewController: NSHostingController(rootView: ClipboardView(viewModel: viewModel))
        )
        clipboardWindow = window
        return window
    }
}
