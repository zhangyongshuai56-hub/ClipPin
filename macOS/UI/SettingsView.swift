import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ClipboardSettingsView()
                .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }
            DataSettingsView()
                .tabItem { Label("数据", systemImage: "externaldrive") }
            PrivacySettingsView()
                .tabItem { Label("隐私", systemImage: "hand.raised") }
            AboutSettingsView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 430)
    }
}

/// 数据（导入 / 导出）：文件夹与记录迁移到另一台电脑。
private struct DataSettingsView: View {
    @State private var isBusy = false
    @State private var resultMessage: String?
    @State private var failureMessage: String?

    var body: some View {
        Form {
            Section("导出") {
                Text("把剪贴板历史与全部文件夹及其中的记录导出为一个 .pasteexport 文件（图片一并打包），拷贝到另一台电脑的 Paste 中导入即可。文件与文件夹类记录只保存引用，不打包文件本体。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("导出全部内容…") { chooseExportDestination() }
            }
            Section("导入") {
                Text("从 .pasteexport 文件导入：剪贴板历史与文件夹合并，重复内容自动去重合并，命名标题、置顶与移除状态保留，文件类记录自动跳过并计数。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("从文件导入…") { chooseImportFile() }
            }
        }
        .formStyle(.grouped)
        .disabled(isBusy)
        .overlay {
            if isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在处理…").font(.footnote)
                }
            }
        }
        .alert(
            "导入 / 导出完成",
            isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(failureMessage ?? "")
        }
    }

    private func chooseExportDestination() {
        guard let repository = CoreStore.shared.repository else {
            failureMessage = LibraryTransferError.coreUnavailable.localizedDescription
            return
        }
        let panel = NSSavePanel()
        // 运行时注册的自定义 UTType 没有扩展名映射，SavePanel 不会自动补后缀：
        // 直接在默认文件名里带 .pasteexport（导入面板不过滤类型，由解析层校验）
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "Paste-导出-\(formatter.string(from: Date())).pasteexport"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                resultMessage = try await LibraryTransfer
                    .exportAll(to: url, repository: repository)
                    .message
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }

    private func chooseImportFile() {
        guard let repository = CoreStore.shared.repository else {
            failureMessage = LibraryTransferError.coreUnavailable.localizedDescription
            return
        }
        let panel = NSOpenPanel()
        // 不按 UTI 过滤：运行时注册的自定义类型对文件面板的扩展名匹配不可靠，
        // 会把 .pasteexport（乃至无扩展名的旧导出文件）挡成灰色不可选。
        // 放开显示、由解析层严格校验（invalidDocument）。
        panel.message = "选择 Paste 导出的备份文件（.pasteexport）"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                resultMessage = try await LibraryTransfer
                    .importDocument(from: url, repository: repository)
                    .message
            } catch {
                failureMessage = (error as? LibraryTransferError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
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
                    "登录时启动 Paste",
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
        .task {
            // 授权发生在系统设置里：页面存活期间轮询同步，用户授权回来无需重开设置页
            while !Task.isCancelled {
                accessibilityTrusted = PasteService.shared.isAccessibilityTrusted
                try? await Task.sleep(for: .seconds(2))
            }
        }
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
    @AppStorage(CleanupSettings.intervalValueKey) private var intervalValue = 1
    @AppStorage(CleanupSettings.intervalUnitKey) private var intervalUnitRaw = CleanupSettings.IntervalUnit.hours.rawValue
    @State private var cleanupInProgress = false
    @State private var cleanupSummary: String?
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
                Text("Enter 与双击卡片都按此操作执行；⌘↩ 始终粘贴到当前活动应用。" + (DefaultPasteAction(rawValue: defaultActionRaw)?.detail ?? ""))
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
                HStack {
                    Text("清理频率")
                    Spacer()
                    TextField("间隔", value: $intervalValue, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                    Picker(
                        "单位",
                        selection: $intervalUnitRaw
                    ) {
                        ForEach(CleanupSettings.IntervalUnit.allCases, id: \.self) { unit in
                            Text(unit.title).tag(unit.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 82)
                }
                Button("立即清理") { runCleanupNow() }
                    .disabled(cleanupInProgress)
                Text("置顶与已收藏到文件夹的记录永不自动清理、不计入上限；保留时长按记录的最近使用时间计算，频率决定检查间隔。")
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
        // 关闭设置窗口时若仍在录制快捷键，移除监视器，避免它继续吞掉应用内所有按键
        .onDisappear {
            if isRecording {
                stopRecording()
            }
        }
        .onChange(of: retentionRaw) {
            Task { await CleanupScheduler.shared.runOnce() }
        }
        .onChange(of: historyLimit) {
            Task { await CleanupScheduler.shared.runOnce() }
        }
        .onChange(of: intervalValue) {
            // 输入钳制并回写：0 / 负数 / 超界直接修正，避免「显示 0 实际每分钟跑一次」
            // 的显示值与生效值脱节（写回触发的一次 onChange 中值已合法，不再改写）
            let clamped = min(max(intervalValue, 1), CleanupSettings.intervalUnit.maxValue)
            if clamped != intervalValue {
                intervalValue = clamped
            }
            CleanupScheduler.shared.restartSchedule()
        }
        .onChange(of: intervalUnitRaw) {
            // 换单位后把数值钳制到新单位的合法范围
            intervalValue = min(max(intervalValue, 1), CleanupSettings.intervalUnit.maxValue)
            CleanupScheduler.shared.restartSchedule()
        }
        .alert(
            "自动清理",
            isPresented: Binding(
                get: { cleanupSummary != nil },
                set: { if !$0 { cleanupSummary = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(cleanupSummary ?? "")
        }
        .alert(
            "无法设置快捷键",
            isPresented: Binding(
                get: { shortcutErrorMessage != nil },
                set: { if !$0 { shortcutErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(shortcutErrorMessage ?? "该组合键已被其他应用占用，请换一个组合再试。")
        }
    }

    private func runCleanupNow() {
        cleanupInProgress = true
        Task {
            let summary = await CleanupScheduler.shared.runOnce()
            cleanupInProgress = false
            cleanupSummary = summary.message
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
                    .disabled(!ExcludedApps.isValidBundleID(newBundleID))
                }
                Text("按 Bundle ID 添加（如 com.example.app）；这些应用前台时剪贴板不会被记录。")
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
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Paste")
                .font(.title2).bold()
            Text("版本 \(BundleInfo.version)（\(BundleInfo.build)）")
                .foregroundStyle(.secondary)
            Text("本地优先的 macOS 剪贴板管理器")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
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

            // 面板内已占用纯 ⌘ 快捷键：全局热键设成同组合会在面板里抢先触发收起，
            // 让 ⌘F 搜索 / ⌘P 置顶等失灵（带 ⇧/⌃/⌥ 的组合不冲突）
            let panelReserved: Set<UInt32> = [
                UInt32(kVK_ANSI_F),            // ⌘F 搜索
                UInt32(kVK_ANSI_C),            // ⌘C 复制到剪贴板
                UInt32(kVK_ANSI_E),            // ⌘E 编辑内容
                UInt32(kVK_ANSI_R),            // ⌘R 重命名
                UInt32(kVK_ANSI_P),            // ⌘P 置顶
                UInt32(kVK_Return),            // ⌘↩ 粘贴到当前应用
                UInt32(kVK_ANSI_KeypadEnter),  // ⌘↩（小键盘）
            ]
            if carbon == UInt32(cmdKey), panelReserved.contains(UInt32(event.keyCode)) {
                recordingHint = "该组合已被面板内快捷键占用，请换一个"
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
