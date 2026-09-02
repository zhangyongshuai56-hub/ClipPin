import AppKit
import Foundation
import os

extension Notification.Name {
    /// 监听器成功入库一条新内容后发出；UI 据此刷新列表。
    static let clipboardMonitorDidSaveItem = Notification.Name("com.aidopaste.clipboard.didSaveItem")
}

/// 剪贴板监听（§15、§18、§33、§39、§40、§44）。
///
/// - 单个 Timer 以 0.5s 间隔检查 `changeCount`（O(1) 调用，非高频轮询，§44）；
/// - 实际读取与入库在后台线程执行，避免阻塞主线程；
/// - 应用自身写入产生的变更通过抑制表跳过（§18）；
/// - 前台应用属于排除列表时不记录（§39）；暂停状态不记录（§40）。
@MainActor
final class ClipboardMonitor {
    static let pollInterval: TimeInterval = 0.5

    private let appState: AppState
    private let repository: ClipboardRepository
    private let logger = Logger(subsystem: "com.aidopaste.app", category: "clipboard")

    private var timer: Timer?
    /// 最近见过的 changeCount；-1 表示尚未建立基线（首次检查会捕获当前剪贴板）。
    private var lastChangeCount: Int = -1
    /// 后台捕获进行中标记，避免重复并发捕获。
    private var isCapturing = false

    init(appState: AppState, repository: ClipboardRepository) {
        self.appState = appState
        self.repository = repository
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            // Timer 在主 RunLoop 上触发，此处必然在主线程
            guard let self else { return }
            MainActor.assumeIsolated {
                self.checkOnce()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        logger.info("clipboard monitor started interval=\(Self.pollInterval, privacy: .public)")
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        logger.info("clipboard monitor stopped")
    }

    /// §18：应用把历史内容写回剪贴板（如复制历史条目）之后，监听会自动跳过
    /// 对应的 changeCount；抑制表由 ClipboardChangeGate 统一管理。

    private func checkOnce() {
        // §40：暂停时不记录
        guard !appState.isPaused else { return }

        let changeCount = NSPasteboard.general.changeCount
        guard changeCount != lastChangeCount else { return }

        // §18：自家写入导致的变更，只更新基线不捕获
        if ClipboardChangeGate.shared.consumeIfSuppressed(changeCount) {
            lastChangeCount = changeCount
            logger.debug("clipboard change suppressed (internal write)")
            return
        }

        // 上一拍捕获尚未完成；等完成后下一拍会看到新的 changeCount
        guard !isCapturing else { return }

        // 前台应用：用于来源记录（§33）与排除检查（§39）。NSWorkspace 需在主线程调用。
        let frontApp = NSWorkspace.shared.frontmostApplication
        let sourceBundleID = frontApp?.bundleIdentifier
        if ExcludedApps.isExcluded(sourceBundleID) {
            lastChangeCount = changeCount
            logger.debug("clipboard change from excluded app")
            return
        }

        // 先更新基线：捕获期间若有新变更，下一拍仍能看到更大的 changeCount
        lastChangeCount = changeCount
        isCapturing = true

        let sourceName = frontApp?.localizedName
        let repository = self.repository
        Task.detached(priority: .utility) {
            let payload = ClipboardReader.read(sourceApp: sourceBundleID, sourceAppName: sourceName)
            if let payload {
                if payload.isWithinSizeLimit {
                    do {
                        let entry = try await repository.create(payload.toNewItem())
                        // §84：日志只记录 id / 大小，不记录内容原文
                        await self.captureDidSave(id: entry.id, byteSize: payload.byteSize)
                    } catch {
                        // 库层错误已带上下文；这里保证捕获失败不影响监听循环
                        await self.captureDidFail(error)
                    }
                } else {
                    // §51：超限内容直接跳过
                    await self.captureSkippedAsTooLarge(byteSize: payload.byteSize)
                }
                // §16：图片临时文件在 Core 转存（或跳过）后由 Swift 清理
                payload.cleanupTemporaryFiles()
            }
            await self.captureDidFinish()
        }
    }

    private func captureDidSave(id: Int64, byteSize: Int64) {
        logger.info("clipboard captured id=\(id) bytes=\(byteSize)")
        // 通知 UI 层刷新（ViewModel 会做防抖合并）
        NotificationCenter.default.post(name: .clipboardMonitorDidSaveItem, object: nil)
    }

    private func captureDidFail(_ error: any Error) {
        logger.error("clipboard save failed: \(error.localizedDescription, privacy: .public)")
    }

    private func captureSkippedAsTooLarge(byteSize: Int64) {
        logger.info("clipboard item skipped: too large bytes=\(byteSize)")
    }

    private func captureDidFinish() {
        isCapturing = false
    }
}
