import Foundation

/// §18：应用自身写剪贴板产生的 changeCount 抑制表。
/// 监听器消费、写入方（复制动作）登记；均在 MainActor 上访问，天然并发安全。
@MainActor
final class ClipboardChangeGate {
    static let shared = ClipboardChangeGate()

    private var suppressed: Set<Int> = []

    private init() {}

    /// 写入剪贴板后登记新的 changeCount，监听器将跳过这次变更。
    func suppress(_ changeCount: Int) {
        suppressed.insert(changeCount)
    }

    /// 监听器检查并消费；命中返回 true（本次变更不捕获）。
    func consumeIfSuppressed(_ changeCount: Int) -> Bool {
        suppressed.remove(changeCount) != nil
    }
}
