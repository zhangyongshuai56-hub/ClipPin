import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// 原生数据层自测（-ClipPinSelfTest）：在临时库上运行关键断言后退出（退出码 0 / 1）。
/// 覆盖原 Rust 测试套的关键路径：迁移、去重 touch、搜索（FTS / LIKE / 软删除过滤）、
/// Pin、软删除与移出文件夹物理删除、编辑重分类与合并、文件夹 CRUD、
/// 清理（上限 / 孤儿文件）、分类器、统计、图片转存、导入导出往返。
/// 跨线程仅经由信号量串行（transferTests 等待后再读结果），@unchecked 成立。
final class PasteSelfTest: @unchecked Sendable {
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
            try transferTests()
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
        expect(try database.schemaVersion() == pasteSchemaVersion, "schema reaches latest")

        // 文本捕获：标题派生 + 分类 + 字节数
        let created = try database.createItem(textEntry("UniFFI 边界测试条目\n第二行")).entry
        expect(created.itemType == .text, "plain text type")
        expect(created.title == "UniFFI 边界测试条目", "title = first non-empty line")
        expect(created.contentSize == Int64("UniFFI 边界测试条目\n第二行".utf8.count), "content size in bytes")

        // 去重 touch：同内容只刷新时间，不新增行
        let firstUpdatedAt = created.updatedAt
        Thread.sleep(forTimeInterval: 0.01)
        let touchedOutcome = try database.createItem(created.toNewItem())
        expect(touchedOutcome.isNew == false, "dedup outcome reports merged")
        let touched = touchedOutcome.entry
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
        let urlEntry = try database.createItem(textEntry("https://developer.apple.com/design/?x=1")).entry
        expect(urlEntry.itemType == .url, "URL classified")
        expect(urlEntry.title == "developer.apple.com", "URL title = host")
        expect(urlEntry.url == "https://developer.apple.com/design/?x=1", "URL normalized to url field")

