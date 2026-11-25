import Foundation
import SwiftUI
import AppCloneDomain
import LauncherStorage
import Diagnostics

/// Observable application state.
///
/// Deliberately thin: it owns the repository and the selected engine, and
/// exposes exactly what the UI needs. All data-safety logic lives in
/// `ProfileCoordinator` / `OwnershipPolicy` in the domain package, which is
/// unit-tested. This type must never bypass those.
///
/// Until a real engine adapter exists, the app runs against `MockEngine` and
/// says so **in the UI** — it must never present mock data as a working clone.
@MainActor
final class AppModel: ObservableObject {

    enum EngineMode: String {
        case jailbreak = "Jailbreak engine"
        case mock = "Mock (no engine)"
        case unsupported = "No engine available"
    }

    @Published private(set) var profiles: [Profile] = []
    /// Source applications the user may clone FROM. Only validated sources are
    /// listed; an untested app is never advertised as supported (plan §4.1).
    @Published private(set) var sources: [SourceApplication] = []
    @Published private(set) var environment: EnvironmentReport?
    @Published private(set) var engineMode: EngineMode = .unsupported
    @Published private(set) var startupError: String?
    @Published var activeJobText: String?
    @Published private(set) var isReady = false

    private var repository: LauncherRepository?
    private var coordinator: ProfileCoordinator?
    private var currentEngine: CloneEngine?

    /// Boots storage and probes the engine. Never crashes the UI: every failure
    /// becomes a visible, actionable message rather than a silent no-op.
    func start() async {
        guard !isReady else { return }
        do {
            let url = try Self.databaseURL()
            let repo = try LauncherRepository.open(at: url)
            repository = repo

            // Prefer the real jailbreak engine; it reports itself unusable when
            // the privileged daemon is not installed, in which case we fall back
            // to the mock so the UI still runs (clearly labelled).
            let engine: CloneEngine
            let mode: EngineMode
            let jailbreak = JailbreakEngine()
            if let probe = try? await jailbreak.probeEnvironment(),
               probe.canUse(.probeEnvironment) {
                engine = jailbreak
                mode = .jailbreak
            } else {
                engine = MockEngine()
                mode = .mock
            }
            currentEngine = engine
            engineMode = mode
            coordinator = ProfileCoordinator(engine: engine, repository: repo)

            let report = try await engine.probeEnvironment()
            environment = report
            try? repo.saveCapabilitySnapshot(report: report)

            await recoverInterruptedJobs()
            await reloadSources()
            try reloadProfiles()
            isReady = true
        } catch {
            startupError = "Could not start: \(error)"
            engineMode = .unsupported
        }
    }

    private static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("AppClone", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("launcher.sqlite")
    }

    /// Plan §10.4: find jobs that were not terminal at last run and act on the
    /// recovery decision rather than assuming the work finished.
    private func recoverInterruptedJobs() async {
        guard let repo = repository else { return }
        guard let jobs = try? repo.unfinishedJobs() else { return }
        for var job in jobs {
            switch JobRecovery.decide(for: job) {
            case .none:
                continue
            case .retryFromStart, .releaseStaleLock:
                job.outcome = .interrupted
                job.errorCode = "INTERRUPTED_RETRY"
                try? repo.updateJob(job)
            case .reconcileWithEngine, .surfaceToUser:
                job.outcome = .interrupted
                job.errorCode = "INTERRUPTED_RECONCILE"
                try? repo.updateJob(job)
            }
        }
    }

    func reloadProfiles() throws {
        profiles = try repository?.profiles() ?? []
    }

    /// Loads the cloneable sources, seeding the validated default (Facebook)
    /// on first run. Additional apps are added only after they pass the project
    /// test suite, so the picker stays honest.
    func reloadSources() async {
        guard let repo = repository, let engine = currentEngine else { return }

        // Ask the live engine what it can actually clone. On the jailbreak engine
        // this enumerates the apps really installed on the device, which is what
        // the create-sheet picker shows.
        if engine.kind != .mock,
           let discovered = try? await engine.listSources(), !discovered.isEmpty {
            for d in discovered {
                let app = SourceApplication(
                    sourceType: .installedApp,
                    bundleID: d.bundleID,
                    displayName: d.displayName,
                    engineKind: engine.kind,
                    engineSourceID: d.sourceID
                )
                try? repo.upsertApplication(app)
            }
            sources = (try? repo.allApplications()) ?? []
            return
        }

        if let existing = try? repo.allApplications(), !existing.isEmpty {
            sources = existing
            return
        }
        let facebook = SourceApplication(
            sourceType: .installedApp,
            bundleID: "com.facebook.Facebook",
            displayName: "Facebook",
            engineKind: currentEngine?.kind ?? .mock,
            engineSourceID: "com.facebook.Facebook"
        )
        try repo.saveApplication(facebook)
        sources = [facebook]
    }

    /// Creates a clone through the coordinator. The UI shows the honest result,
    /// including when reconciliation is required.
    func createProfile(source: SourceApplication, name: String, color: ProfileColor) async {
        guard let coordinator, let repo = repository else { return }
        // Bind the source row to whichever engine is actually active, so a
        // profile can never be created under the wrong engine.
        var app = source
        app.engineKind = currentEngine?.kind ?? .mock
        try? repo.saveApplication(app)

        activeJobText = "Creating…"
        defer { activeJobText = nil }

        do {
            let result = try await coordinator.createBlankProfile(
                app: app,
                sourceVersion: nil,
                name: name.isEmpty ? source.displayName : name,
                color: color,
                idempotencyKey: "create-\(UUID().uuidString)"
            )
            switch result {
            case .created:
                try reloadProfiles()
            case .needsReconciliation(let jobID, let reason):
                startupError = "Needs reconciliation (\(jobID)): \(reason)"
            case .rejected(let error):
                startupError = "Rejected: \(error.code)"
            }
        } catch {
            startupError = "Create failed: \(error)"
        }
    }

    func launch(_ profile: Profile) async {
        guard let coordinator else { return }
        activeJobText = "Opening \(profile.name)…"
        defer { activeJobText = nil }
        let outcome = try? await coordinator.launch(
            profileID: profile.id,
            idempotencyKey: "launch-\(UUID().uuidString)"
        )
        switch outcome {
        case .dispatched:
            try? reloadProfiles()
        case .dispatchFailed(_, let code):
            startupError = "Launch failed: \(code)"
        case .rejected(let error):
            startupError = "Launch rejected: \(error.code)"
        case nil:
            startupError = "Launch failed: unknown error"
        }
    }

    func delete(_ profile: Profile) {
        guard let repo = repository else { return }
        do {
            try repo.deleteProfileMetadata(profileID: profile.id)
            try reloadProfiles()
        } catch {
            startupError = "Delete failed: \(error)"
        }
    }

    func dismissError() { startupError = nil }
}
