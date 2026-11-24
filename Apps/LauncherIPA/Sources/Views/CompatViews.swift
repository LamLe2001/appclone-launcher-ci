import SwiftUI

/// A label/value row.
///
/// Exists because `LabeledContent` requires **iOS 16**, while this app targets
/// iOS 15.0 for the iPhone 7 Plus (iOS 15.8.5). Using the SwiftUI built-in here
/// would compile fine on a modern simulator and then fail to launch on the
/// actual device — exactly the kind of mistake the target-version audit exists
/// to catch.
struct InfoRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A section with an explicit header.
///
/// The `TitledSection("Title") { }` shorthand is available on newer SDKs but not
/// reliably on iOS 15; `Section(header:)` is universally available.
struct TitledSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    /// Unlabeled initializer so call sites read `TitledSection("About") { … }`,
    /// matching the familiar `Section("About")` shape. Without this the
    /// synthesized memberwise init requires `title:` and every call site fails
    /// to compile (caught by the first real iOS build).
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Section(header: Text(title)) {
            content()
        }
    }
}
