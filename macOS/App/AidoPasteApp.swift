import SwiftUI

@main
struct AidoPasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
        } label: {
            Image(systemName: appDelegate.appState.statusBarSymbolName)
        }
        .menuBarExtraStyle(.menu)
        .environment(appDelegate.appState)

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}
