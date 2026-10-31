import AppKit
import SwiftUI

/// 剪贴板主窗口（需求 §2/§3）：底部快速操作面板。
/// 悬浮层级 + 全空间可见、隐藏标题栏、圆角毛玻璃、可拖拽调整尺寸（最小 700×300）。
final class ClipboardWindow: NSPanel {
    /// 默认内容尺寸（紧凑化：1000×280）。
    static let defaultContentSize = NSSize(width: 1000, height: 280)

    init(rootView: ClipboardView, contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            // .nonactivatingPanel：不激活应用也能成为 key window（Spotlight 模型）。
            // 前台应用正在输入时协作式激活会被系统拒绝，键盘焦点不能依赖应用激活。
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.title = "ClipPin"
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(buttonType)?.isHidden = true
        }
        // 最小尺寸不限制（用户要求）；上限由 WindowManager 在 windowWillResize
        // 按当前屏幕可用区钳制
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
        // 固定 active：面板常以非激活 key 状态使用（热键呼出），
        // followsWindowActiveState 会让材质在这种状态下变淡
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true

        // 用 AutoLayout 把内容钉在材质视图四边：窗口任何尺寸变化下都不会漂移
        // （autoresizing 在 fullSizeContentView + 安全区变化时会出现内容高度漂移，
        //  导致底部提示条被裁剪）
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        // contentViewController 让 AppKit 全程接管视图尺寸与安全区布局
        let controller = NSViewController()
        controller.view = effect
        self.contentViewController = controller
        self.center()
    }
}
