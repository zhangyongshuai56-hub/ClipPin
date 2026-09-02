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

## 当前状态

Phase 1 已完成：

- 菜单栏常驻应用（无 Dock 图标、启动不显示主窗口）
- 菜单：打开剪贴板 / 搜索剪贴板 / 暂停记录 / 设置 / 退出
- 基础剪贴板窗口（900×650，含空状态占位）
- 设置窗口：登录启动（SMAppService）、主题（跟随系统 / 浅色 / 深色）、关于
- 明暗色使用系统语义颜色
