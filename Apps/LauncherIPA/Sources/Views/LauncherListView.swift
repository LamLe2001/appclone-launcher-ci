import SwiftUI
import AppCloneDomain

/// Main launcher tab: the list of created clones.
struct LauncherListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var newColor: ProfileColor = .blue

    var body: some View {
        NavigationView {
            Group {
                if !model.isReady {
                    ProgressView("Starting…")
                } else if model.profiles.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Launcher")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create clone")
                }
            }
            .sheet(isPresented: $showingCreate) { createSheet }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("No clones yet")
                .font(.headline)
            Text("Create a clone from the Facebook source in the Library tab.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if !model.engineMode.rawValue.isEmpty {
                Text(model.engineMode.rawValue)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.top, 4)
            }
        }
    }

    private var list: some View {
        List {
            if let job = model.activeJobText {
                Section {
                    Label(job, systemImage: "clock.arrow.circlepath")
                        .foregroundColor(.secondary)
                }
            }
            ForEach(model.profiles) { profile in
                NavigationLink(destination: ProfileDetailView(profile: profile)) {
                    ProfileRow(profile: profile)
                }
            }
            .onDelete(perform: delete)
        }
        .listStyle(.insetGrouped)
    }

    private var createSheet: some View {
        NavigationView {
            Form {
                TitledSection("Name") {
                    TextField("e.g. Facebook Work", text: $newName)
                }
                TitledSection("Color") {
                    ColorPicker(selection: $newColor)
                }
                if model.engineMode == .mock {
                    Section {
                        Text("No real engine is linked in this build. Creating here exercises the launcher's data model only; it does not clone Facebook.")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                }
            }
            .navigationTitle("New clone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCreate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = newName
                        let color = newColor
                        showingCreate = false
                        newName = ""
                        Task { await model.createProfile(name: name, color: color) }
                    }
                }
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { model.profiles[$0] }
        targets.forEach { model.delete($0) }
    }
}

/// Color selector bound to the domain token.
private struct ColorPicker: View {
    @Binding var selection: ProfileColor

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
            ForEach(ProfileColor.allCases, id: \.self) { color in
                Circle()
                    .fill(Self.uiColor(color))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle().strokeBorder(Color.primary,
                                              lineWidth: selection == color ? 2 : 0)
                    )
                    .onTapGesture { selection = color }
                    .accessibilityLabel(color.displayName)
            }
        }
        .padding(.vertical, 4)
    }

    static func uiColor(_ color: ProfileColor) -> Color {
        switch color {
        case .blue: return .blue
        case .green: return .green
        case .purple: return .purple
        case .orange: return .orange
        case .pink: return .pink
        case .teal: return .teal
        case .red: return .red
        case .indigo: return .indigo
        }
    }
}

struct ProfileRow: View {
    let profile: Profile

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(ColorPicker.uiColor(profile.color))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.body)
                Text(stateLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if profile.isPinned {
                Image(systemName: "pin.fill").foregroundColor(.secondary)
            }
        }
    }

    /// Honest state text. "Recently opened" never claims "logged in".
    private var stateLabel: String {
        switch profile.state {
        case .ready: return "Ready"
        case .preparing: return "Preparing"
        case .launching: return "Opening…"
        case .recentlyLaunched: return "Opened recently"
        case .needsAttention: return "Needs attention"
        case .unsupported: return "Unsupported"
        }
    }
}
