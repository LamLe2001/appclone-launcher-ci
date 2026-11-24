import SwiftUI

/// Application entry point.
///
/// Deployment target is **iOS 15.0** so it runs on the target device
/// (iPhone 7 Plus, iOS 15.8.5). This constrains the UI: `NavigationView` rather
/// than `NavigationStack`, and no iOS 16+ APIs anywhere.
@main
struct LauncherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { await model.start() }
        }
    }
}
