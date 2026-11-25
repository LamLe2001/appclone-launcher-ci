# AppClone Container Engine (jailbreak branch)

A self-developed container engine: it lets one installed app (default
`com.facebook.Facebook`) run against several independent data containers, with
its own files, preferences, App Groups and Keychain namespace.

This implements **Method B** from the project plan (§5.1) — the self-developed
engine, chosen because no commercial engine (Crane) is available on this
device.

---

## 1. Why this is more than "swap a folder"

The plan (§12.2) warns explicitly:

> Do not use renaming two Documents folders as if it were a complete engine.
> Each namespace can hold different data; as long as the Keychain is still
> shared, two profiles can still use each other's login state.

So the engine has to redirect **four** independent things:

| Surface | How iOS stores it | What the engine does |
|---|---|---|
| Files, caches, sqlite | `<home>/Documents`, `<home>/Library` | `NSHomeDirectory()` → container `Data/` |
| Preferences | `<home>/Library/Preferences` | follows the home redirect |
| **App Groups** | shared container, *not* under home | hook `containerURLForSecurityApplicationGroupIdentifier:` |
| **Keychain** | process-wide, keyed by service/account | prefix service + account per container |

All four are implemented before a clone is considered usable.

## 2. Architecture

```
┌──────────────────────┐         UNIX socket          ┌────────────────────────┐
│  Launcher (SwiftUI)  │  CREATE / WIPE / DELETE /    │  appcloned (root)      │
│  JailbreakEngine     │  SETACTIVE / LIST  ────────► │  owns                   │
│  (sandboxed app)     │  path-free requests          │  /var/mobile/Library/   │
└──────────────────────┘                              │      AppClone/          │
                                                      └──────────┬─────────────┘
                                                                 │ writes
                                                                 ▼
                                                     /…/AppClone/active.plist
                                                                 │ read
                                                                 ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  Target app process (Facebook) + AppCloneKit tweak                            │
│    NSHomeDirectory            → Containers/<bid>/<cid>/Data                   │
│    NSTemporaryDirectory       → …/Data/tmp                                    │
│    containerURLForSecurityApplicationGroupIdentifier: → …/Data/Library/AppGroup/<gid> │
│    SecItem{Add,CopyMatching,Update,Delete} → service/account prefixed         │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Why a daemon and not just file writes from the launcher

The launcher is sandboxed. Letting it name arbitrary paths would turn a launcher
bug into arbitrary file write outside its container. Requests therefore carry a
`bundleID` and a `containerID` only; `appcloned` validates both against a strict
charset and resolves the path itself. Deletion additionally re-checks that the
resolved path is still inside the container root.

### Why the tweak degrades safely

If no container is active, or the container directory is missing, every hook
returns `%orig`. A broken state makes the app behave exactly like the stock app
rather than failing to launch.

## 3. Container layout

```
/var/mobile/Library/AppClone/
├── active.plist                     # { active = { "<bundleID>" = "<containerID>" } }
└── Containers/
    └── com.facebook.Facebook/
        └── c9f1…/                   # containerID = FNV-1a of the operation ID
            ├── .appclone-marker.plist
            └── Data/
                ├── Documents/
                ├── Library/
                │   ├── Preferences/
                │   ├── Caches/
                │   └── AppGroup/<group>/
                └── tmp/
```

The `.appclone-marker.plist` is the ownership record: a container without one is
never treated as ours, mirroring `OwnershipPolicy` in the domain package.

## 4. Protocol

One request per connection, newline terminated. Reply is `OK …` or `ERR <code> …`.

| Request | Meaning |
|---|---|
| `PING` | liveness |
| `CREATE <cid> <bid> <name>` | make a container (idempotent per `cid`) |
| `DELETE <cid> <bid>` | remove a container and its data |
| `WIPE <cid> <bid>` | keep the record, drop the data |
| `LIST <bid>` | container ids for an app |
| `SETACTIVE <cid\|-> <bid>` | which container the tweak should use |
| `GETACTIVE <bid>` | read it back |

## 5. Building and installing

```bash
# on macOS with Xcode
export THEOS=$HOME/theos
export THEOS_PACKAGE_SCHEME=rootless
cd Adapters/Jailbreak/Engine && make package FINALPACKAGE=1
```

CI does this automatically: `.github/workflows/ios-engine-deb.yml`.

Install on a jailbroken (rootless) device:

1. Copy `com.levothanhlam.appclone_*.deb` to the phone (Filza).
2. Tap it → **Install with Sileo** (or `dpkg -i` from a root shell).
3. Reinstall the launcher IPA via TrollStore (it now links `JailbreakEngine`).
4. Open the launcher → **Settings** should read `Jailbreak engine`, not Mock.

## 6. Known limitations (honest)

| Limitation | Consequence |
|---|---|
| `quiesce` is **not** supported | The engine cannot prove the previous guest stopped, so `ProfileCoordinator` refuses to switch containers while an instance may still be running. The user must close the app before opening another clone. |
| No data export/import yet | Backup/restore of containers is reported `unsupported`. |
| Keychain namespacing is by name prefix | Correct for apps that address items by service/account (the common case). An app that enumerates *all* keychain items of an access group would still see items from siblings. |
| Facebook anti-tamper | Not yet validated on device. A jailbreak-aware app may refuse to run with an injected tweak. This is the largest unknown and can only be settled by testing on the device. |
| Notification routing | Per-clone push routing is not implemented. |

## 7. What is verified vs not

| Claim | State |
|---|---|
| Daemon protocol, path validation, atomic state write | implemented; **not yet compiled/run on device** |
| Tweak hooks (home/temp/AppGroup/keychain) | implemented; **not yet compiled/run on device** |
| Package builds | via CI (see workflow run) |
| Facebook actually runs in two separated containers | **NOT VERIFIED** — this is the Gate A question |

Do not read "engine written" as "cloning works". The engine removes the
*architectural* blocker; whether Facebook tolerates it is an empirical question
the device must answer.
