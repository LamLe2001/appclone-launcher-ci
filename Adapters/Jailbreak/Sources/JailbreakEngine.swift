import Foundation
import AppCloneDomain

/// Real engine adapter for the jailbreak branch.
///
/// It does **not** manipulate files itself: the sandboxed launcher asks the
/// privileged daemon (`appcloned`, installed by the companion .deb) to create,
/// wipe, delete and activate containers. Requests name a container ID, never a
/// path, so a compromised launcher cannot reach outside the container root.
///
/// The in-app half of the engine (the `AppCloneKit` tweak injected into the
/// target app) reads the same "active container" state and redirects
/// NSHomeDirectory / App Groups / Keychain accordingly.
@MainActor
public final class JailbreakEngine: CloneEngine {

    public nonisolated let kind: EngineKind = .jailbreak
    public nonisolated let adapterVersion = "jb-0.1.0"

    /// Rootless jailbreaks relocate to /var/jb.
    private let socketPath: String
    private let statePlistPath: String

    public init(rootless: Bool = true) {
        if rootless {
            socketPath = "/var/jb/var/run/appcloned.sock"
            statePlistPath = "/var/jb/var/mobile/Library/AppClone/active.plist"
        } else {
            socketPath = "/var/run/appcloned.sock"
            statePlistPath = "/var/mobile/Library/AppClone/active.plist"
        }
    }

    // MARK: - daemon transport

    private enum DaemonError: Error { case unreachable(String) }

