import AppKit
import SwiftUI
import os

/// 窗口生命周期管理（需求 §1~§6）。仅在主线程访问。
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private let logger = Logger(subsystem: "com.paste.app", category: "window")

    private var clipboardWindow: ClipboardWindow?
    /// 窗口内容使用的 ViewModel；随窗口内容一起释放。
    private weak var viewModel: ClipboardViewModel?

    /// 面板尺寸持久化键（需求 §4）。
    private static let panelSizeKey = "panelSize"
    /// 面板显示时刻：用于「点击外部关闭」的防误关宽限期。
    private var shownAt = Date.distantPast
    /// 面板是否真正获得过键盘焦点（激活失败时不启用「点击外部关闭」）。
    private var panelHadKeyFocus = false
    private var resignObserver: NSObjectProtocol?
    /// 面板可见期间的全局点击监听（非激活面板不会产生 resignActive，点击外部关闭由此兜底）。
    private var clickOutsideObserver: Any?
    /// 显隐动画代数：每次呼出/隐藏自增。被打断的动画回调检查代数后再收尾，
    /// 否则快速连按 ⌘⇧V 时，上一次隐藏的完成回调会把刚显示的面板 orderOut 吞掉。
    private var transitionGeneration = 0

    /// 「点击外部 / 失活关闭」的防误关宽限期：面板拿到过键盘焦点后，
    /// 点击外部是明确意图，短宽限即可（响应优先）；焦点从未落位
    /// （系统拒绝激活）时保留长宽限，避免呼出瞬间被误关。
    private var dismissGraceInterval: TimeInterval { panelHadKeyFocus ? 0.3 : 1.5 }

    /// 显示剪贴板面板（需求 §1）：出现在鼠标所在屏幕底部居中。
    /// focusSearch 只给显式搜索入口用（菜单栏「搜索剪贴板」）：默认呼出只出列表，
    /// 搜索框不再自动展开/聚焦，搜索改为用户主动进入（🔍 按钮 / ⌘F）。
    func showClipboardWindow(focusSearch: Bool = false) {
        guard let repository = CoreStore.shared.repository else {
            logger.error("clipboard window requested before core is ready")
            return
        }
        // §37：在激活自己之前记录前台应用，作为 Quick Paste 的粘贴目标
        PasteService.shared.noteWindowAboutToShow()

        let savedSize = Self.loadPanelSize()
        let window = clipboardWindow ?? makeClipboardWindow(repository: repository, contentSize: savedSize)
        // 存档尺寸按当前屏幕钳上限：大屏存下的大尺寸换到小屏 / 拔掉显示器后不致溢出
        let clamped = Self.clampedPanelSize(window.frame.size)
        if clamped != window.frame.size {
            window.setContentSize(clamped)
        }

        shownAt = Date()
        panelHadKeyFocus = false
        transitionGeneration += 1
        // §64：呼出「到场」——自底部锚点轻微上浮 + 淡入；从当前呈现值出发，
        // 打断进行中的隐藏时不会跳变；已完整可见时（菜单栏重复呼出）不重播
        animateIn(window)
        // .nonactivatingPanel：makeKey 不依赖应用激活——前台应用正在输入、
        // 协作式激活被系统拒绝时，面板照样拿到键盘焦点（Spotlight 模型）
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        // best-effort 激活：成功时失活关闭等旧行为保持；失败不影响面板可用
        NSApp.activate(ignoringOtherApps: true)
        // makeKey 可能被系统延迟（协作式激活期间），重试直至面板真正拿到 key；
        // 期间面板又被隐藏（代数变化）则放弃重试
        let generation = transitionGeneration
        for delay in [0.1, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard generation == self.transitionGeneration else { return }
                if !window.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.makeKey()
                }
                self.panelHadKeyFocus = self.panelHadKeyFocus || window.isKeyWindow
            }
        }
        logger.info("panel shown: key=\(window.isKeyWindow) active=\(NSApp.isActive)")
        // 搜索界面：默认不展开——呼出即看列表；只有显式搜索请求才展开并聚焦输入框。
        // 未聚焦时面板仍是 key window，↑↓←→ 导航、⌘C / ⌘P / ↩ 等快捷键照常工作。
        if let viewModel {
            if focusSearch {
                viewModel.requestSearchFocus()
            } else {
                // 收起可能残留的搜索框并清空查询词，面板每次呼出都回到默认状态
                viewModel.resetSearchUI()
            }
        }
        installClickOutsideObserverIfNeeded()
        installResignObserverIfNeeded()
    }

    /// 全局快捷键行为（§26）：未显示 → 呼出并聚焦搜索；有焦点 → 隐藏；
    /// 可见但无 key（系统延迟 makeKey）→ 重新 makeKey 而不是误隐藏。
    func toggleClipboardWindow() {
        if let window = clipboardWindow, window.isVisible {
            if window.isKeyWindow {
                logger.info("toggle: visible+key → hide")
                hideClipboardWindow()
            } else {
                logger.info("toggle: visible without key → make key")
                window.makeKeyAndOrderFront(nil)
                window.makeKey()
                panelHadKeyFocus = panelHadKeyFocus || window.isKeyWindow
            }
        } else {
            showClipboardWindow()
        }
    }

    /// 隐藏面板（Esc / 点击外部 / Quick Paste，§28、需求 §6）。
    /// 与呼出互为镜像（同路径往返，空间一致）；从当前呈现值出发可被随时打断，
    /// 完成回调检查动画代数：被打断的隐藏不再 orderOut 面板。
    func hideClipboardWindow() {
        guard let window = clipboardWindow, window.isVisible else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        let frame = window.frame
        let exitFrame = CGRect(
            origin: CGPoint(x: frame.origin.x, y: frame.origin.y - 10),
            size: frame.size
        )
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(exitFrame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard generation == self.transitionGeneration, self.clipboardWindow === window else { return }
                window.orderOut(nil)
                window.alphaValue = 1
                // 面板不可见期间无需监听全局点击：常驻监听让 App 存活期内每次系统级
                // 鼠标点击都进回调；下次 showClipboardWindow 会重装
                self.removeClickOutsideObserver()
            }
        })
    }

    /// 呼出动画：淡入 + 自底部目标位置下方 10pt 上浮到场。
    /// 起点取当前呈现值（打断隐藏时从中途继续），reduce motion 退化为快速淡入。
    private func animateIn(_ window: NSPanel) {
        let size = window.frame.size
        let targetOrigin = Self.bottomCenterOrigin(for: window)
        let targetFrame = CGRect(origin: targetOrigin, size: size)
        if !window.isVisible {
            // 隐藏收尾时 alpha 已复位为 1，重新呼出前先置于起点
            window.setFrame(CGRect(origin: CGPoint(x: targetOrigin.x, y: targetOrigin.y - 10), size: size), display: false)
            window.alphaValue = 0
        }
        guard window.alphaValue < 0.999 || window.frame != targetFrame else { return }
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0.08 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    /// 外观设置变化时同步到已创建窗口的标题栏。
    func applyAppearanceToAllWindows() {
        clipboardWindow?.appearance = AppearanceMode.stored.nsAppearance
    }

    // MARK: - 创建与 delegate

    private func makeClipboardWindow(repository: ClipboardRepository, contentSize: NSSize) -> ClipboardWindow {
        let viewModel = ClipboardViewModel(repository: repository, pasteService: .shared)
        self.viewModel = viewModel
        let window = ClipboardWindow(rootView: ClipboardView(viewModel: viewModel), contentSize: contentSize)
        window.delegate = self
        clipboardWindow = window
        return window
    }

    /// 拖拽调宽高时按当前屏幕可用区钳制（需求 §3：最大接近屏幕可用区域）。
    nonisolated func windowWillResize(_ sender: NSWindow, to frame: NSSize) -> NSSize {
        var size = frame
        MainActor.assumeIsolated {
            guard let screen = sender.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let margin: CGFloat = 24
            // 只钳制上限（不超出屏幕）；最小尺寸不限制（用户要求）
            size.width = min(size.width, visible.width - margin * 2)
            size.height = min(size.height, visible.height - margin * 2)
        }
        return size
    }

    /// 需求 §4：记住用户最后使用的窗口尺寸。
    nonisolated func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        MainActor.assumeIsolated {
            let size = window.frame.size
            UserDefaults.standard.set("\(Int(size.width))x\(Int(size.height))", forKey: Self.panelSizeKey)
            logger.info("panel size saved \(Int(size.width))x\(Int(size.height))")
        }
    }

    /// 需求 §6：点击窗口外部关闭（应用激活成功时的路径）。
    /// 1.5s 宽限期防误关（呼出后焦点可能被短暂抢回）；粘贴进行中不关闭。
    private func installResignObserverIfNeeded() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.clipboardWindow, window.isVisible else { return }
                // 宽限期：呼出后焦点可能被前一个应用短暂抢回，期间不失活关闭
                guard Date().timeIntervalSince(self.shownAt) > self.dismissGraceInterval else { return }
                // Quick Paste 进行中不关（激活目标应用会触发失活）
                guard !PasteService.shared.isBusy else { return }
                // 呼出时未获得焦点（如系统拒绝后台激活）→ 失活不关，面板仍可点击使用
                guard self.panelHadKeyFocus else { return }
                self.hideClipboardWindow()
            }
        }
    }

    /// 「点击外部关闭」兜底：非激活面板（热键呼出且协作式激活被拒）不会产生
    /// resignActive 事件，全局鼠标监听负责在点击面板外时关闭。
    /// 全局监听只收到应用外部的点击，无需再判断点击位置；
    /// 宽限期与 Quick Paste 守卫与失活路径一致，两条路径幂等。
    /// 生命周期与面板可见性绑定：hideClipboardWindow 完成时移除。
    private func installClickOutsideObserverIfNeeded() {
        guard clickOutsideObserver == nil else { return }
        clickOutsideObserver = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.clipboardWindow, window.isVisible else { return }
                guard Date().timeIntervalSince(self.shownAt) > self.dismissGraceInterval else { return }
                guard !PasteService.shared.isBusy else { return }
                self.hideClipboardWindow()
            }
        }
    }

    private func removeClickOutsideObserver() {
        if let clickOutsideObserver {
            NSEvent.removeMonitor(clickOutsideObserver)
            self.clickOutsideObserver = nil
        }
    }

    // MARK: - 定位与尺寸

    /// 需求 §1/§5：面板目标位置为鼠标所在屏幕底部居中（无法确定时回退当前帧）。
    /// visibleFrame 已扣除菜单栏 / Dock / 刘海。
    private static func bottomCenterOrigin(for window: NSPanel) -> CGPoint {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            return window.frame.origin
        }
        let visibleFrame = screen.visibleFrame
        let size = window.frame.size
        let bottomMargin: CGFloat = 12
        return CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + bottomMargin
        )
    }

    static func loadPanelSize() -> NSSize {
        guard let text = UserDefaults.standard.string(forKey: panelSizeKey) else {
            return ClipboardWindow.defaultContentSize
        }
        let parts = text.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] >= 60, parts[1] >= 60 else {
            return ClipboardWindow.defaultContentSize
        }
        return NSSize(width: parts[0], height: parts[1])
    }

    /// 面板尺寸按鼠标所在屏幕的可用区钳上限（margin 与 windowWillResize 一致）。
    /// 只钳上限不动下限（用户要求不限制最小尺寸）。
    private static func clampedPanelSize(_ size: NSSize) -> NSSize {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            return size
        }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        return NSSize(
            width: min(size.width, max(60, visible.width - margin * 2)),
            height: min(size.height, max(60, visible.height - margin * 2)))
    }
}
