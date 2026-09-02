#!/bin/bash
# 构建 Rust Core 并生成 Swift 绑定。
# 由 Xcode 的 "Build Rust Core" Run Script Phase 调用，也可手动执行：
#   Scripts/build-rust-core.sh [Debug|Release]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCROOT="${SRCROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIGURATION="${CONFIGURATION:-${1:-Debug}}"

# Xcode GUI 环境的 PATH 通常不含 cargo
export PATH="$HOME/.cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

PROFILE="debug"
if [ "$CONFIGURATION" = "Release" ]; then
  PROFILE="release"
fi

OUT_DIR="$SRCROOT/.build/rust/$CONFIGURATION"
GEN_DIR="$SRCROOT/macOS/Bridge/Generated"
RUST_DIR="$SRCROOT/rust-core"

cd "$RUST_DIR"
cargo build

# 生成绑定（幂等）：Swift 文件进源码树（fileSystemSynchronizedGroups 自动纳入编译），
# 头文件与 modulemap 拷贝到 OUT_DIR 供 SWIFT_INCLUDE_PATHS 查找
cargo run --quiet --bin uniffi-bindgen -- generate \
  --library "target/$PROFILE/libaidopaste_core.a" \
  --language swift \
  --out-dir "$GEN_DIR"

mkdir -p "$OUT_DIR"
cp "target/$PROFILE/libaidopaste_core.a" "$OUT_DIR/libaidopaste_core.a"
cp "$GEN_DIR/AidoPasteCoreFFI.h" "$OUT_DIR/"
# Swift ClangImporter 只自动发现名为 module.modulemap 的文件，需按此名提供
cp "$GEN_DIR/AidoPasteCoreFFI.modulemap" "$OUT_DIR/module.modulemap"

echo "rust core ready: $OUT_DIR"
