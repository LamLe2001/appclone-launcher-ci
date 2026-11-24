import SwiftUI
import AppCloneDomain

/// Library tab. In the IPA build this is where a user would import a signed
/// IPA; that path is not implemented yet, so the screen states the limitation
/// instead of showing a fake "import" button that does nothing (plan §7.1:
/// "Không hiển thị danh sách app cài sẵn giả lập cho bản IPA").
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            List {
                TitledSection("Sources") {
                    row(title: "Facebook",
                        subtitle: "Native app source",
                        available: model.engineMode != .unsupported)
                }

                TitledSection("Import IPA") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not available in this build")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                        Text("Importing a signed IPA requires the LiveContainer-style host runtime, which is not linked. The launcher shell can be installed and opened, but the clone mechanism is not active.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                TitledSection("Engine") {
                    InfoRow("Mode", model.engineMode.rawValue)
                    if let env = model.environment {
                        InfoRow("Adapter", env.fingerprint.adapterVersion)
                        InfoRow("OS", env.fingerprint.osVersion)
                    }
                }
            }
            .navigationTitle("Library")
        }
        .navigationViewStyle(.stack)
    }

    private func row(title: String, subtitle: String, available: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: available ? "checkmark.circle" : "xmark.circle")
                .foregroundColor(available ? .green : .secondary)
        }
    }
}
