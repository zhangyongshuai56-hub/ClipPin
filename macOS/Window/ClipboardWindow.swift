import AppKit
import SwiftUI

/// 剪贴板主窗口（需求 §2/§3）：底部快速操作面板。
/// 悬浮层级 + 全空间可见、隐藏标题栏、圆角毛玻璃、可拖拽调整尺寸（最小 700×300）。
final class ClipboardWindow: NSPanel {
    /// 最小内容尺寸（需求 §3）。
    static let minContentSize = NSSize(width: 700, height: 300)
    /// 默认内容尺寸（需求 §3：1000×420）。
    static let defaultContentSize = NSSize(width: 1000, height: 420)

    init(rootView: ClipboardView, contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
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
        self.minSize = Self.minContentSize
        // 上限由 WindowManager 在 windowWillResize 按当前屏幕可用区钳制
        self.contentMaxSize = NSSize(width: 10_000, height: 10_000)
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 不用 hidesOnDeactivate：激活失败时它会把面板整个吞掉（实测）；
        // 「点击外部关闭」由 WindowManager 以宽限期方式手动实现，隐藏统一走
        // Esc / 快捷键 toggle / 点击外部 / Quick Paste 显式路径（§28、需求 §6）
        self.isMovableByWindowBackground = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isReleasedWhenClosed = false
        self.isRestorable = false
        self.appearance = AppearanceMode.stored.nsAppearance

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
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
