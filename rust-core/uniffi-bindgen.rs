//! UniFFI 绑定生成器入口。
//! 用法：cargo run --bin uniffi-bindgen -- generate --library <静态库> --language swift --out-dir <目录>
fn main() {
    uniffi::uniffi_bindgen_main()
}
