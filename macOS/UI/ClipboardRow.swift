import SwiftUI

/// 单条历史记录（§34）：类型图标 + 内容预览 + 来源与时间。
struct ClipboardRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.itemType.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 20)
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
