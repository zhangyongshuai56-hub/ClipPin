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

Rust Core 会在 Xcode 构建时由 `Scripts/build-rust-core.sh` 自动编译并生成 Swift 绑定，
也可手动执行：

```bash
Scripts/build-rust-core.sh Debug    # 或 Release
cd rust-core && cargo test          # Rust 单元测试 + 集成测试
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

Phase 3 已完成（UniFFI 桥接）：

- Rust 侧 `api/ffi.rs`：`AidoPasteDatabase` 对象 + Record/Enum/Error 全量导出（uniffi 0.32，proc-macro 模式）
- Xcode 集成：`Build Rust Core` script phase（cargo 构建 + uniffi-bindgen 生成绑定），
  静态库链接（`-laidopaste_core`），FFI 头文件经 `SWIFT_INCLUDE_PATHS` 提供
- Swift 侧分层：`RustCoreBridge`（领域模型 + UserFacingError 映射）→
  `ClipboardRepository`（actor，全量 Core API）→ `CoreStore`（应用启动初始化）
- 数据库位置：`~/Library/Application Support/AidoPaste/Database/clipboard.db`（WAL）
- 端到端验证：应用启动即创建数据库，日志输出 `rust core ready schema=1`
- 41 个 Rust 测试全绿（含 3 个 FFI 边界测试）

Phase 4 已完成（Clipboard 监听 · Text）：

- `ClipboardMonitor`：0.5s changeCount 检查（O(1)，非高频轮询），读取与入库在后台线程
- §18 防自捕获：应用写入剪贴板产生的变更经抑制表跳过（并发安全）
- §33 来源应用记录；§39 排除应用（内置 1Password / 钥匙串，列表 Phase 11 配置）
- §40 暂停记录（菜单栏开关即时生效）；§51 超 50MB 内容跳过
- 启动时捕获当前剪贴板作为基线；重复内容由 Rust 去重只刷新时间
- 实机验证：复制 A/B/C 入库、再复制 A 去重（时间刷新记录数不变）、暂停时不记录

Phase 5 已完成（Clipboard UI）：

- 主界面（§22）：侧栏分类（全部/置顶/文本/图片/链接/文件）+ 实时搜索栏 + 历史列表 + 详情预览
- `ClipboardViewModel`（@Observable，§56）：列表状态 / 防抖搜索（200ms）/ 键盘导航 / 动作
- 行预览（§34）：类型图标 + 内容预览 + 语言徽章（代码）+ 来源 · 时间；详情（§35）：内容/来源/创建/大小 + 复制/Pin/删除
- 键盘优先（§28）：↑↓ 选择、Enter 复制、Delete 删除、⌘P 置顶、⌘F 搜索、Esc 关窗（NSEvent 本地监听实现）
- 分页（§58）：每页 50 条，滚动到底自动加载；实时刷新：监听入库后列表自动更新（防抖合并）
- 复制（§37 前半）：写剪贴板 + §18 抑制表防自捕获 + 去重 touch 刷新最近使用时间
- 右键菜单（§66）：复制 / Pin / 取消 Pin / 在 Finder 中显示 / 打开链接 / 删除
- GUI 实机验证通过：布局渲染、实时刷新、键盘导航、复制防自捕获、去重 touch

Phase 6 已完成（全局快捷键）：

- `GlobalShortcutManager`：Carbon `RegisterEventHotKey`，默认 ⌘⇧V（§26）
- 快捷键行为：未显示 → 呼出并聚焦搜索；已显示 → 隐藏（toggle）
- 窗口定位（§27）：鼠标所在屏幕 + 鼠标附近，`visibleFrame` 约束（自动避开菜单栏 / Dock / 刘海），越界收敛
- 注册失败可见（被占用 / 系统错误均抛错并记录），设置页展示当前组合
- 实机验证：HID 级 CGEvent 模拟 ⌘⇧V，呼出 / 隐藏 / 再呼出全部通过

Phase 7 已完成（图片支持）：

- 捕获 PNG / TIFF（§19），图片按 §16 以临时文件路径过 FFI，Core 读取字节转存
- `ImageStore`（§20）：原图按内容哈希存 `Images/`，320px PNG 缩略图存 `Thumbnails/`，临时文件 + rename 原子写入
- 去重按图片字节 SHA-256（§17）；删除 / 过期清理 / 历史上限同步清理图片文件（§32）
- UI：列表缩略图、详情大图、复制写回图片、行拖拽导出（§36、§59）
- 48 Rust tests 全绿（含 8 个图片测试）；实机验证捕获→落盘→缩略图→去重→UI 渲染全链路

