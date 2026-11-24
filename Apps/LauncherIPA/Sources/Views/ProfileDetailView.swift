import SwiftUI
import AppCloneDomain

/// Detail screen for one clone. Actions that require a real engine are shown
/// disabled with the reason, never silently hidden or faked (plan §7.1).
struct ProfileDetailView: View {
    let profile: Profile
    @EnvironmentObject private var model: AppModel
    @State private var confirmDelete = false

    private var current: Profile {
        model.profiles.first { $0.id == profile.id } ?? profile
    }

    var body: some View {
        Form {
            TitledSection("Profile") {
                InfoRow("Name", current.name)
                InfoRow("State", stateText)
                InfoRow("App", "Facebook")
                if let opened = current.lastOpenedAt {
                    InfoRow("Last opened", opened.formatted(date: .abbreviated, time: .shortened))
                }
            }

            TitledSection("Actions") {
                Button {
                    Task { await model.launch(current) }
                } label: {
                    Label("Open", systemImage: "play.fill")
                }
                .disabled(!current.state.allowsLaunch)

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Remove from launcher", systemImage: "trash")
                }
            }

            Section {
                Text("Open dispatches a launch request. It does not mean you are signed in.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Remove \(current.name)?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                model.delete(current)
            }
        } message: {
            Text("This removes the launcher's record for this clone. In a build with a real engine it would also delete that clone's data — the original Facebook is never touched.")
        }
    }

    private var stateText: String {
        switch current.state {
        case .ready: return "Ready"
        case .preparing: return "Preparing"
        case .launching: return "Opening"
        case .recentlyLaunched: return "Opened recently"
        case .needsAttention: return "Needs attention"
        case .unsupported: return "Unsupported"
        }
    }
}
