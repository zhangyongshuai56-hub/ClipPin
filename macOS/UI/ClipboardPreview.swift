import SwiftUI

/// 选中条目的详情预览（§35）。
struct ClipboardPreview: View {
    let entry: ClipboardEntry
    var viewModel: ClipboardViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: entry.itemType.symbolName)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                contentSection
                infoSection
                actionSection
            }
            .padding(14)
        }
        .id(entry.id)
        .accessibilityLabel("条目详情")
    }

    private var title: String {
        var title = entry.itemType.title
        if entry.itemType == .code, let language = entry.codeLanguage {
            title += " · \(language)"
        }
        return title
    }

    // MARK: - 内容（§35、§59）

    private var contentText: String {
        entry.textContent ?? entry.url ?? entry.filePath ?? ""
    }

    @ViewBuilder
    private var contentSection: some View {
        if entry.itemType == .image {
            // 详情展示较大缩略图；复制时写回原图
            ThumbnailImage(path: entry.thumbnailPath ?? entry.imagePath, side: 232)
                .frame(maxWidth: .infinity)
        } else {
            Text(contentText)
                .font(.system(size: 12, design: entry.itemType == .code ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(16)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - 元信息（§35）

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("来源", value: entry.sourceAppName ?? entry.sourceApp ?? "未知")
            LabeledContent("创建", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: entry.contentSize, countStyle: .file))
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 动作（§66）

    private var actionSection: some View {
        VStack(spacing: 8) {
            Button {
                viewModel.copyToPasteboard(entry)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.togglePin(entry) }
                } label: {
                    Label(entry.isPinned ? "取消 Pin" : "Pin", systemImage: "pin")
                }
                if entry.itemType == .url {
                    Button("打开链接") { viewModel.openLink(entry) }
                }
                if entry.itemType == .file || entry.itemType == .folder {
                    Button("在 Finder 中显示") { viewModel.revealInFinder(entry) }
                }
                Spacer(minLength: 0)
                Button("删除", role: .destructive) {
                    Task { await viewModel.delete(entry) }
                }
            }
        }
    }
}
