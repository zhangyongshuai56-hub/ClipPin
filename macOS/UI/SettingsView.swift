import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AboutSettingsView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 280)
    }
}

/// 通用设置：登录启动（SMAppService）、外观主题、快捷键展示。
private struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var launchAtLoginErrorMessage: String?

    var body: some View {
        Form {
            Section("启动") {
                Toggle(
                    "登录时启动 AidoPaste",
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { desired in
                            do {
                                try LaunchAtLoginService.setEnabled(desired)
                                launchAtLogin = desired
                            } catch {
                                // 失败必须可见：回滚开关并给出原因
                                launchAtLogin = !desired
                                launchAtLoginErrorMessage = error.localizedDescription
                            }
                        }
                    )
                )
            }
            Section("外观") {
                Picker("主题", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceRaw) {
                    WindowManager.shared.applyAppearanceToAllWindows()
                }
            }
            Section("快捷键") {
                LabeledContent("打开剪贴板", value: "⌘ ⇧ V")
                Text("自定义全局快捷键将在后续版本提供。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
        .onAppear {
            launchAtLogin = LaunchAtLoginService.isEnabled
        }
        .alert(
            "无法更新登录启动设置",
            isPresented: Binding(
                get: { launchAtLoginErrorMessage != nil },
                set: { if !$0 { launchAtLoginErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(launchAtLoginErrorMessage ?? "")
        }
    }
}

/// 关于页：版本与构建号。
private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("AidoPaste")
                .font(.title2).bold()
            Text("版本 \(BundleInfo.version)（\(BundleInfo.build)）")
                .foregroundStyle(.secondary)
            Text("本地优先的 macOS 剪贴板管理器")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(AppearanceMode.stored.colorScheme)
    }
}

private enum BundleInfo {
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
    }
}
