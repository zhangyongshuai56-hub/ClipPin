import AppKit
import ImageIO
import SwiftUI

/// 面板卡片（需求 §2、§11）：内容预览 + 类型/来源 + 时间；选中态显示「↩ 粘贴」角标。
/// 单击选中、双击执行「默认操作」（与 Enter 共用设置）——点击检测收口在按下手势的 onEnded 内：
/// 不能再依赖父视图的 onTapGesture，子视图的 DragGesture(minimumDistance: 0)
/// 会在 mouse-down 完成识别并使父视图 tap 手势失效（SwiftUI 手势仲裁），双击由此失灵。
struct ClipboardCard: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    var onSelect: () -> Void = {}
    var onDoubleAction: () -> Void = {}
    @State private var isHovered = false
    /// 按下状态：反馈发生在按下的瞬间，而不是松开时。
    @State private var isPressed = false
    /// 本次按压的起始时刻，用于排除长按。
    @State private var pressStartDate = Date.distantPast
    /// 上一次单击时刻，用于双击判定（间隔取系统双击阈值）。
    @State private var lastTapDate: Date?
    /// VoiceOver 焦点；与 selectionID 双轨会让 ⌫/Enter 作用于另一张卡片，焦点到达即同步选中。
    @AccessibilityFocusState private var isVoiceOverFocused: Bool

    /// 位移超过该值按拖拽处理（取消点击）；按住超过该时长不算点击。
    private static let clickTranslationLimit: CGFloat = 8
    private static let clickDurationLimit: TimeInterval = 0.5

    var body: some View {
        cardSurface
            .onHover { isHovered = $0 }
            // minimumDistance 0：mouse-down 即触发，按下瞬间就有反馈；
            // 松开时位移/时长达标才算点击，按住拖走等于取消
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isPressed { pressStartDate = value.time }
                        isPressed = hypot(value.translation.width, value.translation.height) < Self.clickTranslationLimit
                    }
                    .onEnded { value in
                        isPressed = false
                        guard hypot(value.translation.width, value.translation.height) < Self.clickTranslationLimit,
                              value.time.timeIntervalSince(pressStartDate) < Self.clickDurationLimit
                        else { return }
                        let now = Date()
                        if let last = lastTapDate, now.timeIntervalSince(last) <= NSEvent.doubleClickInterval {
                            lastTapDate = nil
                            onDoubleAction()
                        } else {
                            lastTapDate = now
                            onSelect()
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAddTraits(.isButton)
            .accessibilityFocused($isVoiceOverFocused)
            .onChange(of: isVoiceOverFocused) { _, focused in
                if focused { onSelect() }
            }
            // 默认动作挂到 VO+Space（.isButton trait 本身没有可执行的按压目标）
            .accessibilityAction { onDoubleAction() }
            .accessibilityAction(named: PasteSettings.defaultAction == .activeApp ? "粘贴" : "复制") { onDoubleAction() }
    }

    /// 卡片视觉层：与 body 的手势 / 无障碍修饰链分开，避免超长表达式拖垮类型检查。
    private var cardSurface: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: entry.itemType.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.itemType.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(entry.updatedAt.shelfRelativeTime)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            // 内容在头部行与来源行之间垂直 + 水平居中：窗口拉伸时上下 Spacer 均分剩余空间
            Spacer(minLength: 0)
            bodyContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if let source = entry.sourceAppName {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 150, maxWidth: 150, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.10)
                        : (isPressed
                            ? Color.primary.opacity(0.085)
                            : (isHovered ? Color.primary.opacity(0.055) : Color.primary.opacity(0.035)))
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        }
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }

    /// 朗读内容 = 类型 + 置顶 + 时间 + 来源 + 内容预览（缺一不可，读屏用户没有"扫一眼"）。
    private var accessibilitySummary: String {
        var parts: [String] = [entry.itemType.title]
        if entry.isPinned { parts.append("已置顶") }
        parts.append(entry.updatedAt.shelfRelativeTime)
        if let source = entry.sourceAppName { parts.append("来源\(source)") }
        parts.append(entry.preview ?? entry.title ?? "")
        return parts.joined(separator: "，")
    }

    // MARK: - 内容预览（需求 §2 卡片形态）

    @ViewBuilder
    private var bodyContent: some View {
        switch entry.itemType {
        case .image:
            ThumbnailImage(path: entry.thumbnailPath ?? entry.imagePath, side: 0)
                .frame(height: 52)
                .frame(maxWidth: .infinity)
        case .url:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? entry.url ?? "链接")
                    .foregroundStyle(.tint)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Text(entry.url ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .file, .folder:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? entry.filePath ?? "文件")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(entry.filePath ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if entry.contentSize > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: entry.contentSize, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .code:
            Text(entry.preview ?? entry.textContent ?? "")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(4)
        default:
            Text(entry.preview ?? entry.textContent ?? "")
                .lineLimit(4)
        }
    }
}

