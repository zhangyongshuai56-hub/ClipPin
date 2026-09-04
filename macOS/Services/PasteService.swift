import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Quick Paste 编排结果；反馈文案由 ViewModel 翻译。
enum QuickPasteOutcome {
    /// 已注入 ⌘V 并恢复了用户原剪贴板。
    case success(targetName: String?)
    /// 缺少辅助功能权限。
    case accessibilityDenied
    /// 内容写入剪贴板失败（调用方的 write 返回 false）。
    case writeFailed
    /// 未能完成粘贴：目标缺失 / 激活被拒 / 焦点未落位。
    case failed
}

/// Quick Paste 服务（§37、§38）。
/// 流程：快照用户原剪贴板 → 复制选中项 → 隐藏窗口 → 激活之前的前台应用 →
/// 合成 ⌘V → 延时恢复用户原剪贴板。无辅助功能权限时由 UI 显式引导，绝不绕过权限机制。
@MainActor
final class PasteService {
    static let shared = PasteService()

    private let logger = Logger(subsystem: "com.paste.app", category: "paste")

    /// 剪贴板窗口弹出前的前台应用（粘贴目标）。需求 §13：不能把自己当目标。
    private(set) var previousApp: NSRunningApplication?

    /// Quick Paste 进行中标记：点击外部关闭的守卫（激活目标应用会触发失活）。
    var isBusy = false

    /// 粘贴目标应用名称（反馈文案「✓ 已粘贴到 Safari」用，需求 §18）。
    var previousAppName: String? { previousApp?.localizedName }

    private init() {}

    // MARK: - 权限（§38）

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 打开系统设置的辅助功能面板。
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 粘贴目标

    /// WindowManager 显示剪贴板窗口前调用：记录粘贴目标应用。
    /// §13：不能把自己当目标——从菜单栏呼出时前台就是本应用，此时无可粘贴目标。
    func noteWindowAboutToShow() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = (front?.bundleIdentifier == Bundle.main.bundleIdentifier) ? nil : front
    }

    // MARK: - 剪贴板快照（§37：用户原来的 Clipboard 不能被破坏）

    typealias PasteboardSnapshot = [(NSPasteboard.PasteboardType, Data)]

    func captureCurrentContents() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        guard let types = pasteboard.types else { return [] }
        return types.compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        }
    }

    /// 恢复快照内容；恢复动作本身不进历史（§18）。
    func restore(_ snapshot: PasteboardSnapshot) {
        guard !snapshot.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes(snapshot.map(\.0), owner: nil)
        for (type, data) in snapshot {
            pasteboard.setData(data, forType: type)
        }
        ClipboardChangeGate.shared.suppress(pasteboard.changeCount)
        logger.info("pasteboard restored types=\(snapshot.count)")
    }

    // MARK: - 粘贴

    /// 隐藏窗口 → 激活之前的前台应用 → 合成 ⌘V。
    /// 返回 false 表示未能完成（原因已记录）。
    func pasteToPreviousApp(hideWindow: () -> Void) async -> Bool {
        guard let previous = previousApp else {
            logger.error("quick paste aborted: no previous app recorded")
            return false
        }
        guard previous.bundleIdentifier != Bundle.main.bundleIdentifier else {
            logger.error("quick paste aborted: target is self")
            return false
        }
        hideWindow()
        // 由当前应用发起协作式激活，把焦点让渡给粘贴目标
        let activated = previous.activate(from: .current)
        if !activated {
            logger.error("quick paste aborted: activation refused")
            return false
        }
        // 给目标应用一点完成激活的时间，再注入按键
        try? await Task.sleep(for: .milliseconds(250))
        // 焦点没落在目标应用上时，⌘V 会打进错误窗口；宁可失败让上层恢复快照
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.processIdentifier else {
            logger.error("quick paste aborted: focus did not settle on target app")
            return false
        }
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true) else {
            return false
        }
        keyDown.flags = [.maskCommand]
        keyDown.post(tap: .cghidEventTap)
        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
            keyUp.flags = [.maskCommand]
            keyUp.post(tap: .cghidEventTap)
        }
        logger.info("quick paste keystroke sent")
        return true
    }

    // MARK: - 完整编排

    /// 完整 Quick Paste 编排（§37）：快照原剪贴板 → 写板 → 隐藏窗口 → 激活目标 →
    /// ⌘V → 延时恢复。内容如何写板（`write`）属于调用方的领域知识；
    /// 时序、快照恢复与 isBusy 状态全部在此收口。
    func runQuickPaste(write: () -> Bool, hideWindow: () -> Void) async -> QuickPasteOutcome {
        guard isAccessibilityTrusted else { return .accessibilityDenied }
        let snapshot = captureCurrentContents()
        guard write() else { return .writeFailed }
        isBusy = true
        defer { isBusy = false }
        let pasted = await pasteToPreviousApp(hideWindow: hideWindow)
        guard pasted else {
            // 失败也必须还原用户原剪贴板（§37：原 Clipboard 不能被破坏）
            restore(snapshot)
            return .failed
        }
        // 确保目标 App 读取完成后再恢复原剪贴板（需求 §14）
        try? await Task.sleep(for: .milliseconds(600))
        restore(snapshot)
        return .success(targetName: previousAppName)
    }
}
