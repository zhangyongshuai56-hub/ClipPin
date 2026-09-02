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

    /// 显示剪贴板窗口（§26）：出现在鼠标所在屏幕、靠近鼠标的位置（§27）。
    /// Core 未就绪时记录错误并忽略，不崩溃。
    func showClipboardWindow(focusSearch: Bool = false) {
        guard let repository = CoreStore.shared.repository else {
            logger.error("clipboard window requested before core is ready")
            return
        }
        // §37：在激活自己之前记录前台应用，作为 Quick Paste 的粘贴目标
        PasteService.shared.noteWindowAboutToShow()
        let window = clipboardWindow ?? makeClipboardWindow(repository: repository)
        positionWindowNearMouse(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if focusSearch {
            viewModel?.requestSearchFocus()
        }
    }

    /// 全局快捷键行为（§26）：未显示 → 呼出并聚焦搜索；已显示 → 隐藏。
    func toggleClipboardWindow() {
        if let window = clipboardWindow, window.isVisible {
            hideClipboardWindow()
        } else {
            showClipboardWindow(focusSearch: true)
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

    // MARK: - 定位（§27）

    /// 窗口出现在鼠标附近：以鼠标所在屏幕的可见区域为界（自动避开菜单栏、Dock、刘海区域），
    /// 水平以鼠标为中心，垂直大致与鼠标对齐；越界时收进可见区域，保证不超出屏幕。
    private func positionWindowNearMouse(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen else {
            window.center()
            return
        }
        let visibleFrame = screen.visibleFrame
        let size = window.frame.size
        var origin = CGPoint(
            x: mouseLocation.x - size.width / 2,
            y: mouseLocation.y - size.height * 0.6
        )
        origin.x = max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - size.width))
        origin.y = max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - size.height))
        // 屏幕比窗口还小（极端分辨率）时兜底取可见区左下角
        origin.x = max(origin.x, visibleFrame.minX)
        origin.y = max(origin.y, visibleFrame.minY)
        window.setFrameOrigin(origin)
    }
}
