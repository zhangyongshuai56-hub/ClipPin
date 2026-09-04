import SwiftUI

@main
struct PasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
            // menu 风格的 MenuBarExtra 不会继承 scene 级 environment，必须注入到内容内部
                .environment(appDelegate.appState)
        } label: {
            Image(systemName: appDelegate.appState.statusBarSymbolName)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}