    /// Sends one request line and returns the daemon's reply line.
    /// Every call opens a fresh connection: the protocol is stateless, which keeps
    /// recovery trivial if the daemon restarts.
    private func send(_ request: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.unreachable("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw DaemonError.unreachable("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        var mutableAddr = addr
        let connected = withUnsafePointer(to: &mutableAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw DaemonError.unreachable("cannot connect to appcloned")
        }

        let out = Array((request + "\n").utf8)
        _ = out.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count - 1)
        guard n > 0 else { throw DaemonError.unreachable("no reply") }
        return String(decoding: buffer[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ok(_ response: String) -> String? {
        guard response.hasPrefix("OK") else { return nil }
        let parts = response.split(separator: " ", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    // MARK: - CloneEngine

    public func probeEnvironment() async throws -> EnvironmentReport {
        var capabilities: [CapabilityRecord] = []
        let daemonUp: Bool
        do {
            daemonUp = ok(try send("PING")) == "pong"
        } catch {
            daemonUp = false
        }

        func record(_ cap: Capability, _ ok_: Bool, _ reason: String? = nil) -> CapabilityRecord {
            CapabilityRecord(capability: cap,
                             status: ok_ ? .supported : .unsupported,
                             reason: reason)
        }

        capabilities.append(record(.probeEnvironment, daemonUp, daemonUp ? nil : "appcloned not reachable"))
        capabilities.append(record(.createBlankProfile, daemonUp, daemonUp ? nil : "daemon down"))
        capabilities.append(record(.deleteProfile, daemonUp, daemonUp ? nil : "daemon down"))
        capabilities.append(record(.resetProfile, daemonUp, daemonUp ? nil : "daemon down (wipe uses daemon)"))
        capabilities.append(record(.listProfiles, daemonUp))
        capabilities.append(record(.inspectProfile, daemonUp))
        capabilities.append(record(.launch, true,
            "launch uses LSApplicationWorkspace openApplicationWithBundleID"))
        // Quiesce is NOT supported: this engine cannot prove the previous guest
        // stopped, so the coordinator will refuse unsafe container switches.
        capabilities.append(record(.quiesce, false, "cannot verify the guest process stopped"))
        capabilities.append(record(.exportData, false, "container export not implemented yet"))
        capabilities.append(record(.importData, false, "container import not implemented yet"))

        let fp = EnvironmentFingerprint(engineKind: .jailbreak,
                                        engineVersion: "appcloned-0.1.0",
                                        adapterVersion: adapterVersion,
                                        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                        jailbreakFlavor: socketPath.contains("/var/jb") ? "rootless" : "rootful")
        return EnvironmentReport(fingerprint: fp,
                                 capabilities: capabilities,
                                 summary: daemonUp ? "Jailbreak engine connected"
                                                   : "Jailbreak engine: daemon not reachable")
    }

    /// Lists apps that are actually installed and cloneable. Uses
    /// LSApplicationWorkspace; the launcher is a TrollStore "System" app so this
    /// private API is available to it.
    public func listSources() async throws -> [DiscoveredSource] {
        guard let workspace = Self.applicationWorkspace() else { return [] }
        let selector = NSSelectorFromString("allInstalledApplications")
        guard workspace.responds(to: selector),
              let apps = workspace.perform(selector)?.takeUnretainedValue() as? [NSObject] else {
            return []
        }
        var out: [DiscoveredSource] = []
        for app in apps {
            let bid = (app.value(forKey: "bundleIdentifier") as? String) ?? ""
            // Only user-facing apps from the App container are clonable.
            let type = (app.value(forKey: "applicationType") as? String) ?? ""
            guard type == "User", !bid.isEmpty else { continue }
            let name = (app.value(forKey: "localizedName") as? String) ?? bid
            out.append(DiscoveredSource(sourceID: bid, bundleID: bid, displayName: name))
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func validateSource(_ sourceID: String) async throws -> Bool {
        (try await listSources()).contains { $0.bundleID == sourceID }
    }

    public func createBlankProfile(sourceID: String, operationID: String) async throws -> CreatedProfile {
        // Deterministic container ID derived from the operation so a retried call
        // cannot create a second container (daemon CREATE is idempotent per id).
        let containerID = Self.containerID(for: operationID)
        let reply = try send("CREATE \(containerID) \(sourceID) clone")
        guard ok(reply) != nil else {
            throw EngineError.rejected(reason: reply)
        }
        return CreatedProfile(handle: EngineHandle("\(sourceID)::\(containerID)"))
    }

    public func inspectProfile(_ handle: EngineHandle) async throws -> InspectedProfile {
        guard let (bundleID, containerID) = Self.split(handle) else {
            return InspectedProfile(handle: handle, exists: false)
        }
        let reply = try send("LIST \(bundleID)")
        guard let list = ok(reply) else {
            throw EngineError.rejected(reason: reply)
        }
        let ids = list.split(separator: ",").map(String.init)
        return InspectedProfile(handle: handle,
                                exists: ids.contains(containerID),
                                marker: ids.contains(containerID)
                                    ? OwnershipMarker(profileID: RecordID(containerID),
                                                      appID: RecordID(bundleID))
                                    : nil)
    }

    /// Activates the container then asks SpringBoard to launch the app.
    public func launch(_ handle: EngineHandle) async throws {
        guard let (bundleID, containerID) = Self.split(handle) else {
            throw EngineError.staleHandle
        }
        let reply = try send("SETACTIVE \(containerID) \(bundleID)")
        guard ok(reply) != nil else { throw EngineError.rejected(reason: reply) }

        guard let workspace = Self.applicationWorkspace() else {
            throw EngineError.rejected(reason: "LSApplicationWorkspace unavailable")
        }
        let sel = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: sel) else {
            throw EngineError.rejected(reason: "openApplicationWithBundleID unavailable")
        }
        _ = workspace.perform(sel, with: bundleID)
    }

    /// The engine cannot prove the guest stopped, so this is deliberately
    /// unsupported (the coordinator will refuse unsafe switches).
    public func quiesce(_ handle: EngineHandle) async throws {
        throw EngineError.capabilityNotSupported(.quiesce)
    }

    public func resetProfile(_ handle: EngineHandle) async throws {
        guard let (bundleID, containerID) = Self.split(handle) else {
            throw EngineError.staleHandle
        }
        let reply = try send("WIPE \(containerID) \(bundleID)")
        guard ok(reply) != nil else { throw EngineError.rejected(reason: reply) }
    }

    public func deleteProfile(_ handle: EngineHandle) async throws {
        guard let (bundleID, containerID) = Self.split(handle) else {
            throw EngineError.staleHandle
        }
        let reply = try send("DELETE \(containerID) \(bundleID)")
        guard ok(reply) != nil else { throw EngineError.rejected(reason: reply) }
    }

    // MARK: - helpers

    private static func applicationWorkspace() -> NSObject? {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("defaultWorkspace")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    /// Stable per-operation container id (UUID-ish, path-safe).
    private static func containerID(for operationID: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in operationID.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(format: "c%016llx", hash)
    }

    private static func split(_ handle: EngineHandle) -> (bundleID: String, containerID: String)? {
        let parts = handle.rawValue.components(separatedBy: "::")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}
