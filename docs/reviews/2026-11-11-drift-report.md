# Drift report: 2026-11-11

- **Target:** `docs/designs/` (one document: `muninn-v2.md`, as of `bb114c1` on `v2/design`)
- **Source tree:** `Package.swift`, `packages/`, `apps/` (working tree is clean, so this matches `bb114c1`)
- **Context:** the design has passed only gate 0. Gates A–D haven't started, so most of the divergences below are planned work that hasn't been done yet, not regressions. Each bullet is tagged with the gate that is meant to close it. Bullets tagged **[now]** are inaccuracies or rule breaks that already apply today.

## muninn-v2.md

### Inaccuracies and rule breaks that apply now

- **[now] §2 "Testing": the test count is wrong.** The design says "48 tests". The tree has 100 `@Test` functions: 42 in `packages/MuninnStore/Tests/ClipboardStoreTests.swift`, 10 in `packages/MuninnIPC/Tests/IPCTests.swift` and 48 in `apps/muninn-cli/Tests/CLITests.swift`. The 48 looks like the CLI suite alone.
- **[now] §3 / §7 gate 0: "import checks" are marked done, but nothing configures them.** `--explicit-target-dependency-import-check error` appears only in the design (§4.1, §4.9). There's no CI config (no `.github/`), no build script and no `swiftSettings` in `Package.swift`. So the dependency rules in §4.1 aren't enforced anywhere.
- **[now] §1.4 / D5: the minimum OS doesn't match.** The design and D5 set the minimum at macOS 27. `Package.swift` declares `platforms: [.macOS(.v13)]`.
- **[now] §4.1 build rule "never flags or environment variables":** `MuninnPaths.socketPath` (`packages/MuninnCore/Sources/Paths.swift:18-21`) accepts an override from the `MUNINN_SOCKET_PATH` environment variable in every build. This v1 test seam is exactly the kind of switch the design forbids, and the design neither mentions it nor plans its removal.

### Architectural divergence (v1 is still in place)

- **§4.1 / gate B: modules are missing.** `MuninnSearch`, `MuninnSecurity` and `MuninnProcessing` don't exist. `MuninnProcessors`, `MuninnUI` and `apps/muninn-worker` (gates C/D) are missing too.
- **§4.1 / gate C: the restructure hasn't happened.** There's no `Muninn.xcodeproj` and no `App/`. `.gitignore` still excludes `*.xcodeproj`. `MuninnClipboard` hasn't been renamed to `MuninnCapture`. The UI lives in `apps/muninn-menubar`, an executable target the design's layout doesn't list.
- **§4.1: the `benchmarks/`, `spikes/`, `docs/cli-schemas/` and `docs/evidence/` directories don't exist.**
- **§4.1: `MuninnCore` does I/O.** The design says `MuninnCore` holds models, IDs, paths and IPC types with "no I/O". `ClipboardWriter` (`packages/MuninnCore/Sources/ClipboardWriter.swift`) writes `NSPasteboard.general`. `MuninnPaths` imports AppKit, creates directories and probes executables. The design moves `ClipboardWriter` to `MuninnCapture` but doesn't say when, and doesn't address the I/O in `Paths`.
- **§4.2 conventions 4–7 / gate B: v1 concurrency is still here, outside the allow-listed C-interop layers.**
  - `ClipboardStore` uses `@unchecked Sendable` and `NSLock` (`packages/MuninnStore/Sources/ClipboardStore.swift:11-13`).
  - `ClipboardWatcher` uses `@unchecked Sendable` and `NSLock` (`packages/MuninnClipboard/Sources/ClipboardWatcher.swift:16,22`).
  - `IPCServer` uses `@unchecked Sendable` and `Thread.detachNewThread` (`packages/MuninnIPC/Sources/IPCServer.swift:8,60,92`).
  - The helper calls `DispatchQueue.main.sync` (`apps/muninnd/Sources/main.swift:100,139,144`).
  - The UI uses GCD: `DaemonClient` (`DispatchQueue`, `DaemonClient.swift:7,83`), `PanelViewModel` (`DispatchWorkItem`/`asyncAfter`, `PanelViewModel.swift:22,43-49`), `AppDelegate.swift:25`, `HelperManager.swift:80` and `SearchField.swift:59`.
  - `Task.detached` appears in `HelperManager.swift:43`.
  - There are unstored `Task {}` blocks throughout `PanelViewModel` and `AppDelegate`.
  - No `// SAFETY:` comments exist anywhere, and no CI grep enforces any of this.
