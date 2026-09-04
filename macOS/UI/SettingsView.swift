import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ClipboardSettingsView()
                .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }
            PrivacySettingsView()
                .tabItem { Label("隐私", systemImage: "hand.raised") }
            AboutSettingsView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 430)
    }
}

/// 通用设置：登录启动（SMAppService）、外观主题、快捷键展示、辅助功能权限。
private struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var accessibilityTrusted = PasteService.shared.isAccessibilityTrusted
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
            Section("权限") {
                LabeledContent("辅助功能（自动粘贴）", value: accessibilityTrusted ? "✓ 已授权" : "⚠️ 未授权")
                if !accessibilityTrusted {
                    Button("打开系统设置") {
                        PasteService.shared.openAccessibilitySettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
        .onAppear {
            launchAtLogin = LaunchAtLoginService.isEnabled
            accessibilityTrusted = PasteService.shared.isAccessibilityTrusted
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

/// 剪贴板设置（§49）：自动清理、历史上限、保存内容开关、单条大小上限。
/// 全部写入 UserDefaults，监听与调度即时读取生效。
private struct ClipboardSettingsView: View {
    @State private var currentCombo: HotKeyCombo = .stored
    @State private var isRecording = false
    @State private var keyMonitor: Any?
    @State private var recordingHint = "点击「更改」后按下新的组合键（Esc 取消）"
    @State private var shortcutErrorMessage: String?
    @AppStorage(CleanupSettings.retentionKey) private var retentionRaw = RetentionPolicy.thirtyDays.rawValue
    @AppStorage(CleanupSettings.historyLimitKey) private var historyLimit = 1000
    @AppStorage(CaptureSettings.maxItemSizeKey) private var maxItemSize = 50 * 1024 * 1024
    @AppStorage(CaptureSettings.saveImagesKey) private var saveImages = true
    @AppStorage(CaptureSettings.saveFilesKey) private var saveFiles = true
    @AppStorage(CaptureSettings.saveURLsKey) private var saveURLs = true

    private let historyLimits: [(Int, String)] = [
        (100, "100 条"),
        (500, "500 条"),
        (1000, "1000 条"),
        (5000, "5000 条"),
        (0, "不限"),
    ]

    private let itemSizes: [(Int, String)] = [
        (5 * 1024 * 1024, "5 MB"),
        (10 * 1024 * 1024, "10 MB"),
        (50 * 1024 * 1024, "50 MB"),
        (100 * 1024 * 1024, "100 MB"),
    ]

    @AppStorage(PasteSettings.defaultActionKey) private var defaultActionRaw = DefaultPasteAction.activeApp.rawValue
    @AppStorage(PasteSettings.plainTextKey) private var alwaysPlainText = false

    var body: some View {
        Form {
            Section("全局快捷键") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("呼出剪贴板").font(.system(size: 13))
                        Text(recordingHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(isRecording ? "按下新组合键…" : currentCombo.displayString)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(minWidth: 110)
                        .multilineTextAlignment(.center)
                        .background(
                            isRecording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .overlay {
                            if isRecording {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            }
                        }
                    Button(isRecording ? "取消" : "更改") {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    }
                    Button("恢复默认") {
                        applyShortcut(.defaultOpenClipboard)
                    }
                }
                .onAppear { currentCombo = .stored }
            }
            Section("粘贴项目") {
                Picker("默认操作", selection: $defaultActionRaw) {
                    Text(DefaultPasteAction.activeApp.title).tag(DefaultPasteAction.activeApp.rawValue)
                    Text(DefaultPasteAction.clipboard.title).tag(DefaultPasteAction.clipboard.rawValue)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: defaultActionRaw) {
                    Task { await CleanupScheduler.shared.runOnce() }
                }
                Text(DefaultPasteAction(rawValue: defaultActionRaw)?.detail ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("始终以纯文本粘贴", isOn: $alwaysPlainText)
            }
            Section("自动清理") {
                Picker("保留时长", selection: $retentionRaw) {
                    ForEach(RetentionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy.rawValue)
                    }
                }
                Picker("历史上限", selection: $historyLimit) {
                    ForEach(historyLimits, id: \.0) { limit, title in
                        Text(title).tag(limit)
                    }
                }
                Text("超出上限时从最旧的非置顶记录开始清理；置顶记录永不自动清理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("保存内容") {
                Toggle("保存图片", isOn: $saveImages)
                Toggle("保存文件与文件夹", isOn: $saveFiles)
                Toggle("保存 URL", isOn: $saveURLs)
                Picker("单条大小上限", selection: $maxItemSize) {
                    ForEach(itemSizes, id: \.0) { size, title in
                        Text(title).tag(size)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: retentionRaw) {
            Task { await CleanupScheduler.shared.runOnce() }
        }
        .onChange(of: historyLimit) {
            Task { await CleanupScheduler.shared.runOnce() }
        }
    }
}

/// 隐私设置（§39、§40）：暂停记录、排除应用管理。
private struct PrivacySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var userExcluded: [String] = ExcludedApps.userDefined.sorted()
    @State private var newBundleID = ""

    var body: some View {
        Form {
            Section("记录") {
                Toggle(
                    "暂停记录剪贴板",
                    isOn: Binding(
                        get: { appState.isPaused },
                        set: { appState.setPaused($0) }
                    )
                )
                Text("暂停期间不记录任何新内容，菜单栏图标会同步变化。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("内置排除应用") {
                ForEach(ExcludedApps.builtIn.sorted(), id: \.self) { bundleID in
                    LabeledContent(bundleID, value: "内置")
                }
                Text("这些应用前台时不会记录剪贴板（如密码管理器）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("自定义排除应用") {
                ForEach(userExcluded, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                        Spacer()
                        Button("移除") {
                            ExcludedApps.removeUser(bundleID)
                            refresh()
                        }
                    }
                }
                HStack {
                    TextField("com.example.app", text: $newBundleID)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        ExcludedApps.addUser(newBundleID)
                        newBundleID = ""
                        refresh()
                    }
                    .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("按 Bundle ID 添加；这些应用前台时剪贴板不会被记录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func refresh() {
        userExcluded = ExcludedApps.userDefined.sorted()
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


// MARK: - 全局快捷键录制（设置页）

extension ClipboardSettingsView {
    private func startRecording() {
        guard keyMonitor == nil else { return }
        isRecording = true
        recordingHint = "按下新的组合键（需包含 ⌘ / ⌃ / ⌥，Esc 取消）"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc 取消录制
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var carbon: UInt32 = 0
            if mods.contains(.command) { carbon |= UInt32(cmdKey) }
            if mods.contains(.shift) { carbon |= UInt32(shiftKey) }
            if mods.contains(.option) { carbon |= UInt32(optionKey) }
            if mods.contains(.control) { carbon |= UInt32(controlKey) }

            // 安全要求：全局热键必须含 ⌘/⌃/⌥ 之一，避免裸字母键吞掉正常输入
            guard carbon & UInt32(cmdKey | controlKey | optionKey) != 0 else {
                recordingHint = "组合键需包含 ⌘ / ⌃ / ⌥ 之一，再试一次"
                return nil
            }

            let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: carbon)
            applyShortcut(combo)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        isRecording = false
        recordingHint = "点击「更改」后按下新的组合键（Esc 取消）"
    }

    /// 应用新快捷键：注册成功才持久化；失败（冲突等）自动回滚原组合并提示。
    private func applyShortcut(_ combo: HotKeyCombo) {
        do {
            try GlobalShortcutManager.shared.register(combo) {
                WindowManager.shared.toggleClipboardWindow()
            }
            HotKeyCombo.save(combo)
            currentCombo = combo
            recordingHint = "点击「更改」后按下新的组合键（Esc 取消）"
        } catch {
            // 注册失败（如组合被占用）：恢复之前的组合
            try? GlobalShortcutManager.shared.register(.stored) {
                WindowManager.shared.toggleClipboardWindow()
            }
            shortcutErrorMessage = error.localizedDescription
        }
    }
}