        // JSON 捕获 → code + metadata.language
        let jsonEntry = try database.createItem(textEntry(#"{"name": "ClipPin", "version": 1}"#)).entry
        expect(jsonEntry.itemType == .code, "JSON classified as code")
        expect(jsonEntry.codeLanguage == "json", "JSON language metadata")

        // 普通句子不误判（曾因 "let " + "?" 误判为 Swift 的回归）
        let prose = try database.createItem(textEntry("let me know if you need help")).entry
        expect(prose.itemType == .text, "prose stays text")

        // 软删除全流程（port of soft_remove_keeps_board_copy_and_purges_on_exit）
        let board = try database.createBoard(name: "工作", color: "#4F8EF7")
        let favorited = try database.createItem(textEntry("收藏内容")).entry
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
        let plain = try database.createItem(textEntry("普通内容")).entry
        expect(try database.removeItemFromHistory(id: plain.id) == .deleted, "unpinned removal deletes")
        expectThrows("deleted item not found", { try database.getItem(id: plain.id) })

        // 导入还原软删除状态
        let restored = try database.createItem(textEntry("备份恢复的条目")).entry
        try database.setItemBoard(id: restored.id, boardId: board.id)
        try database.setRemovedFromHistory(id: restored.id, removed: true)
        expect(!ids(try database.getItems(filter: nil, boardId: nil, limit: 50, offset: 0)).contains(restored.id), "restored flag hides from history")
        expect(try database.getItems(filter: nil, boardId: board.id, limit: 50, offset: 0).count == 1, "restored flag visible in board")
        try database.setRemovedFromHistory(id: restored.id, removed: false)
        expect(ids(try database.getItems(filter: nil, boardId: nil, limit: 50, offset: 0)).contains(restored.id), "clearing flag restores history")
        expectThrows("setRemoved on missing id", { try database.setRemovedFromHistory(id: 999, removed: true) })

        // 编辑：重分类 + 命名标题保留 + 可被新类型搜到
        let edited = try database.createItem(textEntry("普通一句话")).entry
        try database.renameItem(id: edited.id, title: "我的链接")
        let outcome = try database.editTextItem(id: edited.id, newText: "https://unique-edit-target-9x.com")
        expect(!outcome.merged, "edit not merged")
        expect(outcome.entry.itemType == .url, "edit reclassified to url")
        expect(outcome.entry.title == "我的链接", "custom title kept")
        expect(outcome.entry.titleIsCustom, "titleIsCustom set")
        expect(try database.searchItems("unique-edit-target", filter: nil, boardId: nil, limit: 50, offset: 0).count == 1, "edited url searchable")
        expectThrows("edit rejects empty", { try database.editTextItem(id: edited.id, newText: "   ") })

        // 编辑合并进已有重复（组织信息归并到保留行：Pin 不再随合并丢失）
        let keep = try database.createItem(textEntry("独特的内容")).entry
        let willMerge = try database.createItem(textEntry("将被改成重复的草稿")).entry
        try database.pinItem(id: willMerge.id)
        let mergedOutcome = try database.editTextItem(id: willMerge.id, newText: "独特的内容")
        expect(mergedOutcome.merged && mergedOutcome.entry.id == keep.id, "edit merges into duplicate")
        expectThrows("merged row deleted", { try database.getItem(id: willMerge.id) })
        expect(mergedOutcome.entry.isPinned, "merge preserves pin from edited row")

        // 编辑合并继承文件夹：板内条目编辑成与历史条目重复时，保留行应继承该板归属
        // （回归：?5 曾误绑保留行自己的 board_id，COALESCE 成 no-op，继承永不生效）
        let mergeBoard = try database.createBoard(name: "合并继承板", color: "#4F8EF7")
        let historyTwin = try database.createItem(textEntry("待被板内条目合并的历史内容")).entry
        let boardTwin = try database.createItem(textEntry("将被改成重复的板内内容")).entry
        try database.setItemBoard(id: boardTwin.id, boardId: mergeBoard.id)
        let inheritOutcome = try database.editTextItem(id: boardTwin.id, newText: "待被板内条目合并的历史内容")
        expect(inheritOutcome.merged && inheritOutcome.entry.id == historyTwin.id, "edit merges board row into history row")
        let boardMembers = ids(try database.getItems(filter: nil, boardId: mergeBoard.id, limit: 50, offset: 0))
        expect(boardMembers == [historyTwin.id], "merge inherits board from edited row")
        try database.deleteBoard(id: mergeBoard.id)

        // 重新复制软删除条目 → 恢复历史可见（此前 dedup touch 隐藏行，历史无反应）
        let recopied = try database.createItem(textEntry("软删后重新复制")).entry
        try database.setItemBoard(id: recopied.id, boardId: board.id)
        _ = try database.removeItemFromHistory(id: recopied.id)
        expect(!ids(try database.getItems(filter: nil, boardId: nil, limit: 50, offset: 0)).contains(recopied.id),
               "soft-removed hidden before recopy")
        let again = try database.createItem(textEntry("软删后重新复制")).entry
        expect(again.id == recopied.id, "recopy hits dedup row")
        expect(!again.removedFromHistory, "recopy restores history visibility")

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
            let entry = try database.createItem(textEntry("上限测试 \(index)")).entry
            ids.append(entry.id)
        }
        let pinned = try database.createItem(textEntry("上限置顶豁免")).entry
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

        // maxCount <= 0 必须是 no-op（DB 层设防，防调用方误传清空全部历史）
        expect(try database.enforceHistoryLimit(0) == 0, "limit 0 is no-op")
        expect(try database.enforceHistoryLimit(-5) == 0, "negative limit is no-op")
        expect(try database.getItems(filter: nil, boardId: nil, limit: 50, offset: 0).count == 4,
               "limit 0 keeps history intact")

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
        let storedOutcome = try database.createItem(imageEntry)
        let stored = storedOutcome.entry
        expect(storedOutcome.isNew, "image capture inserts new row")
        expect(stored.itemType == .image, "image type forced")
        expect(stored.imagePath != nil && FileManager.default.fileExists(atPath: stored.imagePath!), "image stored")
        expect(stored.thumbnailPath != nil && FileManager.default.fileExists(atPath: stored.thumbnailPath!), "thumbnail generated")

        // 同内容再捕获：哈希命中已有条目，不重复转存
        let touched = try database.createItem(imageEntry).entry
        expect(touched.id == stored.id && touched.imagePath == stored.imagePath, "image dedup idempotent")

        // 无法解码的“图片”：原图照存、无缩略图
        let garbage = sourceDirectory.appendingPathComponent("garbage.png")
        try Data("not an image at all".utf8).write(to: garbage)
        var badEntry = NewClipboardEntry()
        badEntry.itemType = .image
        badEntry.imageSourcePath = garbage.path
        let bad = try database.createItem(badEntry).entry
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

    /// 导入导出往返（async；经独立线程桥接，主线程用信号量等待）。
    private func transferTests() throws {
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread {
            Task {
                do {
                    try await self.runTransferAssertions()
                } catch {
                    self.failures.append("transfer tests threw: \(String(describing: error))")
                }
                semaphore.signal()
            }
        }
        thread.name = "paste-selftest-transfer"
        thread.start()
        if semaphore.wait(timeout: .now() + 30) != .success {
            failures.append("transfer tests timed out")
        }
    }

    private func runTransferAssertions() async throws {
        let source = try ClipboardRepository(inMemoryForTesting: true)
        _ = try await source.create(textEntry("历史区内容"))
        let board = try await source.createBoard(name: "迁移夹", color: "#4F8EF7")
        let boardItem = try await source.create(textEntry("文件夹内容"))
        try await source.setItemBoard(id: boardItem.entry.id, boardId: board.id)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-selftest-\(UUID().uuidString).pasteexport")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let exportSummary = try await LibraryTransfer.exportAll(to: fileURL, repository: source)
        if exportSummary.itemCount != 2 || exportSummary.boardCount != 1 {
            print("  diag: export itemCount=\(exportSummary.itemCount) boardCount=\(exportSummary.boardCount) skipped=\(exportSummary.skippedBrokenCount)")
        }
        expect(exportSummary.itemCount == 2, "export includes history and board items")
        expect(exportSummary.boardCount == 1, "export board count")

        let target = try ClipboardRepository(inMemoryForTesting: true)
        let importSummary = try await LibraryTransfer.importDocument(from: fileURL, repository: target)
        expect(importSummary.itemCount == 2 && importSummary.mergedCount == 0, "import round-trip counts")
        expect(importSummary.boardCount == 1, "import processes board")
        expect(try await target.search("历史区内容", boardId: nil, limit: 10, offset: 0).count == 1,
               "history item round-trips")
        let targetBoards = try await target.boards()
        expect(targetBoards.first?.name == "迁移夹", "board round-trips")
        expect(try await target.items(boardId: targetBoards[0].id, limit: 10, offset: 0).count == 1,
               "board item round-trips")

        // 过新版本拒绝导入（版本门）
        let futureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-selftest-future-\(UUID().uuidString).pasteexport")
        defer { try? FileManager.default.removeItem(at: futureURL) }
        try Data("{\"format\":\"paste-export\",\"version\":99,\"exportedAt\":\"2026-01-01T00:00:00Z\",\"boards\":[]}".utf8)
            .write(to: futureURL)
        do {
            _ = try await LibraryTransfer.importDocument(from: futureURL, repository: target)
            failures.append("future version: expected throw, got success")
            checks += 1
        } catch {
            checks += 1
        }
    }

    private func classifierTests() {
        expect(isStandaloneURL("https://apple.com"), "URL: plain https")
        expect(isStandaloneURL("http://localhost:8080/path?q=1"), "URL: localhost with port")
        expect(!isStandaloneURL("https://apple.com\nsecond line"), "URL: multiline rejected")
        expect(!isStandaloneURL("visit https://apple.com now"), "URL: embedded rejected")
        expect(!isStandaloneURL("ftp://example.com"), "URL: ftp rejected")
        expect(!isStandaloneURL("https://"), "URL: empty host rejected")

        expect(classifyText("https://apple.com") == .url, "classify url")
        expect(classifyText(#"{"name": "ClipPin", "version": 1}"#) == .code, "classify JSON")
        expect(detectCodeLanguage(#"{"a": [1, 2, 3]}"#) == "json", "JSON language")
        expect(detectCodeLanguage(#"{"a": "#) == nil, "incomplete JSON not code")
        expect(classifyText("#!/bin/bash\necho hi") == .code, "shebang is code")
        expect(detectCodeLanguage("#!/usr/bin/env python3") == "python", "shebang python3")
        expect(detectCodeLanguage("#!/bin/zsh") == "shell", "shebang zsh shell")
        expect(detectCodeLanguage("#!env -S bun run dev") == "javascript", "shebang env -S bun")

        let swiftCode = "struct Foo {\n    func bar() -> Int {\n        let x = 1\n        return x\n    }\n}"
        expect(classifyText(swiftCode) == .code && detectCodeLanguage(swiftCode) == "swift", "swift detected")
        let pythonCode = "def main():\n    import sys\n    print(sys.argv)\n\nif __name__ == '__main__':\n    main()"
        expect(classifyText(pythonCode) == .code && detectCodeLanguage(pythonCode) == "python", "python detected")
        let sql = "SELECT id, name FROM users WHERE age > 18 ORDER BY name"
        expect(classifyText(sql) == .code && detectCodeLanguage(sql) == "sql", "sql detected")
        // 散文误判回归：select/from 都是英语常用词，两个词不再足以判成 SQL
        expect(classifyText("Please select from the menu") == .text, "english prose stays text")
        expect(classifyText("今天天气不错，适合出去走走。") == .text, "chinese prose stays text")
        expect(classifyText("   ") == .text, "empty stays text")
    }
}
