# AidoPaste

本地优先的 macOS 原生剪贴板管理器（参考 Paste 的产品理念，自主实现）。

## 技术架构

- **前端**：SwiftUI + AppKit，macOS 15.0+，仅支持 Apple Silicon
- **核心**：Rust Core（数据模型 / 去重 / 分类 / 搜索 / 清理）
- **存储**：SQLite（FTS5 全文搜索），图片与缩略图存文件系统
- **桥接**：UniFFI（Swift ↔ Rust），禁止 HTTP / WebSocket 方案

开发按 Phase 推进：Phase 1 macOS 基础 → Phase 2 Rust Core → Phase 3 UniFFI → Phase 4 Clipboard → ……

## 构建

```bash
xcodebuild -scheme AidoPaste -configuration Debug -derivedDataPath .build/DerivedData build
```

产品输出：`.build/DerivedData/Build/Products/Debug/AidoPaste.app`

## Rust Core

```bash
cd rust-core
cargo test                          # 单元测试 + 集成测试
cargo clippy --all-targets -- -D warnings
cargo fmt
```

## 当前状态

Phase 1 已完成：

- 菜单栏常驻应用（无 Dock 图标、启动不显示主窗口）
- 菜单：打开剪贴板 / 搜索剪贴板 / 暂停记录 / 设置 / 退出
- 基础剪贴板窗口（900×650，含空状态占位）
- 设置窗口：登录启动（SMAppService）、主题（跟随系统 / 浅色 / 深色）、关于
- 明暗色使用系统语义颜色

Phase 2 已完成（`rust-core/`，独立 crate `aidopaste-core`）：

- `ClipboardItem` 数据模型 + 规则分类器（URL / JSON / Swift / Python / JS / SQL / Shell）
- SHA-256 content_hash 去重：重复复制只刷新时间与来源，保留 Pin
- SQLite（WAL + busy_timeout）：`user_version` 迁移框架、FTS5 trigram 全文索引（中英文子串）
- 搜索：≥3 字符走 FTS5，短查询回退 LIKE；类型过滤 + 分页
- CRUD / Pin / 批量删除 / 过期清理（1/7/30/90 天/永不）/ 历史条数上限 / 统计
- 38 个单元 + 集成测试全绿；clippy 零警告；rustfmt 通过

