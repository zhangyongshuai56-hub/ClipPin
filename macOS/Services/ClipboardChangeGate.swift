import Foundation

/// §18：应用自身写剪贴板产生的 changeCount 抑制表。
/// 监听器消费、写入方（复制动作）登记；均在 MainActor 上访问，天然并发安全。
///
/// 记录带时间窗（2s）：自家写入后若第三方在下一拍前又写入，监听器看到的
/// changeCount 不再等于被抑制值，旧式等值集合会让该记录永久滞留；时间窗
/// 保证陈旧记录自动作废。窗口内同值复现（轮询期间连续两次自家写入恰好同
/// changeCount 不可能——changeCount 单调递增）不受影响。
@MainActor
final class ClipboardChangeGate {
    static let shared = ClipboardChangeGate()

    /// 抑制记录有效期：远大于轮询间隔（0.5s），小于任何真实用户复制间隔的下界。
    private static let suppressionWindow: TimeInterval = 2

    private var suppressed: [Int: Date] = [:]

    private init() {}

    /// 写入剪贴板后登记新的 changeCount，监听器将跳过这次变更。
    func suppress(_ changeCount: Int) {
        pruneExpired()
        suppressed[changeCount] = Date()
    }

    /// 监听器检查并消费；命中且仍在窗口内返回 true（本次变更不捕获）。
    func consumeIfSuppressed(_ changeCount: Int) -> Bool {
        pruneExpired()
        guard let registeredAt = suppressed.removeValue(forKey: changeCount) else { return false }
        return Date().timeIntervalSince(registeredAt) <= Self.suppressionWindow
    }

    private func pruneExpired() {
        guard !suppressed.isEmpty else { return }
        let now = Date()
        suppressed = suppressed.filter { now.timeIntervalSince($0.value) <= Self.suppressionWindow }
    }
}
