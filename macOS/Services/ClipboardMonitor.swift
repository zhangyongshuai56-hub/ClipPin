import AppKit
import Foundation
import os

extension Notification.Name {
    /// 监听器成功入库一条新内容后发出；UI 据此刷新列表。
    static let clipboardMonitorDidSaveItem = Notification.Name("com.paste.clipboard.didSaveItem")
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
    private let logger = Logger(subsystem: "com.paste.app", category: "clipboard")

    private var timer: Timer?
    /// 最近见过的 changeCount；-1 表示尚未建立基线（首次检查会捕获当前剪贴板）。
    private var lastChangeCount: Int = -1
    /// 后台捕获进行中标记，避免重复并发捕获。
    private var isCapturing = false
    /// 当前捕获的开始时间；看门狗据此复位卡死的捕获状态，避免监听静默停摆。
    private var captureStartedAt: Date?
    /// 捕获代数：每次启动新捕获自增。看门狗复位后旧捕获可能迟到完成，
    /// 代号不匹配时不得复位新捕获的互斥标志（否则两个捕获并发）。
    private var captureGeneration = 0
    /// 捕获看门狗超时：正常捕获毫秒级，超过即视为仓储层异常卡死。
    private static let captureWatchdogTimeout: TimeInterval = 15

    init(appState: AppState, repository: ClipboardRepository) {
        self.appState = appState
        self.repository = repository
    }

    func start() {
        guard timer == nil else { return }
        // 只挂 .common modes：菜单展开（event tracking）时轮询不中断；
        // 不用 scheduledTimer（默认挂 default mode，会与 common 重复注册）
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
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
        let changeCount = NSPasteboard.general.changeCount

        // §40：暂停时不记录。同步推进基线，否则恢复后会把暂停期间的变更补录入库
        if appState.isPaused {
            lastChangeCount = changeCount
            return
        }

        guard changeCount != lastChangeCount else { return }

        // §18：自家写入导致的变更，只更新基线不捕获
        if ClipboardChangeGate.shared.consumeIfSuppressed(changeCount) {
            lastChangeCount = changeCount
            logger.debug("clipboard change suppressed (internal write)")
            return
        }

        // 上一拍捕获尚未完成；等完成后下一拍会看到新的 changeCount。
        // 看门狗：仓储层异常卡死（磁盘 / SQLite 锁）时复位状态并告警，
        // 否则 isCapturing 永不释放，监听静默死亡且无任何日志。
        if isCapturing {
            if let started = captureStartedAt,
               Date().timeIntervalSince(started) > Self.captureWatchdogTimeout {
                logger.error("capture stuck for \(Int(Date().timeIntervalSince(started)), privacy: .public)s; watchdog reset")
                isCapturing = false
                captureStartedAt = nil
            } else {
                return
            }
        }

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
        let startedAt = Date()
        captureStartedAt = startedAt
        captureGeneration += 1
        let generation = captureGeneration

        let sourceName = frontApp?.localizedName
        let repository = self.repository
        Task.detached(priority: .utility) {
            let payload = ClipboardReader.read(sourceApp: sourceBundleID, sourceAppName: sourceName)
            if let payload {
                if payload.isWithinSizeLimit {
                    // 文件载荷一文件一条；其余载荷单条
                    var lastID: Int64?
                    var savedCount = 0
                    for entry in payload.toNewItems() {
                        do {
                            let outcome = try await repository.create(entry)
                            lastID = outcome.entry.id
                            savedCount += 1
                        } catch {
                            // 库层错误已带上下文；这里保证捕获失败不影响监听循环
                            await self.captureDidFail(error)
                        }
                    }
                    if savedCount > 0 {
                        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                        // §84：日志只记录 id / 大小 / 耗时，不记录内容原文
                        await self.captureDidSave(id: lastID ?? 0, byteSize: payload.byteSize, elapsedMs: elapsedMs)
                    }
                } else {
                    // §51：超限内容直接跳过
                    await self.captureSkippedAsTooLarge(byteSize: payload.byteSize)
                }
                // §16：图片临时文件在 Core 转存（或跳过）后由 Swift 清理
                payload.cleanupTemporaryFiles()
            }
            await self.captureDidFinish(generation: generation)
        }
    }

    private func captureDidSave(id: Int64, byteSize: Int64, elapsedMs: Int) {
        logger.info("clipboard captured id=\(id) bytes=\(byteSize) ms=\(elapsedMs)")
        // 通知 UI 层刷新（ViewModel 会做防抖合并）
        NotificationCenter.default.post(name: .clipboardMonitorDidSaveItem, object: nil)
    }

    private func captureDidFail(_ error: any Error) {
        logger.error("clipboard save failed: \(error.localizedDescription, privacy: .public)")
    }

    private func captureSkippedAsTooLarge(byteSize: Int64) {
        logger.info("clipboard item skipped: too large bytes=\(byteSize)")
    }

    private func captureDidFinish(generation: Int) {
        // 看门狗复位后旧捕获迟到完成时代号已不匹配——不得清掉
        // 新捕获正在使用的互斥标志，否则两个捕获会并发进行
        guard generation == captureGeneration else { return }
        isCapturing = false
        captureStartedAt = nil
    }
}