- **§4.2 / D4 hotkey: `HotKeyManager` still uses a global `nonisolated(unsafe)` handler** (`apps/muninn-menubar/Sources/HotKeyManager.swift:5`) instead of a main-actor-owned registration.
- **§4.2: no `StoreWriter` actor and no read-only connection pool.** One `SQLiteConnection` serves reads and writes behind a lock, so a slow `LIKE` search blocks capture.
- **§4.3 / gate B: the schema is v1.** The tree has a single `clipboard_entries` table and a `schema_version` table. None of these exist: `capture_events`, `content_items`, `representations`, `assets`, `asset_chunks`, `extracted_text`, `previews`, `annotations`, `processing_jobs`, `settings`, `audit_log`, `schema_migrations`.
- **§4.3 identity: deduplication differs.**
  - Text is deduplicated only against the most recent row, by a hash of the raw text, not normalized text. Copying A, B, A creates three rows instead of one item with two events.
  - Non-text rows get a hash of `kind + metadata JSON` and are deduplicated against the previous row. The design says items without a stored primary representation are never deduplicated (`content_hash` null).
  - There's no `capture_count` or `last_captured_at`.
- **§4.3 representations: content isn't kept.** `ClipboardWatcher` reads only `.string` for text. It stores a placeholder for images, RTF, HTML and files, and records no `available_types`. Reading the image with `NSImage(pasteboard:)` decodes the whole image (TIFF included) in the helper. That contradicts "don't read TIFF when a compact raster type is offered" and §4.13's "no full decode in the helper".
- **§4.3 / §4.4 / §1.5: no encryption and no key management.** `CSQLite` links system `sqlite3`, not SQLCipher. The DB at `~/Library/Application Support/Muninn/muninn.db` is plaintext. The tree has none of the following: Keychain code, `KeyProvider`, `PRAGMA temp_store = MEMORY`, `PRAGMA secure_delete`, `cipher_integrity_check`, orphan-DB handling, `.metadata_never_index`, or a pre-migration copy.
- **§4.3 migrations: no `schema_migrations` with checksums.** Migrations run as ad hoc `ALTER TABLE` statements guarded by `schema_version`, with no transaction around them.
- **§4.4: no lock handling.** Nothing observes screen lock or user switching. The helper serves data and captures while locked.
- **§4.5 / gate C: the helper is still a child process.** `HelperManager` launches `muninnd run` with `Process()` and restarts it once. `SMAppService` is used only as `.mainApp` for the app's own login item (`LoginItemManager.swift`). There's no `.agent`, launchd plist or `.requiresApproval` handling.
- **§4.6 / D21 / gate B: the IPC is v1.** It's an unauthenticated `AF_UNIX` socket with one request per connection. None of these are implemented: XPC, peer code-signing requirement, version handshake (exit 8), `requestId`/`supersedes`/`cancel`, streamed payloads, subscriptions, connection/in-flight/message-size limits, or stable error `code`s. Errors carry a free-text `category`, and the server's catch path builds JSON by string interpolation (`IPCServer.swift:109`). `muninn debug send` doesn't exist.
- **§4.7 / gate B: no `SearchService`.** Search is `content LIKE '%q%' ORDER BY id DESC`, so there's no FTS5, ranking, filters (`since`/`until`/`app`/`type`/`pinned`), `total`/`hasMore` on search, `--all` streaming or `sqlite3_progress_handler` cancellation. An empty query is rejected, but the design makes "empty query plus filters" valid. The panel debounces with a cancellable `DispatchWorkItem`, but in-flight searches aren't cancelled server-side.
- **§4.7 "No cursors": v1 has offset paging the design rules out.** `list` accepts `offset` (`IPCMessage.swift:61-69`, `main.swift:49-60`) and the CLI exposes `--offset`. The design says paging is out until real use needs it, and doesn't list `--offset`.
- **§4.8: none of the capture pipeline exists.** That includes `PasteboardSource`/`CapturePolicy` separation, concealed/transient/auto-generated type checks, `org.nspasteboard.source` attribution, the counters (`missedChanges`, `coalescedRepeats`, `droppedBackpressure`), the backpressure queue, the job pipeline and the index step.
- **§4.8 "Muninn's own writes": self-copies are dropped instead of recorded.** The watcher returns early on the marker (`ClipboardWatcher.swift:72-74`). The design records exactly one capture event with source `muninn`. `ClipboardWriter` writes an empty marker with no item id and no `org.nspasteboard.source`.
- **§4.11 CLI contract / gate B: the CLI is v1.**
  - Missing commands: `history`, `paste`, `open`, `session`, `doctor`, `debug send`, and `status --limits`/`--audit`.
  - Missing global flags: `--no-interactive`, `--width` and `--version`.
  - `search` requires a query and has no filters.
  - `--json` prints the raw IPC envelope to stdout, even on errors. It has no `schemaVersion` and no `error.json` on stderr.
  - Every failure exits 1, including "helper unreachable" (should be 3) and "not found" (should be 2). Codes 2–9 aren't implemented.
  - `list`/`search` return full `content`, not a size-capped `preview` plus `byteSize`.
  - There's no "showing 20 of N" notice on stderr; a count goes to stdout instead.
  - `list --all` sends `Int.max` as the limit instead of streaming.
  - `copy` refuses non-text items ("cannot copy this item yet").
