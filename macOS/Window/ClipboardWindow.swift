import AppKit
import SwiftUI

/// 剪贴板主窗口。Phase 1 使用标准标题栏窗口；
/// Phase 6 将改为鼠标附近唤出，Phase 13 做 Liquid Glass 面板打磨。
final class ClipboardWindow: NSWindow {
    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        self.title = "AidoPaste"
        self.isReleasedWhenClosed = false
        self.isRestorable = false
        self.appearance = AppearanceMode.stored.nsAppearance
        self.center()
    }
}
