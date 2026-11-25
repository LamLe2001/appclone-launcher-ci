import SwiftUI
import AppCloneDomain

/// Settings tab. Shows build identity (needed for the delivery evidence), the
/// engine mode, and the capability snapshot — all read-only and honest.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
    private var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }
    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "?"
    }

    var body: some View {
        NavigationView {
            List {
                TitledSection("About") {
                    InfoRow("App version", appVersion)
                    InfoRow("Build", buildNumber)
                    InfoRow("Bundle ID", bundleID)
                    InfoRow("Minimum iOS", "15.0")
                }

                TitledSection("Engine") {
                    InfoRow("Mode", model.engineMode.rawValue)
                    if let env = model.environment {
                        Text(env.summary)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                if !model.engineDiagnostics.isEmpty {
                    TitledSection("Engine diagnostics") {
                        ForEach(model.engineDiagnostics, id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                TitledSection("Capabilities") {
                    if let env = model.environment {
                        ForEach(env.capabilities, id: \.capability) { record in
                            HStack {
                                Text(record.capability.rawValue)
                                    .font(.footnote)
                                Spacer()
                                Text(record.status.rawValue)
                                    .font(.caption)
                                    .foregroundColor(statusColor(record.status))
                            }
                        }
                    } else {
                        Text("Not probed").foregroundColor(.secondary)
                    }
                }

                Section {
                    Text("This build links the mock engine only. It proves the launcher app installs, launches and is usable; it does not clone Facebook.")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
            }
            .navigationTitle("Settings")
        }
        .navigationViewStyle(.stack)
    }

    private func statusColor(_ status: CapabilityStatus) -> Color {
        switch status {
        case .supported: return .green
        case .unsupported: return .red
        case .unknown: return .secondary
        }
    }
}
