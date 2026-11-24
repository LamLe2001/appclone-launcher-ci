# AppCloneLauncher — build inputs

Code-only mirror used to produce the iOS build artifact in CI.
Project documentation lives in a private repository.

- `Packages/` — Swift modules (domain, storage, backup, diagnostics) + tests
- `Apps/LauncherIPA/` — SwiftUI app shell for iOS 15
- `.github/workflows/ios-unsigned-ipa.yml` — archives an unsigned IPA