/// 缩略图内存缓存（§57、§83）：网格滚动时行会反复重绘，
/// NSCache 避免重复磁盘 IO，并在内存压力下自动逐出。
/// 解码经 ImageIO 按目标尺寸下采样：一张 4K 截屏在 52pt 卡片里
/// 只需 ~320px 位图的内存，而不是整图；cost 按实际解码字节计，totalCostLimit 才真实生效。
/// 缓存读写限定主线程（SwiftUI 视图访问），解码本身在后台任务执行。
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    private func key(_ path: String, _ maxPixel: CGFloat) -> NSString {
        "\(path)#\(Int(maxPixel))" as NSString
    }

    func cachedImage(for path: String, maxPixel: CGFloat) -> NSImage? {
        cache.object(forKey: key(path, maxPixel))
    }

    func store(_ image: NSImage, for path: String, maxPixel: CGFloat) {
        cache.setObject(image, forKey: key(path, maxPixel), cost: image.decodedByteSize)
    }

    /// ImageIO 下采样解码：读元数据算缩放比，只解码目标尺寸一次。
    /// nonisolated：在后台任务中调用，产物经 SendableImage 投回主线程。
    nonisolated static func decodeDownsampled(path: String, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// CGImage 的 Sendable 载体：解码后的位图不可变、跨线程只读，
/// 用显式包装通过 Swift 6 的跨隔离域检查。
private final class SendableImage: @unchecked Sendable {
    let cgImage: CGImage?
    init(_ cgImage: CGImage?) { self.cgImage = cgImage }
}

private extension NSImage {
    /// 解码后位图的内存占用，供 NSCache cost 使用。
    var decodedByteSize: Int {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// 本地缩略图加载（经缓存）。
/// side > 0 时为正方形；side == 0 时占满调用方给定的尺寸（需由调用方提供高度）。
/// 用 Color.clear + overlay + clipped 的组合保证 aspect-fill 溢出部分被裁掉，
/// 避免大图按原始尺寸绘制溢出卡片边界。
/// 解码异步进行：缓存未命中时先显示占位图，后台下采样完成后回填——
/// body 求值期间不做磁盘 IO / 图像解码，快速滚动不逐卡阻塞主线程。
struct ThumbnailImage: View {
    let path: String?
    let side: CGFloat
    /// 下采样目标（最长边像素，含 Retina 倍率）；默认与 Core 侧缩略图标准一致。
    var maxPixel: CGFloat = 320
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(Color.primary.opacity(0.08))
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: side > 0 ? side : nil, height: side > 0 ? side : nil)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("图片预览")
            .task(id: "\(path ?? "")#\(Int(maxPixel))") {
                await loadThumbnail()
            }
    }

    private func loadThumbnail() async {
        guard let path else {
            image = nil
            return
        }
        if let cached = ThumbnailCache.shared.cachedImage(for: path, maxPixel: maxPixel) {
            image = cached
            return
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            SendableImage(ThumbnailCache.decodeDownsampled(path: path, maxPixel: maxPixel))
        }.value
        guard !Task.isCancelled else { return }
        guard let cgImage = decoded.cgImage else { return }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        ThumbnailCache.shared.store(nsImage, for: path, maxPixel: maxPixel)
        image = nsImage
    }
}

extension Date {
    /// 相对时间格式（如「3分钟前」「昨天 14:30」回退为日期）。
    var shelfRelativeTime: String {
        formatted(.relative(presentation: .named))
    }
}
