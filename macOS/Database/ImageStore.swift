import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 图片与缩略图存储（§20，port of image_store.rs）
// 原图按内容哈希命名存入 Images/，缩略图（PNG，最长边 320px）存入 Thumbnails/；
// 数据库只保存路径。写临时文件后 rename，崩溃不会留下半截文件（§48）。

struct StoredImage {
    let imagePath: String
    let thumbnailPath: String?
}

/// 缩略图最长边（§59：列表只加载缩略图，不加载原图）。
private let thumbnailMaxEdge = 320

struct ImageStore {
    private let imagesDirectory: URL
    private let thumbnailsDirectory: URL

    /// 打开（或创建）存储目录结构。
    init(storageRoot: URL) throws {
        imagesDirectory = storageRoot.appendingPathComponent("Images", isDirectory: true)
        thumbnailsDirectory = storageRoot.appendingPathComponent("Thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
    }

    /// 把捕获的图片文件按内容哈希落盘并生成缩略图。
    /// 无法解码的格式（如 HEIC）跳过缩略图，不影响原图保存。
    func store(source: URL, contentHash: String) throws -> StoredImage {
        let extensionName: String = {
            let ext = source.pathExtension.lowercased()
            return ext.isEmpty ? "png" : ext
        }()
        let imagePath = imagesDirectory.appendingPathComponent("\(contentHash).\(extensionName)")
        let temporaryPath = imagesDirectory.appendingPathComponent(".tmp-\(contentHash).\(extensionName)")

        let fileManager = FileManager.default
        // 已存在同哈希产物时跳过转存（幂等；目标可能正被读取，直接覆盖有竞争风险）
        if !fileManager.fileExists(atPath: imagePath.path) {
            try? fileManager.removeItem(at: temporaryPath)
            try fileManager.copyItem(at: source, to: temporaryPath)
            try fileManager.moveItem(at: temporaryPath, to: imagePath)
        } else {
            try? fileManager.removeItem(at: temporaryPath)
        }

        let thumbnailPath = makeThumbnail(source: source, contentHash: contentHash)
        return StoredImage(imagePath: imagePath.path, thumbnailPath: thumbnailPath)
    }

    /// 清扫孤儿产物文件（§48）：不在引用集合中的文件删除。
    /// 一小时内的 `.tmp-` 文件视为进行中的转存，跳过以避免竞争。
    func sweepOrphans(referencedFileNames: Set<String>) throws -> Int {
        var removed = try sweepDirectory(imagesDirectory, referenced: referencedFileNames)
        removed += try sweepDirectory(thumbnailsDirectory, referenced: referencedFileNames)
        return removed
    }

    /// 删除条目对应的图片与缩略图文件（§32）。文件不存在时忽略。
    func remove(imagePath: String?, thumbnailPath: String?) {
        for path in [imagePath, thumbnailPath].compactMap({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - 私有

    private func sweepDirectory(_ directory: URL, referenced: Set<String>) throws -> Int {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
        var removed = 0
        for entry in entries {
            let resource = try? entry.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard resource?.isRegularFile == true else { continue }
            let name = entry.lastPathComponent
            if referenced.contains(name) { continue }
            if name.hasPrefix(".tmp-") {
                let age = resource?.contentModificationDate.map { Date().timeIntervalSince($0) } ?? 0
                if age < 3_600 { continue }
            }
            if (try? fileManager.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// 生成缩略图（ImageIO 下采样 + PNG 编码，临时文件 rename 原子落盘）。
    /// 失败返回 nil，不影响原图。
    private func makeThumbnail(source: URL, contentHash: String) -> String? {
        let thumbnailPath = thumbnailsDirectory.appendingPathComponent("\(contentHash).png")
        let temporaryPath = thumbnailsDirectory.appendingPathComponent(".tmp-\(contentHash).png")
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxEdge,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(
                temporaryPath as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporaryPath)
            return nil
        }
        do {
            if FileManager.default.fileExists(atPath: thumbnailPath.path) {
                try FileManager.default.removeItem(at: thumbnailPath)
            }
            try FileManager.default.moveItem(at: temporaryPath, to: thumbnailPath)
            return thumbnailPath.path
        } catch {
            try? FileManager.default.removeItem(at: temporaryPath)
            return nil
        }
    }
}