- **§4.11 IPC methods:** `hello`, `diagnostics`, `cancel`, `history`, `payload`, `session` and `subscribe` don't exist.
- **§4.12 / gate B: no access policy.** There are no scopes, sessions, approvals, protected items, `audit_log` or `non_interactive` refusal. Any local process can read and delete all history, including `resume` with no scope.
- **§4.13 / §4.14: there's no `MuninnLimits`.** The only limit is a hard-coded `maxContentSize = 1_000_000` in `ClipboardStore.swift:14`, checked *after* the full string is read. There are no flood, fan-out, timeout or disk-floor guardrails and no `omitted`/`notProcessed` labels. File fan-out keeps the first 20 names (`ClipboardWatcher.swift:107`). The design keeps "no references; count and common folder only" past the limit.
- **§4.15: content goes into logs.** `muninnd` `print`s a 60-character preview of every captured item to stdout (`apps/muninnd/Sources/main.swift:24-25`), along with the DB path and error descriptions. The design forbids logging clipboard content and file paths in release builds. No `os.Logger` or `OSSignposter` is used anywhere.
- **§4.16 onboarding: none of the pasteboard-privacy onboarding exists.** The watcher reads the pasteboard on every change with no `accessBehavior` check. The first-run panel (`SetupView.swift`) has no *Enable Clipboard Monitoring* step and no access-state display. `FirstRunManager` uses `UserDefaults`, which the design doesn't mention.
- **§4.17: the menu bar icon is the SF Symbol `doc.on.clipboard`** with no state modes and no text label. The paused/offline state appears only inside the panel footer.
- **§5 / gate C: no v1 → v2 migration code.**
- **§4.9: no integration, policy, fault-injection, migration, benchmark, UI or release-signed tests.** Tests cover only v1 store, IPC and CLI behavior.
- **§4.10 / gate C: no signing, notarization or bundling scripts.**

### Code not covered by the design

- **`CLIInstaller`** (`apps/muninn-menubar/Sources/CLIInstaller.swift`) symlinks the CLI into `/usr/local/bin`, `/opt/homebrew/bin` or `~/.local/bin`. The design refers to a "symlink on `PATH`" only in `doctor` check 1. It doesn't say who creates the symlink, or where.
- **The global hotkey ⌘⌥V** (`HotKeyManager.swift:30-45`) is hard-coded. The design keeps the Carbon hotkey but doesn't specify the binding or whether it's configurable.
- **`muninnd run`**: the app passes a `run` argument (`HelperManager.swift:75`) that the helper ignores. Neither is in the design.

**Suggestion for cheaper future reports:** add a short "Implementation map" to §4.1 that maps each design component to its source path (e.g. `SearchService` → `packages/MuninnSearch/Sources/SearchService.swift`) once gate B creates them. Then the drift check can go straight to the files instead of searching.
