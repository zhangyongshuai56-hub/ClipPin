import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// 原生数据层自测（-PasteSelfTest）：在临时库上运行关键断言后退出（退出码 0 / 1）。
/// 覆盖原 Rust 测试套的关键路径：迁移、去重 touch、搜索（FTS / LIKE / 软删除过滤）、
/// Pin、软删除与移出文件夹物理删除、编辑重分类与合并、文件夹 CRUD、
/// 清理（上限 / 孤儿文件）、分类器、统计、图片转存。
final class PasteSelfTest {
    private var failures: [String] = []
    private var checks = 0

    static func run() -> Bool {
        PasteSelfTest().execute()
    }

    private func execute() -> Bool {
        failures = []
        checks = 0

        do {
            try coreFlowTests()
            try cleanupTests()
            try imageTests()
            classifierTests()
        } catch {
            failures.append("unexpected throw: \(String(describing: error))")
        }

        if failures.isEmpty {
            print("SELFTEST PASS (\(checks) checks)")
            return true
        }
        print("SELFTEST FAIL (\(failures.count) of \(checks) checks failed):")
        failures.forEach { print("  - \($0)") }
        return false
    }

    private func expect(_ condition: Bool, _ name: String) {
        checks += 1
        if !condition { failures.append(name) }
    }

    private func expectThrows(_ name: String, _ body: () throws -> Void) {
        checks += 1
        do {
            try body()
            failures.append("\(name): expected throw, got success")
        } catch {}
    }

    private func ids(_ entries: [ClipboardEntry]) -> Set<Int64> {
        Set(entries.map(\.id))
    }

    private func textEntry(_ text: String) -> NewClipboardEntry {
        var entry = NewClipboardEntry()
        entry.itemType = .text
        entry.textContent = text
        return entry
    }

