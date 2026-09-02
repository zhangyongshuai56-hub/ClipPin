import AppKit
import SwiftUI

/// 剪贴板主窗口（§23、§27）：Spotlight 式悬浮面板。
/// 悬浮层级 + 全空间可见（呼出于任何桌面/全屏之上）、失焦自动隐藏、
/// 隐藏标题栏 + 圆角毛玻璃（NSVisualEffectView，原生材质，§23）。
final class ClipboardWindow: NSPanel {
    init(rootView: ClipboardView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = "AidoPaste"
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(buttonType)?.isHidden = true
        }
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 不用 hidesOnDeactivate：激活失败（系统安全策略）时它会把面板整体吞掉；
        // 隐藏统一走 Esc / 快捷键 toggle / Quick Paste 三条显式路径（§28）
        self.isMovableByWindowBackground = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isReleasedWhenClosed = false
        self.isRestorable = false
        self.appearance = AppearanceMode.stored.nsAppearance

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = effect.bounds
        effect.addSubview(hostingView)
        self.contentView = effect
        self.center()
    }
}
