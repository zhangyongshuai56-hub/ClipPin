import AppKit
import SwiftUI

/// 面板卡片（需求 §2、§11）：内容预览 + 类型/来源 + 时间；选中态显示「↩ 粘贴」角标。
struct ClipboardCard: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: entry.itemType.symbolName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(entry.itemType.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(entry.updatedAt.shelfRelativeTime)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            bodyContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if let source = entry.sourceAppName {
                    Text(source)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
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
                        : (isHovered ? Color.primary.opacity(0.055) : Color.primary.opacity(0.035))
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Text("↩ 粘贴")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.itemType.title)，\(entry.preview ?? entry.title ?? "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .file, .folder:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? entry.filePath ?? "文件")
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(entry.filePath ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if entry.contentSize > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: entry.contentSize, countStyle: .file))
                        .font(.system(size: 10.5))
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
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: path as NSString, cost: cost)
        return image
    }
}

/// 本地缩略图加载（经缓存）。
/// side > 0 时为正方形；side == 0 时占满调用方给定的尺寸（需由调用方提供高度）。
/// 用 Color.clear + overlay + clipped 的组合保证 aspect-fill 溢出部分被裁掉，
/// 避免大图按原始尺寸绘制溢出卡片边界。
struct ThumbnailImage: View {
    let path: String?
    let side: CGFloat

    var body: some View {
        Color.clear
            .overlay {
                if let path, let image = ThumbnailCache.shared.image(for: path) {
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
    }
}

extension Date {
    /// Paste 风格相对时间（如「3分钟前」「昨天 14:30」回退为日期）。
    var shelfRelativeTime: String {
        formatted(.relative(presentation: .named))
    }
}