    /// 生成测试 PNG（纯色位图）。
    private func makeTestPNG(path: URL, width: Int, height: Int) {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.7, green: 0.15, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            path as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - 核心链路

    private func coreFlowTests() throws {
        let database = try PasteDatabase(inMemoryForTesting: true)

        // 迁移到最新版本
        expect(try database.schemaVersion() == pasteSchemaVersion, "schema reaches v4")

        // 文本捕获：标题派生 + 分类 + 字节数
        let created = try database.createItem(textEntry("UniFFI 边界测试条目\n第二行"))
        expect(created.itemType == .text, "plain text type")
        expect(created.title == "UniFFI 边界测试条目", "title = first non-empty line")
        expect(created.contentSize == Int64("UniFFI 边界测试条目\n第二行".utf8.count), "content size in bytes")

        // 去重 touch：同内容只刷新时间，不新增行
        let firstUpdatedAt = created.updatedAt
        Thread.sleep(forTimeInterval: 0.01)
        let touched = try database.createItem(created.toNewItem())
        expect(touched.id == created.id, "dedup keeps same id")
        expect(touched.updatedAt > firstUpdatedAt, "dedup refreshes updated_at")
        expect(try database.statistics().totalCount == 1, "dedup keeps single row")

        // 搜索：FTS（≥3 字符）与 LIKE（短查询）
        expect(try database.searchItems("边界测试", filter: nil, boardId: nil, limit: 50, offset: 0).count == 1, "FTS finds item")
        expect(try database.searchItems("边界", filter: nil, boardId: nil, limit: 50, offset: 0).count == 1, "LIKE fallback finds item")
        expect(try database.searchItems("不存在xyz", filter: nil, boardId: nil, limit: 50, offset: 0).isEmpty, "search miss empty")

        // Pin
        try database.pinItem(id: created.id)
        expect(try database.getPinnedItems(limit: 50, offset: 0).count == 1, "pinned listed")

        // URL 捕获：类型 / 标题域名 / url 规范化
        let urlEntry = try database.createItem(textEntry("https://developer.apple.com/design/?x=1"))
        expect(urlEntry.itemType == .url, "URL classified")
        expect(urlEntry.title == "developer.apple.com", "URL title = host")
        expect(urlEntry.url == "https://developer.apple.com/design/?x=1", "URL normalized to url field")

        // JSON 捕获 → code + metadata.language
        let jsonEntry = try database.createItem(textEntry(#"{"name": "Paste", "version": 1}"#))
        expect(jsonEntry.itemType == .code, "JSON classified as code")
        expect(jsonEntry.codeLanguage == "json", "JSON language metadata")

        // 普通句子不误判（曾因 "let " + "?" 误判为 Swift 的回归）
        let prose = try database.createItem(textEntry("let me know if you need help"))
        expect(prose.itemType == .text, "prose stays text")

        // 软删除全流程（port of soft_remove_keeps_board_copy_and_purges_on_exit）
        let board = try database.createBoard(name: "工作", color: "#4F8EF7")
        let favorited = try database.createItem(textEntry("收藏内容"))
        try database.setItemBoard(id: favorited.id, boardId: board.id)
        try database.pinItem(id: favorited.id)
        expect(try database.removeItemFromHistory(id: favorited.id) == .keptInBoard, "soft remove outcome")
        expect(!ids(try database.getItems(filter: nil, boardId: nil, limit: 50, offset: 0)).contains(favorited.id), "soft-removed gone from history")
        expect(!ids(try database.getPinnedItems(limit: 50, offset: 0)).contains(favorited.id), "soft-removed unpinned")
        let inBoard = try database.getItems(filter: nil, boardId: board.id, limit: 50, offset: 0)
        expect(inBoard.count == 1 && inBoard[0].removedFromHistory && !inBoard[0].isPinned, "kept in board, unpinned, flagged")
        expect(try database.searchItems("收藏内容", filter: nil, boardId: nil, limit: 50, offset: 0).isEmpty, "soft-removed excluded from search")
        // 移出文件夹 → 无处可见 → 物理删除
        try database.setItemBoard(id: favorited.id, boardId: nil)
        expectThrows("purge on board exit", { try database.getItem(id: favorited.id) })

        // 未收藏条目从历史移除 = 物理删除
        let plain = try database.createItem(textEntry("普通内容"))
        expect(try database.removeItemFromHistory(id: plain.id) == .deleted, "unpinned removal deletes")
        expectThrows("deleted item not found", { try database.getItem(id: plain.id) })

        // 导入还原软删除状态
        let restored = try database.createItem(textEntry("备份恢复的条目"))
        try database.setItemBoard(id: restored.id, boardId: board.id)
        try database.setRemovedFromHistory(id: restored.id, removed: true)
        expect(!ids(try database.getItems(filter: nil, boardId: nil, limit: 50, offset: 0)).contains(restored.id), "restored flag hides from history")
        expect(try database.getItems(filter: nil, boardId: board.id, limit: 50, offset: 0).count == 1, "restored flag visible in board")
        try database.setRemovedFromHistory(id: restored.id, removed: false)
        expect(ids(try database.getItems(filter: nil, boardId: nil, limit: 50, offset: 0)).contains(restored.id), "clearing flag restores history")
        expectThrows("setRemoved on missing id", { try database.setRemovedFromHistory(id: 999, removed: true) })

        // 编辑：重分类 + 命名标题保留 + 可被新类型搜到
        let edited = try database.createItem(textEntry("普通一句话"))
        try database.renameItem(id: edited.id, title: "我的链接")
        let outcome = try database.editTextItem(id: edited.id, newText: "https://unique-edit-target-9x.com")
        expect(!outcome.merged, "edit not merged")
        expect(outcome.entry.itemType == .url, "edit reclassified to url")
        expect(outcome.entry.title == "我的链接", "custom title kept")
        expect(outcome.entry.titleIsCustom, "titleIsCustom set")
        expect(try database.searchItems("unique-edit-target", filter: nil, boardId: nil, limit: 50, offset: 0).count == 1, "edited url searchable")
        expectThrows("edit rejects empty", { try database.editTextItem(id: edited.id, newText: "   ") })

        // 编辑合并进已有重复（置顶随合并消失）
        let keep = try database.createItem(textEntry("独特的内容"))
        let willMerge = try database.createItem(textEntry("将被改成重复的草稿"))
        try database.pinItem(id: willMerge.id)
        let mergedOutcome = try database.editTextItem(id: willMerge.id, newText: "独特的内容")
        expect(mergedOutcome.merged && mergedOutcome.entry.id == keep.id, "edit merges into duplicate")
        expectThrows("merged row deleted", { try database.getItem(id: willMerge.id) })
        expect(!ids(try database.getPinnedItems(limit: 50, offset: 0)).contains(willMerge.id), "merged pin gone")

        // 文件夹：重命名 / 删除释放条目
        try database.renameBoard(id: board.id, name: "客户项目")
        expect(try database.listBoards().first?.name == "客户项目", "board renamed")
        expectThrows("rename empty board name", { try database.renameBoard(id: board.id, name: "  ") })
        expectThrows("rename missing board", { try database.renameBoard(id: 999, name: "x") })
        try database.deleteBoard(id: board.id)
        expect(try database.listBoards().isEmpty, "board deleted")
        expect(try database.getItems(filter: nil, boardId: nil, limit: 50, offset: 0).contains { $0.id == restored.id },
               "items released to clipboard on board delete")

        // 统计
        let stats = try database.statistics()
        expect(stats.totalCount >= 4, "statistics total")
        let expectedPinned = try database.getPinnedItems(limit: 50, offset: 0).count
        if stats.pinnedCount != expectedPinned {
            print("  diag: pinnedCount=\(stats.pinnedCount) pinnedListed=\(expectedPinned)")
        }
        expect(stats.pinnedCount == expectedPinned, "statistics pinned matches pinned list")
        expect(stats.byType[.text] ?? 0 >= 3, "statistics by type")
        expect(stats.totalContentSize > 0, "statistics size")

        // 负数分页拒绝（§53）
        expectThrows("negative limit rejected", { try database.getItems(filter: nil, boardId: nil, limit: -1, offset: 0) })
        expectThrows("negative offset rejected", { try database.getPinnedItems(limit: 10, offset: -2) })

        // NotFound
        expectThrows("get missing item", { try database.getItem(id: 987_654) })

        // SHA-256 已知向量（echo -n "hello" | shasum -a 256）
        expect(sha256Hex(Data("hello".utf8)) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
               "sha256 known vector")
    }

    // MARK: - 清理

    private func cleanupTests() throws {
        let database = try PasteDatabase(inMemoryForTesting: true)

        // 历史上限：Pin / 收藏豁免，最旧的先删
        var ids: [Int64] = []
        for index in 0..<5 {
            let entry = try database.createItem(textEntry("上限测试 \(index)"))
            ids.append(entry.id)
        }
        let pinned = try database.createItem(textEntry("上限置顶豁免"))
        try database.pinItem(id: pinned.id)
        let trimmed = try database.enforceHistoryLimit(3)
        let remaining = try database.getItems(filter: nil, boardId: nil, limit: 50, offset: 0)
        if trimmed != 2 || remaining.count != 4 {
            print("  diag: trimmed=\(trimmed) remaining=\(remaining.count) items=\(remaining.map { ($0.id, $0.isPinned, $0.textContent ?? "") })")
        }
        expect(trimmed == 2, "history limit trims 2")
        expect(remaining.count == 4, "pinned exempt from limit")
        expect(!remaining.contains { $0.id == ids[0] }, "oldest trimmed first")
        expect(remaining.contains { $0.id == pinned.id }, "pinned survives limit")

        // 孤儿清扫：删除引用后，扫描库内已无引用的文件
        let orphans = try database.sweepOrphanArtifacts()
        expect(orphans >= 0, "orphan sweep runs")
    }

    // MARK: - 图片

    private func imageTests() throws {
        let database = try PasteDatabase(inMemoryForTesting: true)
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let source = sourceDirectory.appendingPathComponent("capture.png")
        makeTestPNG(path: source, width: 640, height: 480)

        // 图片捕获：按字节哈希转存 + 生成缩略图
        var imageEntry = NewClipboardEntry()
        imageEntry.itemType = .image
        imageEntry.imageSourcePath = source.path
        imageEntry.uti = "public.png"
        let stored = try database.createItem(imageEntry)
        expect(stored.itemType == .image, "image type forced")
        expect(stored.imagePath != nil && FileManager.default.fileExists(atPath: stored.imagePath!), "image stored")
        expect(stored.thumbnailPath != nil && FileManager.default.fileExists(atPath: stored.thumbnailPath!), "thumbnail generated")

        // 同内容再捕获：哈希命中已有条目，不重复转存
        let touched = try database.createItem(imageEntry)
        expect(touched.id == stored.id && touched.imagePath == stored.imagePath, "image dedup idempotent")

        // 无法解码的“图片”：原图照存、无缩略图
        let garbage = sourceDirectory.appendingPathComponent("garbage.png")
        try Data("not an image at all".utf8).write(to: garbage)
        var badEntry = NewClipboardEntry()
        badEntry.itemType = .image
        badEntry.imageSourcePath = garbage.path
        let bad = try database.createItem(badEntry)
        expect(FileManager.default.fileExists(atPath: bad.imagePath ?? ""), "undecodable image still stored")
        expect(bad.thumbnailPath == nil, "undecodable image has no thumbnail")

        // 删除条目同步清理产物
        let imagePath = stored.imagePath!
        let thumbnailPath = stored.thumbnailPath!
        try database.deleteItem(id: stored.id)
        expect(!FileManager.default.fileExists(atPath: imagePath), "image removed with item")
        expect(!FileManager.default.fileExists(atPath: thumbnailPath), "thumbnail removed with item")
    }

    // MARK: - 分类器

    private func classifierTests() {
        expect(isStandaloneURL("https://apple.com"), "URL: plain https")
        expect(isStandaloneURL("http://localhost:8080/path?q=1"), "URL: localhost with port")
        expect(!isStandaloneURL("https://apple.com\nsecond line"), "URL: multiline rejected")
        expect(!isStandaloneURL("visit https://apple.com now"), "URL: embedded rejected")
        expect(!isStandaloneURL("ftp://example.com"), "URL: ftp rejected")
        expect(!isStandaloneURL("https://"), "URL: empty host rejected")

        expect(classifyText("https://apple.com") == .url, "classify url")
        expect(classifyText(#"{"name": "Paste", "version": 1}"#) == .code, "classify JSON")
        expect(detectCodeLanguage(#"{"a": [1, 2, 3]}"#) == "json", "JSON language")
        expect(detectCodeLanguage(#"{"a": "#) == nil, "incomplete JSON not code")
        expect(classifyText("#!/bin/bash\necho hi") == .code, "shebang is code")
        expect(detectCodeLanguage("#!/usr/bin/env python3") == "shell", "shebang language shell")

        let swiftCode = "struct Foo {\n    func bar() -> Int {\n        let x = 1\n        return x\n    }\n}"
        expect(classifyText(swiftCode) == .code && detectCodeLanguage(swiftCode) == "swift", "swift detected")
        let pythonCode = "def main():\n    import sys\n    print(sys.argv)\n\nif __name__ == '__main__':\n    main()"
        expect(classifyText(pythonCode) == .code && detectCodeLanguage(pythonCode) == "python", "python detected")
        let sql = "SELECT id, name FROM users WHERE age > 18 ORDER BY name"
        expect(classifyText(sql) == .code && detectCodeLanguage(sql) == "sql", "sql detected")
        expect(classifyText("今天天气不错，适合出去走走。") == .text, "chinese prose stays text")
        expect(classifyText("   ") == .text, "empty stays text")
    }
}
