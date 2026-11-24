// swift-tools-version:5.9
import PackageDescription

// Workspace package that makes the domain/storage/backup logic buildable and
// testable on any Swift toolchain (Linux CI/macOS). Platform shells
// (Apps/LauncherJB, Apps/LauncherIPA) are Xcode projects that consume these
// packages; they are NOT built here because they need UIKit/SwiftUI.
//
// Targets live under Packages/<Name>/Sources/<Name> so the repository layout
// matches the structure proposed in the project plan (§19.1).
let package = Package(
    name: "AppCloneLauncher",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "AppCloneDomain", targets: ["AppCloneDomain"]),
        .library(name: "LauncherStorage", targets: ["LauncherStorage"]),
        .library(name: "BackupKit", targets: ["BackupKit"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "AppCloneDomain",
            path: "Packages/AppCloneDomain/Sources/AppCloneDomain"
        ),
        .target(
            name: "LauncherStorage",
            dependencies: [
                "AppCloneDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/LauncherStorage/Sources/LauncherStorage"
        ),
        .target(
            name: "BackupKit",
            dependencies: [
                "AppCloneDomain",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            path: "Packages/BackupKit/Sources/BackupKit"
        ),
        .target(
            name: "Diagnostics",
            dependencies: ["AppCloneDomain"],
            path: "Packages/Diagnostics/Sources/Diagnostics"
        ),
        .testTarget(
            name: "AppCloneDomainTests",
            dependencies: ["AppCloneDomain"],
            path: "Packages/AppCloneDomain/Tests/AppCloneDomainTests"
        ),
        .testTarget(
            name: "LauncherStorageTests",
            dependencies: ["LauncherStorage", "AppCloneDomain"],
            path: "Packages/LauncherStorage/Tests/LauncherStorageTests"
        ),
        .testTarget(
            name: "BackupKitTests",
            dependencies: ["BackupKit"],
            path: "Packages/BackupKit/Tests/BackupKitTests"
        ),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics"],
            path: "Packages/Diagnostics/Tests/DiagnosticsTests"
        ),
    ]
)
