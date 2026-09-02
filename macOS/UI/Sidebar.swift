import SwiftUI

/// 侧栏历史分类（§22）。
struct Sidebar: View {
    @Binding var selection: ClipboardCategory

    var body: some View {
        List(selection: $selection) {
            Section("剪贴板") {
                ForEach(ClipboardCategory.allCases) { category in
                    Label(category.title, systemImage: category.symbolName)
                        .tag(category)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("历史分类")
    }
}
