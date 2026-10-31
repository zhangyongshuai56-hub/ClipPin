import AppKit
import SwiftUI

/// 设计 token（UI 审计产物）：把语义色、动效时长与布局尺寸集中到一处，
/// 避免各视图散落 `Color.primary.opacity(0.0x)` 与硬编码动画时长。
///
/// 约定：
/// - **颜色**：一律用语义色（selected / pressed / hovered / resting / muted），
///   不再在视图里手写透明度；muted 一律用 `.secondary`，保证对比度 ≥ 4.5:1。
/// - **动效**：统一走 `Motion.token(_:)`，系统开启「减弱动态效果」时自动退化为无位移淡入。
/// - **尺寸**：可点击目标不低于 22pt，间距不小于 8pt。
enum ClipPinDesign {

    // MARK: - 语义色

    enum Palette {
        /// 卡片静息底色
        static let resting = Color.primary.opacity(0.035)
        /// 卡片悬停底色
        static let hovered = Color.primary.opacity(0.055)
        /// 卡片按下底色
        static let pressed = Color.primary.opacity(0.085)
        /// 卡片选中底色
        static let selected = Color.accentColor.opacity(0.10)
        /// 选中描边
        static let selectedStroke = Color.accentColor
        /// 次要信息（时间 / 来源 / 计数）——`.secondary` 对比度 ≥ 4.5:1
        static let muted = Color.secondary
        /// 置顶标记
        static let pinned = Color.orange
        /// 破坏性操作（删除）
        static let destructive = Color.red
    }

    // MARK: - 动效

    enum Motion {
        /// 按压反馈
        static let press = Animation.easeOut(duration: 0.1)
        /// 状态切换（选中滚动、toast 进出）
        static let standard = Animation.easeOut(duration: 0.15)
        /// 搜索框 ↔ 按钮的形变
        static let morph = Animation.spring(response: 0.25, dampingFraction: 1.0)
        /// 减弱动效时的替代：无位移、快速淡入淡出
        static let reduced = Animation.easeOut(duration: 0.08)

        /// 系统「减弱动态效果」是否开启
        static var isReduced: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        /// 取 token：开启「减弱动态效果」时统一降级为快速淡入（无位移）。
        static func token(_ animation: Animation) -> Animation {
            isReduced ? reduced : animation
        }
    }

    // MARK: - 布局

    enum Metrics {
        /// 可点击目标最小高度（pt）
        static let minTargetHeight: CGFloat = 22
        /// 可点击目标之间的最小间距（pt）
        static let minTargetSpacing: CGFloat = 8
        /// 卡片之间的间距
        static let cardSpacing: CGFloat = 8
        /// 卡片宽度区间：随面板宽度自适应
        static let cardWidthRange: ClosedRange<CGFloat> = 150...260
        /// 期望同时可见的卡片数
        static let visibleCards: CGFloat = 5
        /// 顶部栏高度（含垂直内边距），toast 定位用
        static let topBarHeight: CGFloat = 38
        /// 底部快捷键图例条高度，toast 定位用
        static let footerHeight: CGFloat = 26
    }

    /// 按面板宽度计算卡片宽度：既不写死 150pt 造成大片留白，也不让卡片无限变宽。
    static func cardWidth(containerWidth: CGFloat) -> CGFloat {
        let spacing = Metrics.cardSpacing
        let visible = Metrics.visibleCards
        let ideal = (containerWidth - 16 - spacing * (visible - 1)) / visible
        return min(max(ideal, Metrics.cardWidthRange.lowerBound), Metrics.cardWidthRange.upperBound)
    }
}
