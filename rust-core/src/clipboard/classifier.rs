//! 内容类型规则识别（§19）。第一阶段只用规则，不引入 AI。

use super::model::ItemType;

/// 判断文本是否是可独立打开的 URL。
pub fn is_url(s: &str) -> bool {
    let trimmed = s.trim();
    let lower = trimmed.to_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return false;
    }
    // 单行、无空白、有主机名才算 URL
    !trimmed.contains(char::is_whitespace)
        && trimmed
            .split_once("://")
            .and_then(|(_, rest)| rest.split(['/', '?', '#']).next())
            .is_some_and(|host| !host.is_empty())
}

/// 对文本内容做类型细分：URL / Code / Text。
pub fn classify_text(text: &str) -> ItemType {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return ItemType::Text;
    }
    if is_url(trimmed) {
        return ItemType::Url;
    }
    if detect_code_language(trimmed).is_some() {
        return ItemType::Code;
    }
    ItemType::Text
}

/// 检测代码语言，返回语言标识（写入 metadata.language）。
/// 规则：JSON 语法校验、shebang、关键词计分（阈值 2，避免把普通句子误判为代码）。
pub fn detect_code_language(text: &str) -> Option<&'static str> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }

    // JSON：完整语法校验
    let looks_like_json = (trimmed.starts_with('{') && trimmed.ends_with('}'))
        || (trimmed.starts_with('[') && trimmed.ends_with(']'));
    if looks_like_json && serde_json::from_str::<serde_json::Value>(trimmed).is_ok() {
        return Some("json");
    }

    // 脚本 shebang
    if trimmed.starts_with("#!") {
        return Some("shell");
    }

    let lower = trimmed.to_lowercase();
    let score = |markers: &[&str]| markers.iter().filter(|m| lower.contains(*m)).count();

    const SWIFT: &[&str] = &[
        "func ",
        "let ",
        "var ",
        "struct ",
        "class ",
        "enum ",
        "guard ",
        "extension ",
        "protocol ",
        "@main",
    ];
    const PYTHON: &[&str] = &[
        "def ", "import ", "from ", "print(", "self.", "__name__", "elif ", "raise ",
    ];
    const JAVASCRIPT: &[&str] = &[
        "function ",
        "const ",
        "=>",
        "console.log",
        "document.",
        "export ",
        "require(",
        "async ",
    ];
    const SQL: &[&str] = &[
        "select ",
        "from ",
        "where ",
        "insert into",
        "update ",
        "delete from",
        "join ",
        "group by",
    ];
    const SHELL: &[&str] = &[
        "sudo ", "brew ", "apt ", "cd ", "grep ", "echo ", "export ", "git ", "&&",
    ];

    let candidates: [(&str, usize); 5] = [
        ("swift", score(SWIFT)),
        ("python", score(PYTHON)),
        ("javascript", score(JAVASCRIPT)),
        ("sql", score(SQL)),
        ("shell", score(SHELL)),
    ];
    let (lang, best) = candidates
        .iter()
        .copied()
        .max_by_key(|(_, s)| *s)
        .unwrap_or(("", 0));
    (best >= 2).then_some(lang)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_plain_urls() {
        assert!(is_url("https://apple.com"));
        assert!(is_url("http://localhost:8080/path?q=1"));
        assert!(!is_url("https://apple.com\nsecond line"));
        assert!(!is_url("visit https://apple.com now"));
        assert!(!is_url("ftp://example.com"));
        assert!(!is_url("https://"));
    }

    #[test]
    fn classifies_url() {
        assert_eq!(classify_text("https://apple.com"), ItemType::Url);
    }

    #[test]
    fn classifies_json() {
        assert_eq!(
            classify_text(r#"{"name": "AidoPaste", "version": 1}"#),
            ItemType::Code
        );
        assert_eq!(detect_code_language(r#"{"a": [1, 2, 3]}"#), Some("json"));
        // 不完整 JSON 不是代码
        assert_eq!(detect_code_language(r#"{"a": "#), None);
    }

    #[test]
    fn classifies_shebang_as_shell() {
        assert_eq!(classify_text("#!/bin/bash\necho hi"), ItemType::Code);
        assert_eq!(
            detect_code_language("#!/usr/bin/env python3"),
            Some("shell")
        );
    }

    #[test]
    fn classifies_swift_code() {
        let code =
            "struct Foo {\n    func bar() -> Int {\n        let x = 1\n        return x\n    }\n}";
        assert_eq!(classify_text(code), ItemType::Code);
        assert_eq!(detect_code_language(code), Some("swift"));
    }

    #[test]
    fn classifies_python_code() {
        let code = "def main():\n    import sys\n    print(sys.argv)\n\nif __name__ == '__main__':\n    main()";
        assert_eq!(classify_text(code), ItemType::Code);
        assert_eq!(detect_code_language(code), Some("python"));
    }

    #[test]
    fn classifies_sql() {
        let sql = "SELECT id, name FROM users WHERE age > 18 ORDER BY name";
        assert_eq!(classify_text(sql), ItemType::Code);
        assert_eq!(detect_code_language(sql), Some("sql"));
    }

    #[test]
    fn plain_prose_stays_text() {
        // 含单个弱关键词的普通句子不应误判
        assert_eq!(
            classify_text("let me know if you need help"),
            ItemType::Text
        );
        assert_eq!(
            classify_text("今天天气不错，适合出去走走。"),
            ItemType::Text
        );
        // "let " + 问号这类组合不应被认成 Swift 代码（"?" 曾是特征词）
        assert_eq!(classify_text("let me know, ok?"), ItemType::Text);
    }

    #[test]
    fn empty_text_stays_text() {
        assert_eq!(classify_text("   "), ItemType::Text);
    }
}
