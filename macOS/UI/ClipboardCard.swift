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
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Text(headText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            bodyContent
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            HStack(spacing: 4) {
                Text(entry.updatedAt.clipboardTimestamp)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .frame(height: 112, alignment: .topLeading)
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

    private var headText: String {
        var text = entry.itemType.title
        if entry.itemType == .code, let language = entry.codeLanguage {
            text += " · \(language)"
        }
        if let source = entry.sourceAppName {
            text += " · \(source)"
        }
        return text
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
                Text(entry.url ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .file, .folder:
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title ?? entry.filePath ?? "文件")
                    .fontWeight(.medium)
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

/// 本地缩略图加载（经缓存）。side > 0 时为正方形，否则撑满宽度。
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
                    Rectangle().fill(Color.primary.opacity(0.08))
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side > 0 ? side : nil, height: side > 0 ? side : nil)
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
