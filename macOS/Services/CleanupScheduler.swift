import Foundation
import os

/// 自动清理调度（§32、§50、§43）：启动后执行一次，之后每 6 小时一次。
/// Pin 条目永不清理（§31）；实际清理在仓储 actor 上执行，主线程零 IO。
@MainActor
final class CleanupScheduler {
    static let interval: TimeInterval = 6 * 60 * 60

    private let repository: ClipboardRepository
    private let logger = Logger(subsystem: "com.aidopaste.app", category: "cleanup")
    private var timer: Timer?

    init(repository: ClipboardRepository) {
        self.repository = repository
    }

    func start() {
        guard timer == nil else { return }
        Task { await runOnce() }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            // Timer 在主 RunLoop 上触发，此处必然在主线程
            guard let self else { return }
            MainActor.assumeIsolated {
                self.scheduleRun()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
        logger.info("cleanup scheduler started interval=\(Self.interval, privacy: .public)")
    }

    func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        logger.info("cleanup scheduler stopped")
    }

    private func scheduleRun() {
        Task { await runOnce() }
    }

    /// 执行一轮清理：过期清理（§32）→ 历史上限（§50）→ 孤儿文件清扫（§48）。
    /// 失败记录日志，不影响下一轮。
    func runOnce() async {
        do {
            let expired = try await repository.cleanupExpired(retention: CleanupSettings.retention)
            var trimmed = 0
            // 0 = 不限制（§50 Unlimited）；跳过调用避免清空全部
            if CleanupSettings.historyLimit > 0 {
                trimmed = try await repository.enforceHistoryLimit(CleanupSettings.historyLimit)
            }
            let orphans = try await repository.sweepOrphanArtifacts()
            logger.info("cleanup done expired=\(expired) trimmed=\(trimmed) orphans=\(orphans)")
        } catch {
            logger.error("cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
