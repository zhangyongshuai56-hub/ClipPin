import Foundation
import CryptoKit

// MARK: - 核心错误模型（§82，与 Rust PasteError 一一对应）

/// 原生核心错误；UI 展示一律经 UserFacingError 转换。
enum PasteError: Error {
    case database(String)
    case storage(String)
    case invalidInput(String)
    case notFound(Int64)
    case permissionDenied(String)
    case fileSystem(String)
    case migration(target: Int, message: String)
}

// MARK: - 内容类型规则识别（§19，port of classifier.rs）

/// 判断文本是否是可独立打开的 URL：单行、无空白、http(s)、有主机名。
func isStandaloneURL(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
    guard !trimmed.contains(where: \.isWhitespace) else { return false }
    guard let separatorRange = trimmed.range(of: "://") else { return false }
    let rest = trimmed[separatorRange.upperBound...]
    let host = rest.prefix { !["/", "?", "#"].contains($0) }
    return !host.isEmpty
}

/// 对文本内容做类型细分：URL / Code / Text。
func classifyText(_ text: String) -> ClipboardEntryType {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .text }
    if isStandaloneURL(trimmed) { return .url }
    if detectCodeLanguage(trimmed) != nil { return .code }
    return .text
}

/// 检测代码语言（写入 metadata.language）：JSON 语法校验、shebang、关键词计分（阈值 2）。
/// 平局取计分序列的最后一个（对齐 Rust max_by_key 语义）。
func detectCodeLanguage(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    // JSON：完整语法校验（仅对象 / 数组，与 Rust looks_like_json 一致）
    let looksLikeJSON = (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
        || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    if looksLikeJSON,
       let data = trimmed.data(using: .utf8),
       (try? JSONSerialization.jsonObject(with: data)) != nil {
        return "json"
    }

    // 脚本 shebang
    if trimmed.hasPrefix("#!") { return "shell" }

    let lower = trimmed.lowercased()
    func score(_ markers: [String]) -> Int {
        markers.filter { lower.contains($0) }.count
    }

    let swiftMarkers = ["func ", "let ", "var ", "struct ", "class ", "enum ", "guard ", "extension ", "protocol ", "@main"]
    let pythonMarkers = ["def ", "import ", "from ", "print(", "self.", "__name__", "elif ", "raise "]
    let javascriptMarkers = ["function ", "const ", "=>", "console.log", "document.", "export ", "require(", "async "]
    let sqlMarkers = ["select ", "from ", "where ", "insert into", "update ", "delete from", "join ", "group by"]
    let shellMarkers = ["sudo ", "brew ", "apt ", "cd ", "grep ", "echo ", "export ", "git ", "&&"]

    // 注意平局语义：>= 让后面的候选拿走平局（Rust max_by_key 返回最后一个最大值）
    var bestLanguage = ""
    var bestScore = 0
    for (language, value) in [
        ("swift", score(swiftMarkers)),
        ("python", score(pythonMarkers)),
        ("javascript", score(javascriptMarkers)),
        ("sql", score(sqlMarkers)),
        ("shell", score(shellMarkers)),
    ] {
        if value >= bestScore {
            bestScore = value
            bestLanguage = language
        }
    }
    return bestScore >= 2 ? bestLanguage : nil
}

// MARK: - 内容哈希（§17，port of dedup.rs）

/// 内容字节的 SHA-256 十六进制摘要（CryptoKit，与 Rust sha2 输出一致）。
func sha256Hex(_ data: Data) -> String {
    String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
}

/// 为新条目计算 content_hash：相同内容得到相同哈希，是去重的唯一依据。
func hashForItem(content: String) throws -> String {
    guard !content.isEmpty else {
        throw PasteError.invalidInput("item has no hashable content")
    }
    return sha256Hex(Data(content.utf8))
}
