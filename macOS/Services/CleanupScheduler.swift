import Foundation
import os

extension Notification.Name {
    /// 自动清理删除了数据后发出；UI 据此刷新列表（面板此前不反映清理结果）。
    static let cleanupSchedulerDidCleanup = Notification.Name("com.paste.app.cleanup.didCleanup")
}

/// 自动清理调度（§32、§50）：启动后执行一次，之后按用户自定义频率轮询
/// （数值 + 单位，分钟 / 小时 / 天，默认每 1 小时）。
/// Pin 条目永不清理（§31）；实际清理在仓储 actor 上执行，主线程零 IO。
@MainActor
final class CleanupScheduler {
    static let shared = CleanupScheduler()

    private let logger = Logger(subsystem: "com.paste.app", category: "cleanup")
    private var timer: Timer?
    private var repository: ClipboardRepository?

    private init() {}

    /// 一轮清理的结果（立即清理按钮展示用）。
    struct RunSummary: Equatable {
        var expired = 0
        var trimmed = 0
        var orphans = 0

        var message: String {
            var parts: [String] = []
            if expired > 0 { parts.append("过期记录 \(expired) 条") }
            if trimmed > 0 { parts.append("超出上限记录 \(trimmed) 条") }
            if orphans > 0 { parts.append("孤立文件 \(orphans) 个") }
            return parts.isEmpty ? "没有需要清理的内容。" : "已清理：" + parts.joined(separator: "、") + "。"
        }
    }

    /// Core 就绪后注入仓储并启动调度。
    func configure(repository: ClipboardRepository) {
        self.repository = repository
        start()
    }

    func start() {
        guard timer == nil, repository != nil else { return }
        Task { await runOnce() }
        scheduleTimer()
        logger.info("cleanup scheduler started intervalMinutes=\(CleanupSettings.intervalMinutes, privacy: .public)")
    }

    /// 频率设置变更后重建 Timer（即时生效，不中断已开始的清理）。
    func restartSchedule() {
        guard repository != nil else { return }
        timer?.invalidate()
        timer = nil
        scheduleTimer()
        logger.info("cleanup schedule restarted intervalMinutes=\(CleanupSettings.intervalMinutes, privacy: .public)")
    }

    private func scheduleTimer() {
        let interval = TimeInterval(CleanupSettings.intervalMinutes * 60)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Timer 在主 RunLoop 上触发，此处必然在主线程
            guard let self else { return }
            MainActor.assumeIsolated {
                self.scheduleRun()
            }
        }
        // .common：菜单展开等 UI 阻塞模式下定时仍触发（与 ClipboardMonitor 一致）
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func scheduleRun() {
        Task { await runOnce() }
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        logger.info("cleanup scheduler stopped")
    }

    /// 执行一轮清理：过期清理（§32）→ 历史上限（§50）→ 孤儿文件清扫（§48）。
    /// 失败记录日志，不影响下一轮；有删除时通知 UI 刷新（面板列表此前不反映清理结果）。
    @discardableResult
    func runOnce() async -> RunSummary {
        guard let repository else { return RunSummary() }
        var summary = RunSummary()
        do {
            summary.expired = try await repository.cleanupExpired(retention: CleanupSettings.retention)
            // 0 = 不限制（§50 Unlimited）；跳过调用避免清空全部
            if CleanupSettings.historyLimit > 0 {
                summary.trimmed = try await repository.enforceHistoryLimit(CleanupSettings.historyLimit)
            }
            summary.orphans = try await repository.sweepOrphanArtifacts()
            logger.info("cleanup done expired=\(summary.expired) trimmed=\(summary.trimmed) orphans=\(summary.orphans)")
        } catch {
            logger.error("cleanup failed: \(error.localizedDescription, privacy: .public)")
            return summary
        }
        if summary.expired > 0 || summary.trimmed > 0 || summary.orphans > 0 {
            NotificationCenter.default.post(name: .cleanupSchedulerDidCleanup, object: nil)
        }
        return summary
    }
}
