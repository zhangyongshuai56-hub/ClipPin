import AppKit
import Observation
import SwiftUI

/// 应用外观模式。存储于 UserDefaults，SwiftUI 内容与窗口标题栏 chrome 共用同一份配置。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var stored: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }
}

/// 全局应用状态。只承载跨模块共享的运行时状态，具体业务状态随后续 Phase 进入各自模块。
@MainActor
@Observable
final class AppState {
    /// 暂停剪贴板记录。Phase 1 仅为持久化状态，Phase 4 的 Clipboard Monitor 将读取该值。
    private(set) var isPaused: Bool

    init() {
        isPaused = UserDefaults.standard.bool(forKey: "isPaused")
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        UserDefaults.standard.set(paused, forKey: "isPaused")
    }

    func togglePaused() {
        setPaused(!isPaused)
    }

    var statusBarSymbolName: String {
        isPaused ? "pause.circle.fill" : "doc.on.clipboard"
    }
}
