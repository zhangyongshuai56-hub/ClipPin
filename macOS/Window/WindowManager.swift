import AppKit
import SwiftUI
import os

/// 窗口生命周期管理（需求 §1~§6）。仅在主线程访问。
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private let logger = Logger(subsystem: "com.aidopaste.app", category: "window")

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

    /// 显示剪贴板面板（需求 §1、§7）：出现在鼠标所在屏幕底部居中，聚焦搜索框。
    func showClipboardWindow(focusSearch: Bool = true) {
        guard let repository = CoreStore.shared.repository else {
            logger.error("clipboard window requested before core is ready")
            return
        }
        // §37：在激活自己之前记录前台应用，作为 Quick Paste 的粘贴目标
        PasteService.shared.noteWindowAboutToShow()

        let savedSize = Self.loadPanelSize()
        let window = clipboardWindow ?? makeClipboardWindow(repository: repository, contentSize: savedSize)
        positionAtBottomCenter(window)

        shownAt = Date()
        panelHadKeyFocus = false
        // §64：呼出淡入（100~250ms 内）
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        // 激活重试：macOS 可能拒绝后台激活或焦点被前一个应用抢回，
        // 短间隔重试两次，修复「按两次才呼出」
        for delay in [0.1, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !(window.isKeyWindow && NSApp.isActive) {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    window.makeKey()
                }
                self.panelHadKeyFocus = self.panelHadKeyFocus || window.isKeyWindow
            }
        }
        logger.info("panel shown: key=\(window.isKeyWindow) active=\(NSApp.isActive)")
        // 需求 §7：呼出后搜索框默认聚焦，可直接输入
        if focusSearch, let viewModel {
            viewModel.requestSearchFocus()
        }
        installResignObserverIfNeeded()
    }

    /// 全局快捷键行为（§26）：未显示 → 呼出并聚焦搜索；有焦点 → 隐藏；
    /// 可见但无焦点（被其他应用抢回焦点）→ 重新激活而不是误隐藏。
    func toggleClipboardWindow() {
        if let window = clipboardWindow, window.isVisible {
            if window.isKeyWindow && NSApp.isActive {
                logger.info("toggle: visible+key → hide")
                hideClipboardWindow()
            } else {
                logger.info("toggle: visible without key → re-activate")
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeKey()
                panelHadKeyFocus = window.isKeyWindow
            }
        } else {
            showClipboardWindow()
        }
    }

    /// 隐藏面板（Esc / 点击外部 / Quick Paste，§28、需求 §6）。淡出后保留状态。
    func hideClipboardWindow() {
        guard let window = clipboardWindow, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.alphaValue = 1
            }
        })
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

    /// 需求 §6：点击窗口外部关闭。1.5s 宽限期防误关（呼出后焦点可能被短暂抢回）；粘贴进行中不关闭。
    private func installResignObserverIfNeeded() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.clipboardWindow, window.isVisible else { return }
                // 宽限期：呼出后焦点可能被前一个应用短暂抢回，1.5s 内不失活关闭
                guard Date().timeIntervalSince(self.shownAt) > 1.5 else { return }
                // Quick Paste 进行中不关（激活目标应用会触发失活）
                guard !PasteService.shared.isBusy else { return }
                // 呼出时未获得焦点（如系统拒绝后台激活）→ 失活不关，面板仍可点击使用
                guard self.panelHadKeyFocus else { return }
                self.hideClipboardWindow()
            }
        }
    }

    // MARK: - 定位与尺寸

    /// 需求 §1/§5：面板出现在鼠标所在屏幕底部居中（无法确定时回退主屏）。
    /// visibleFrame 已扣除菜单栏 / Dock / 刘海。
    private func positionAtBottomCenter(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let screen else {
            window.center()
            return
        }
        let visibleFrame = screen.visibleFrame
        let size = window.frame.size
        let bottomMargin: CGFloat = 12
        let origin = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + bottomMargin
        )
        window.setFrameOrigin(origin)
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
}
