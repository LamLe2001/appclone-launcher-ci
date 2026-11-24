import SwiftUI
import AppCloneDomain

/// Root tab container. Three tabs per plan §7.1.
///
/// iOS 15 compatible: `TabView` with `.tabItem`, no `NavigationStack`.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            LauncherListView()
                .tabItem { Label("Launcher", systemImage: "square.grid.2x2") }

            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .alert("Something needs attention",
               isPresented: Binding(
                get: { model.startupError != nil },
                set: { if !$0 { model.dismissError() } }
               )) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.startupError ?? "")
        }
    }
}
