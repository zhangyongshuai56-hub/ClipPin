import AppKit
import SwiftUI

/// 单条历史记录（§34）：类型图标 / 缩略图 + 内容预览 + 来源与时间。
struct ClipboardRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            leadingVisual
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 2) {
                primaryText
                    .lineLimit(2)
                    .font(.system(size: 13))
                HStack(spacing: 5) {
                    if let language = entry.codeLanguage {
                        Text(language)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.secondary)
                    }
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
    }

    // MARK: - 行首视觉（§34、§59）

    @ViewBuilder
    private var leadingVisual: some View {
        if entry.itemType == .image {
            // 列表只加载缩略图（§59），原图在详情按需展示
            ThumbnailImage(path: entry.thumbnailPath ?? entry.imagePath, side: 42)
        } else {
            Image(systemName: entry.itemType.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 20)
        }
    }

    // MARK: - 内容预览（§34）

    @ViewBuilder
    private var primaryText: some View {
        switch entry.itemType {
        case .url:
            Text(entry.title ?? entry.url ?? "链接")
                .fontWeight(.medium)
        case .file, .folder:
            Text(entry.title ?? entry.filePath ?? "文件")
                .fontWeight(.medium)
        case .image:
            Text("图片")
                .foregroundStyle(.secondary)
        case .code:
            Text(entry.preview ?? entry.textContent ?? "")
                .font(.system(size: 13, design: .monospaced))
        default:
            Text(entry.preview ?? entry.textContent ?? "")
        }
    }

    private var metaLine: String {
        [entry.sourceAppName, entry.updatedAt.clipboardTimestamp]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// 缩略图内存缓存（§57、§83）：列表滚动时行会反复重绘，
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
struct ThumbnailImage: View {
    let path: String?
    let side: CGFloat

    var body: some View {
        Group {
            if let path, let image = ThumbnailCache.shared.image(for: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("图片预览")
    }
}

extension Date {
    /// 列表时间显示：今天只显示时间，其它日期带日期。
    var clipboardTimestamp: String {
        if Calendar.current.isDateInToday(self) {
            formatted(date: .omitted, time: .shortened)
        } else {
            formatted(date: .abbreviated, time: .shortened)
        }
    }
}
