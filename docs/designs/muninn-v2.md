# Muninn v2 — Design

Status: **Draft** · Started 2026-11-08

This is **what we are building and why**. It works with two companion documents:

| Document | Holds |
|---|---|
| `docs/designs/muninn-v2.md` (this) | architecture, invariants, interfaces |
| `docs/proofs.md` | claims, experiments, expected and **observed** results |
| `docs/decisions.md` | accepted, revised, pending and open decisions |
| `docs/reviews/` | fresh-context (Goldfish) reviews of this document and their resolution |

**Proof-oriented development.** We prove architectural assumptions before committing to them; we don't attempt to formally prove the whole application. Statements marked with a proof ID, like *(PROOF-004)*, are **hypotheses until that proof passes**. Delivery runs through evidence gates (§7), and each gate produces a working system plus an evidence record.

**v2 is a new, better product, not an increment on v1.** v1's interfaces and data
layout are not compatibility constraints; the only thing carried over is the
user's existing history (§5). §2 records what v1 actually is, so we know what
we are replacing.

**Security is a foundation, not a feature.** A clipboard history holds passwords,
tokens, private messages and documents. Every design choice below is made under
the threat model in §1.1. Encrypting the database on disk is the baseline, not an option.

---

## 1. Goals and non-goals

### Goals

1. **Private by default at rest.** History, assets and indexes are encrypted on disk. The key is stored only in the Keychain, and clipboard content never appears in logs.
2. **Faithful, best-effort capture.** For every clipboard state Muninn observes, keep every compatible representation (text, rich text, images, file references) and when and where it was copied, without storing duplicates. Capture is best-effort, with explicit guarantees (§4.8): polling can miss states that are overwritten between checks, and Muninn counts those gaps rather than hiding them.
3. **One fast search engine.** A shared `SearchService` for panel and CLI: words, substrings, filters and recency-aware ranking. It must hold up at 100k+ items with mixed PT/EN text and code.
4. **Capture is never slowed by heavy processing.** OCR, extraction and previews run in a separate, resumable, idempotent pipeline.
5. **Identity ≠ authorization.** Only Muninn's signed clients can connect, and reading history from the CLI needs a deliberate, user-approved session.
6. **A real macOS app and a dependable CLI.** A signed `.app` from one Xcode project, with the helper as a user-level background service. The CLI has stable JSON schemas and exit codes.
7. **Modern Swift end to end.** Swift 6 strict concurrency, actors for state, no shared mutable singletons. Unsafe escape hatches exist only in the allow-listed C-interop layer.

### Non-goals (v2)

- Sync, accounts, or any network access.
- Mac App Store distribution (sandboxing conflicts with the CLI and helper model).
- Plugin / extension system.
- Cross-platform support.
- Semantic search, embedding models, or a vector database. The search design leaves room for an optional second stage later (§4.7).

> **Open:** product-level features beyond the platform work (snippets, collections, retention policies, agent/MCP access) are not yet scoped (D1).

**A product change from v1, stated plainly.** In v1 the CLI could read all history with no setup. In v2 it can't:
- The first data command in a terminal asks for Touch ID or your password in the app, and the resulting session expires.
- Scripts, cron jobs and agents have **no** access to history in v2. Automation grants are deferred until D1 decides agent access (D27).

The README's "no manual setup required" still holds for the app; it no longer holds for reading history from the CLI.

### 1.1 Security model

**What we protect:** clipboard content and everything derived from it (representations, assets, extracted text, previews, indexes), plus metadata that reveals behavior (which app, when).

**What we promise and what we don't.** Muninn **never intentionally persists plaintext**: not in its database, assets, temp files, logs or backups it makes. It can't promise that plaintext never reaches disk *anywhere*, because these are outside its control:
- **macOS swap and memory compression** (swap is encrypted by macOS)
- **system diagnostics:** crash reports, sysdiagnose, spindumps (we keep content out of what we log, §4.15)
- **terminal output:** `muninn get`/`paste` print content by design, and scrollback, shell history and anything a pipe writes to are the user's
- **the system pasteboard itself:** other apps, clipboard sync and Universal Clipboard see what's copied regardless of Muninn

FileVault is the control for those.

| Threat | In scope? | Mitigation |
|---|---|---|
| Disk theft, lost Mac, copied backups, another macOS user reading files | ✅ | Everything, including binary assets, lives in the SQLCipher DB; no plaintext temp files (§4.3); key only in the Keychain, device-only (§4.4) |
| A process running as the user **reading Muninn's files directly** | ✅ | Files are ciphertext. The Keychain item's access is tied to the helper's code signature, so another process can't take the key without a prompt. |
| A process running as the user **connecting to the socket** | ✅ | Peer UID and code-identity checks; only signed Muninn app/CLI (§4.6) |
| A script, cron job or agent **driving the signed CLI** | ✅ | No history without a user-approved, scoped, short-lived session bound to a terminal. Automation has no access in v2 (D27). Every request is audited (§4.12). |
| A process running **inside a terminal that has an active session** | ⚠️ accepted | It inherits that session until it expires, ends, or the Mac locks, the same tradeoff as `sudo`'s cached credentials. No design can reliably tell the intent of a same-user process; we limit scope and duration and audit instead (§4.12). |
| Access while the Mac is **locked** | ✅ | **The guarantee is the policy gate:** while locked, the helper serves no data and all sessions end (§4.4). Closing the DB and wiping key buffers is defense in depth only, because the Keychain class lets the helper re-read the key without the user. |
| Leaks through logs, crash reports, temp files, Spotlight, Quick Look caches | ✅ | Log privacy (§4.15); in-memory temp store; data dir excluded from Spotlight (`.metadata_never_index`); previews stored as encrypted assets, never in shared caches |
| Malicious content (crafted PDFs/images) attacking parsers | ⚠️ partial | Processors are pure, time-limited and rate-limited; out-of-process isolation is D17 |
| Code injection into Muninn's own processes | ⚠️ partial | Hardened runtime, library validation, no `get-task-allow` in release, no dynamic plugin loading |
| Plaintext v1 remnants on disk | ⚠️ partial | Deleted after migration; we tell the user that SSD free blocks and existing snapshots aren't erased, and recommend FileVault (§5) |
| root / kernel compromise; malware with debugger access to an unlocked session; someone at the unlocked Mac | ❌ | Out of scope. No app-level design can defend against these; FileVault and screen lock are the user's controls. |

### 1.2 Invariants

These must hold in every phase and every build. Breaking one is a bug, whatever else the change achieves.

1. **Muninn never intentionally persists plaintext.** Clipboard content and anything derived from it is written by Muninn only encrypted: DB, assets, temp files, logs. What's outside Muninn's control is listed in §1.1.
2. **Only the helper holds the key and opens the database, and only while the user's session is unlocked.** The UI and CLI see data only through IPC.
3. **Being signed doesn't grant access.** The CLI reads no history without a user-approved, scoped, short-lived session. Every request is audited, and search never reveals what a caller can't read.
4. **Capture is policy-first and never waits on heavy work.** A copy skipped for privacy leaves no trace, and heavy processing never slows capture.
5. **History is append-only, and deletion is complete.** Capture events are never edited; deleting an item removes everything about it.
6. **Processing is idempotent and only writes derived data.** Re-running any job, including after a crash, changes nothing else.
7. **There is one search engine.** The same query on the same data returns the same results in the panel and the CLI.
8. **Unreadable data is never silently destroyed.**
9. **Memory stays healthy.** The always-running processes have a small, fixed idle footprint. It does **not** grow with history size (100 items or 100k) or with uptime (day 1 or day 30), and every burst of work returns to it. Heavy work happens only in processes that exit afterwards (§4.13).
10. **Every input is bounded, and limits are explicit.** No single copy, burst of copies, crafted file or client can exhaust memory, disk or CPU, or push the user's real history out. Beyond a published limit Muninn does less, never part of a job, and says what it didn't do (§4.14).

---

## 2. Current state (v1, as of `ab1e0b2`)

```text
NSPasteboard ──poll 0.5s──► ClipboardWatcher ─► ClipboardStore ─► SQLite (plaintext)
                                   muninnd (helper)
                                        ▲  Unix socket, newline-delimited JSON
                     ┌──────────────────┴──────────────────┐
              muninn-menubar                           muninn (CLI)
         (spawns muninnd via Process())
```

| Area | v1 reality |
|---|---|
| Targets | Pure SwiftPM: 3 executables, 4 libraries, `CSQLite` system-library shim. No `.xcodeproj` (and `.gitignore` excludes `*.xcodeproj`). |
| Concurrency | Mixed: async/await, `Task`, `@MainActor` in UI; `NSLock` + `@unchecked Sendable` in store, watcher, IPC server; `Thread.detachNewThread` per IPC connection; `DispatchQueue.main.sync` in the helper. |
| Storage | System SQLite, WAL, single table `clipboard_entries(id, content, content_hash, created_at, is_pinned, kind, metadata)`, ad-hoc `schema_version` table (v1). **Unencrypted.** |
| Non-text content | Kind + metadata only (dimensions, file names). Image bytes and file contents are **not stored**; `content` holds a placeholder. |
| Search | `content LIKE '%q%'` — unranked, no index use. |
| Background | Menu bar app launches `muninnd run` as a child `Process` and restarts it on exit. `SMAppService.mainApp` only for launch-at-login of the app itself. |
| IPC | `AF_UNIX` socket at `~/Library/Application Support/Muninn/muninn.sock`. No peer authentication; no explicit socket permissions. |
| Testing | Swift Testing: store, IPC, and CLI (spawns real processes). 48 tests. No UI tests. |
| Distribution | README describes `Muninn.app`, but the repo has no bundling, signing, or notarization pipeline. |
| Toolchain | ✅ Updated in v2 kickoff: `swift-tools-version: 6.4` (Swift 6.4.2 / Xcode 27.2), Swift Build engine (SwiftPM default). |

**Reused from v1, not rewritten:**
- the `packages/` and `apps/` module layout
- `Paths` (extended with dev/release data dirs)
- the self-copy pasteboard marker (`MuninnPaths.pasteboardMarkerType`)
- the Carbon hotkey (`HotKeyManager`, with its global handler replaced, §4.2)
- the CLI process test harness (`CLITests.swift`)
- the first-run panel structure

---

## 3. Target stack

| Area | v2 choice | Delta from v1 |
|---|---|---|
| Concurrency | Swift actors, async/await, structured concurrency | Rework |
| Interface | SwiftUI + selective AppKit | Keep |
| Package management | Swift Package Manager | Keep |
| App packaging | Native Xcode app target | **New** |
| Storage | SQLite with SQLCipher encryption; events / content / representations / derived model | **New** |
| Key management | macOS Keychain | **New** |
| Background execution | User-level background service (`SMAppService.agent`) | Rework |
| Process communication | Authenticated local IPC | Rework |
| Search | Shared `SearchService`: FTS5 words + trigram, structured filters, ranking with recency, cursors | **New** |
| File processing | Separate job pipeline: Foundation/AppKit, Vision, PDFKit, ImageIO + Core Image, UniformTypeIdentifiers, NaturalLanguage (previews in memory only) | **New** |
| Testing | Swift Testing + integration / UI tests | Extend |
| Distribution | Signed `.app`, local installation | **New** |
| Build tooling | Swift 6.4, Swift Build, strict target-import checking | ✅ Done |

---

## 4. Architecture

```text
                         Muninn.app (signed, Developer ID)
 ┌──────────────────────────────────────────────────────────────────────┐
 │ Contents/MacOS/Muninn          menu bar UI (SwiftUI + AppKit)          │
 │ Contents/MacOS/muninnd         helper — registered via SMAppService    │
 │ Contents/MacOS/muninn          CLI                                     │
 │ Contents/Library/LaunchAgents/com.muninn.helper.plist                  │
 └──────────────────────────────────────────────────────────────────────┘

 muninnd
   capture path (fast, never blocks on processing)
     PasteboardMonitor ─► CapturePolicy ─► StoreWriter: event + content + representations
       (@MainActor)       (allow/skip)        + assets + enqueue jobs (one transaction)
                                                         │
   processing pipeline (separate, resumable)             ▼
     ProcessingRunner (helper) ◄── processing_jobs
       ├─ helper steps: index (rebuild an item's FTS rows), apply outputs
       └─ worker jobs ──► muninn-worker (sandboxed, on demand): text · ocr · pdf · preview
          outputs ──► StoreWriter (one transaction per job)
                                                                      
   query path
     IPCServer ─ peer auth ─ AccessPolicy ─► router ─► SearchService (reader connections)
                                                  └──► StoreReader
                                 SQLCipher DB (WAL) · key ◄── Keychain
```

### 4.1 Repository structure and packaging

**One repository, one Xcode application project, shared Swift packages.**

```text
muninn/
├── Muninn.xcodeproj/          the only Xcode project: app target + UI-test target
├── App/                       app-target-only files
│   ├── MuninnApp.swift        @main, a thin shell that composes MuninnUI
│   ├── Info.plist · Muninn.entitlements · Assets.xcassets
│   └── LaunchAgents/com.muninn.helper.plist
├── Package.swift              shared package: every library, muninnd, CLI, tests
├── packages/                  libraries (one directory per module)
│   ├── MuninnCore/            models, IDs, paths, IPC message types (no I/O)
│   ├── MuninnStore/           SQLCipher, schema, migrations, StoreWriter/StoreReader
│   ├── MuninnSearch/          SearchService, query planner, ranking, cursors
│   ├── MuninnProcessing/      job runner + Processor protocol
│   ├── MuninnProcessors/      Apple-framework processors (Vision, PDFKit, …)
│   ├── MuninnCapture/         PasteboardMonitor + CapturePolicy (was MuninnClipboard)
│   ├── MuninnSecurity/        KeyProvider, PeerAuthenticator, AccessPolicy
│   ├── MuninnIPC/             socket server/client, framing
│   ├── MuninnTransform/       pure transforms for `muninn transform`
│   └── MuninnUI/              SwiftUI panel, settings, approval prompt
├── apps/
│   ├── muninnd/               helper: composition root only
│   ├── muninn-worker/         on-demand processor worker (XPC service in the bundle)
│   └── muninn-cli/            CLI
├── benchmarks/                search + asset-storage benchmarks, corpus generator
└── docs/                      design docs, cli-schemas/
```

**Dependency rules.** Each rule is enforced by `--explicit-target-dependency-import-check error` and by declaring only the allowed dependencies.

- `MuninnCore` depends on nothing of ours.
- `MuninnProcessors` depends only on `MuninnCore` and Apple frameworks. Processors never see the database.
- `MuninnUI` and `muninn-cli` depend only on `MuninnCore`, `MuninnIPC` and `MuninnTransform`. **Clients never link the store or search.** All data access goes through the helper, which is where policy lives.
- `muninnd` is the only target that links `MuninnStore`, `MuninnSearch`, `MuninnProcessing` and `MuninnSecurity`.
- `muninnd` does **not** link `MuninnProcessors`. Only `muninn-worker` (and tests) do, so Vision, PDFKit and Core Image never load into the always-running helper (§4.13).

**The Xcode project** contains only the app target and its UI tests. It depends on the local package's products and embeds `muninnd` and `muninn` into `Contents/MacOS`. All logic, including the UI, lives in the package. The project owns bundle layout, `Info.plist`, entitlements, signing and embedding.

**What already exists and what moves when.** v1 already has the `packages/` + `apps/` layout and one `Package.swift`.
- **Gate B** adds library modules inside that layout (`MuninnSearch`, `MuninnSecurity`, `MuninnProcessing`). That isn't a restructure.
- **Gate C** is the restructure:
  - add `Muninn.xcodeproj` and `App/`
  - extract the menu bar UI from `apps/muninn-menubar` into `packages/MuninnUI`
  - rename `MuninnClipboard` to `MuninnCapture`
  - replace `HelperManager`'s `Process()` with `SMAppService.agent`
  - update `.gitignore`
- **Gate D** adds `apps/muninn-worker` and `MuninnProcessors`.

One `Package.swift` with several library products is enough for now. Split into separate packages only if build times or reuse outside this repo ever demand it.
- **Hard rule:** `swift build` and `swift test` build and test everything except the app bundle (all libraries, `muninnd` and the CLI) without opening Xcode. Nothing outside the Xcode project may import a module that only exists there. CI runs both commands.
- Signing-dependent behavior sits behind protocols so it can be swapped out under `swift test`: a `KeyProvider` (Keychain vs. in-memory test key) and a `PeerAuthenticator` (code signature vs. UID-only for the test harness). A release `muninnd` never accepts the test variants; they are injected only by test code, never chosen by flags or environment variables.
- **Dev builds are isolated, not weakened.** A `DEBUG` build of `muninnd` (e.g. `swift run muninnd`) is compiled to:
  - use a separate data directory (`~/Library/Application Support/Muninn-Dev/`) and a separate Keychain service (`com.muninn.dev`)
  - authenticate peers by UID only, because unsigned binaries have no stable code identity

  This is decided at **compile time**, not by flags or environment variables, so a release binary has no dev path at all. Dev builds can never read real data. The access policy (§4.12) applies unchanged in every build.
- `.gitignore` changes to track the project (keep ignoring `xcuserdata/`).

### 4.2 Concurrency model

| Component | Isolation |
|---|---|
| `PasteboardMonitor` | `@MainActor` (NSPasteboard is main-thread). Emits captures via `AsyncStream`. |
| `CapturePolicy` | Pure, synchronous decision: store, skip or mark protected. No I/O. |
| `StoreWriter` | actor owning the **single write connection**. Replaces `NSLock` + `@unchecked Sendable`. |
| `StoreReader` / `SearchService` | Small pool of **read-only connections** (WAL allows concurrent readers), so a slow search never blocks capture. Searches are cancellable (§4.7). |
| `ProcessingRunner` | actor **in the helper**. It schedules jobs, runs helper steps itself (the `index` rebuild, applying outputs), and sends worker jobs to `muninn-worker` with a concurrency limit and per-job timeouts. It never runs parsers in the helper (§4.8). |
| `IPCServer` | accept loop as a `Task`; one child task per connection, with one child task per in-flight request inside it (requests are multiplexed by `requestId`, §4.6). Cancellation on shutdown and on disconnect. Replaces detached threads. |
| Helper ↔ watcher | `await`-based calls instead of `DispatchQueue.main.sync`. |

#### Swift conventions (enforced)

1. **Swift 6 language mode with complete strict concurrency** on every target. This is already the default with tools-version 6.4 and is stated explicitly in `Package.swift` (`swiftLanguageModes: [.v6]`). Concurrency warnings are errors.
2. **Actors for stateful services:** `StoreWriter`, `ProcessingRunner`, `SearchService`'s connection pool, and IPC and CLI session state. Stateless logic (`CapturePolicy`, processors, transforms, query parsing) is plain `Sendable` value types and functions.
3. **AppKit and SwiftUI state lives on the main actor.** `MuninnUI` and `MuninnCapture`'s pasteboard monitor are compiled with `defaultIsolation(MainActor.self)`. View models are `@MainActor @Observable`. Work leaves the main actor only through explicit `async` calls into services.
4. **No shared mutable singletons.**
   - No `static var shared` and no mutable globals.
   - Dependencies are created once in a **composition root** (`muninnd/main.swift`, `App/MuninnApp.swift`) and passed in through initializers.
   - Immutable configuration (paths, constants) may be static `let`.
   - v1's `nonisolated(unsafe)` global hotkey handler is replaced by a main-actor-owned registration.
5. **Escape hatches are allow-listed.**
   - `@unchecked Sendable`, `nonisolated(unsafe)` and `@preconcurrency` are allowed only in the C-interop layers (SQLite/SQLCipher wrapper, socket file descriptors, Carbon hotkey bridge).
   - Each use carries a `// SAFETY:` comment explaining the invariant.
   - A CI grep fails the build on any use outside those files.
6. **No GCD or locks in our code.** No `DispatchQueue`, `NSLock` or `Thread`. The exceptions are inside the C-interop wrappers where an API requires them, and they're documented as above.
7. **Structured concurrency first.** Prefer child tasks and `TaskGroup`. Unstructured `Task {}` is allowed only at boundaries (UI event handlers, accept loop), and is always stored so it can be cancelled. `Task.detached` is not used.
8. **Cancellation is honored.** Long work (search, processors, IPC reads) checks `Task.isCancelled` / `try Task.checkCancellation()` at loop boundaries.

### 4.3 Storage — data model

This is the most important change in v2. v1 models a copy as *one string plus a kind*. That works for text but loses information for screenshots, rich text, PDFs and files. v2 separates three concepts:

| Concept | Question it answers | Mutability |
|---|---|---|
| **Capture event** | *When* was something copied, from *which app*, and with *which pasteboard types* available? | Immutable (deletable) |
| **Content** | *What* was copied: the canonical item and **all compatible representations** of it (plain text, HTML, RTF, image, file reference) | Stable once written |
| **Derived content** | What do we *know* about it: OCR text, PDF text, previews, detected URLs, classification, later embeddings | Recomputable from content |

#### Schema

```text
capture_events ──► content_items ◄── saved_items
                        │
                        ├──► representations ──► assets
                        │          │
                        │          └──► (file references: bookmark + metadata)
                        │
                        ├──► extracted_text ──┐
                        ├──► previews ──► assets
                        ├──► annotations      ├──► search_words / search_trigram (FTS5)
                        └──► processing_jobs  │
              representations.text ───────────┘
```

| Table | Purpose | Key columns |
|---|---|---|
| `capture_events` | Immutable history of copy events | `id`, `content_item_id`, `captured_at`, `source_bundle_id`, `source_app_name`, `change_count`, `available_types` (JSON list of UTIs on the pasteboard) |
| `content_items` | Canonical content, reused across events | `id`, `content_hash` (unique), `primary_kind`, `first_captured_at`, `last_captured_at`, `capture_count`, `is_protected` |
| `representations` | One row per stored representation of an item | `id`, `content_item_id`, `uti`, `role` (`primary`/`alternate`), `text` (for text-like types), `asset_id` (for binary), file-reference fields (`bookmark`, `path`, `file_size`, `file_mtime`), `byte_size` |
| `assets` | Stored binary content, deduplicated by hash | `id`, `sha256` (unique), `byte_size`, `chunk_size`, `storage` (`inline`; `external` reserved, D15) |
| `asset_chunks` | The bytes of each asset, split into chunks inside the encrypted DB | `asset_id`, `idx`, `data` (BLOB). Primary key `(asset_id, idx)` |
| `extracted_text` | OCR and document extraction results | `id`, `content_item_id`, `representation_id`, `source` (`ocr`/`pdf`/`html`/`rtf`), `text`, `language`, `confidence`, `extractor_version` |
| `saved_items` | Pinned or explicitly saved content | `content_item_id`, `saved_at`, `label`, `is_pinned` |
| `processing_jobs` | Resumable background processing | `id`, `content_item_id`, `processor_id`, `processor_version`, `state` (`pending`/`running`/`done`/`failed`), `attempts`, `last_error`, `priority`, `updated_at`. **Unique** on `(content_item_id, processor_id, processor_version)` |
| `schema_migrations` | Versioned, recoverable migrations | `version`, `name`, `applied_at`, `checksum` |
| *`previews`* (addition) | Generated thumbnails | `content_item_id`, `asset_id`, `max_dimension` |
| *`annotations`* (addition) | Small derived facts | `content_item_id`, `kind`, `value` (JSON), `producer_version`. In v2, written only by migration (`v1_metadata`) and `pdf` (page count); other producers come with the features that need them (D28). |
| `search_words`, `search_trigram` | The two FTS5 indexes (§4.7) over `representations.text` and `extracted_text.text` | written **only** by the `index` step, never by triggers |
| `settings` | Helper-owned configuration: protected-apps list, overrides of `MuninnLimits` defaults within their ceilings, storage warning thresholds, processor toggles | `key`, `value` (JSON), `updated_at`. Edited by the UI via IPC; never read from files |
| `audit_log` | Sessions and every CLI data request | `id`, `at`, `client` (signing identifier), `session_id`, `operation`, `content_item_id`, `decision` (`allowed`/`denied`/`approved`) |

#### Encryption parameters

- **Keying:** SQLCipher 4 defaults (AES-256, HMAC-SHA512 page authentication). The key is a random 256-bit **raw key** (`PRAGMA key = "x'…'"`), so PBKDF2 is skipped. Nothing user-memorable is involved, and startup stays fast.
- **What is encrypted:** the WAL and the rollback journal are encrypted by SQLCipher.
- **Temp files:** `PRAGMA temp_store = MEMORY` keeps plaintext out of temp files.
- **Binary assets:** stored as chunks **inside** the SQLCipher DB, so they get the same encryption and page authentication. There is no separate crypto format in v2 (see "Binary storage" below).
- **Memory:** clipboard content is plaintext in the helper's memory while in use. That's accepted; the threat model is data at rest and other local callers, not a compromised user session.

Embeddings are **not** in v2. When they come, they get their own table keyed by `content_item_id` plus the model version. Nothing else needs to change.

#### Deduplication — two levels

1. **Content level.** `content_hash` = SHA-256 over the sorted `(uti, sha256(representation bytes))` pairs. Copying the same thing again adds a `capture_event` and bumps `last_captured_at` / `capture_count`. No new content is stored. History keeps every copy; storage keeps one item.
2. **Asset level.** Assets are keyed by their own hash. The same image bytes appearing in two *different* content items (e.g. the same screenshot copied once alone and once with a caption) are stored once.

An asset is deleted, chunks included, in the same transaction that removes its last reference.

#### Which representations are kept

- **Keep** the public, interoperable types: plain text, RTF, HTML, PNG/TIFF/JPEG/HEIC, PDF, file URLs.
- **Skip** representations that are only lossless re-encodings of one already kept. For example, a TIFF that matches the PNG pixel for pixel is dropped and regenerated on `copy` if needed.
- **Skip** private or dynamic types (`dyn.*` and app-internal types) unless they're on an allowlist.
- `available_types` on the capture event still records **everything** that was offered, so we know what we chose not to keep.

#### Files copied from Finder

- **Default: reference, don't duplicate.** Store a `representations` row with a bookmark (`URL.bookmarkData`, which survives renames and moves), path, size and modification time. The file's contents are **not** copied.
- **Snapshot is an explicit capability.** Storing an encrypted copy of a file's contents happens only when the user asks: per item ("Save snapshot") or through a setting with a size cap. A snapshot becomes an `assets` row like any other binary.
- If a reference goes stale (file deleted or moved off-volume), the item keeps its metadata and shows "file unavailable". `copy` fails with exit 2, and nothing is silently substituted.
- Whether to extract text from *referenced* files (e.g. index a copied PDF without snapshotting it) is D14.

#### Binary storage: chunked, inside SQLCipher

v2 stores **every** binary asset inside the encrypted DB. It's split into rows of `asset_chunks`, and written and read with SQLite incremental BLOB I/O, so memory stays bounded by the chunk size. That gives us, for free:
- encryption and page authentication, the same as for everything else
- **atomicity:** asset chunks commit or roll back with the capture transaction, and deletes are equally atomic. There are no files outside the transaction, no publish protocol, no tombstones and no reconciliation.
- streaming `paste` and `copy`, chunk by chunk
- if rekeying is ever needed, `sqlcipher_export` covers history and assets in one step

The DB runs with `auto_vacuum = INCREMENTAL`, so space freed by deletes is reclaimed in idle time (§4.16).

**Costs PROOF-005 must measure:**
- **Size:** the DB file grows large. `VACUUM`, backup and restore all handle one big file, and Time Machine copies a changed file whole.
- **WAL bursts** from large captures, which need `wal_autocheckpoint` tuning.
- **Insert, read and delete latency** across 10 KB–50 MB assets as the DB grows.
- **Chunk size**, somewhere between 64 KB and 1 MB.

**External store: only if PROOF-005 shows inline is unacceptable.** `assets.storage` reserves `external`, so adding it later needs no schema change. It would be designed then, not now. Notes for that design: per-asset keys wrapped by a key-encryption key (envelope encryption, so rotation rewraps small keys instead of re-encrypting files); a crash-safe publish protocol where a DB reference points only to a complete, verified file; and startup reconciliation.

**No key rotation in v2** (D29). The key is device-only and never leaves the Keychain or the helper. A suspected compromise of it implies a threat that §1.1 puts out of scope.

#### Deletion

"Immutable" means events are never *edited*. They can still be deleted.
- `delete <id>` removes the content item, its events, representations, derived rows, jobs, and any asset (with its chunks) left unreferenced, all in **one DB transaction**.
- Privacy wins over history.

#### Processing jobs

See §4.8. The storage-level guarantee is that the capture transaction **includes enqueuing its jobs**, so a crash can never leave stored content with no work scheduled for it.

#### Migrations

- An ordered list of migrations in code. Each one runs in a transaction and is recorded in `schema_migrations` with a checksum, and a checksum mismatch on startup is an error.
- Before any destructive migration, the helper copies the DB to `muninn.db.pre-<version>` and keeps it until the next successful start. That copy is encrypted the same way, so it's safe to leave on disk briefly.
- Replaces v1's ad-hoc `schema_version` table.

#### API shape

- IPC and CLI ids refer to **content items**. Copying the same thing again doesn't create a new id; it moves the item to the top of `list`.
- `get` returns the item, its representations (uti, size, role) and its derived text.
- `capture_events` are exposed through `muninn history <id>`, which lists when and from where an item was copied.

### 4.4 Key management

- On first run, the helper generates a random 256-bit key and stores it as a generic password in the **data-protection keychain** (`kSecUseDataProtectionKeychain`). Service is `com.muninn.db`, accessibility is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and it's not synchronizable.
- **Only the helper reads the key** (D3). In the data-protection keychain, access is governed by **keychain access groups, which come from signing entitlements**. So:
  - "only the helper" means **one private access group**, `<TeamID>.com.muninn.helper`, granted through the `keychain-access-groups` entitlement on the **helper only**
  - the app, CLI and worker don't get that entitlement
  - "no access group" was wrong; the right statement is "no *shared* access group"
- **PROOF-003:** whether that entitlement needs an embedded provisioning profile for a Developer ID build. If it does, the helper must ship as a bundle (e.g. `Contents/Library/LoginItems/Muninn Helper.app`) rather than a bare executable in `Contents/MacOS`, and §4.1 and §4.5 change accordingly. This also decides D22 (Secure Enclave wrapping).
- **Consequences, stated in the UI:**
  - Losing the key means losing the history.
  - Because the key is device-only, Time Machine restores and Migration Assistant to a new Mac bring back the encrypted DB **without** its key, so the history is unreadable there. Moving history between Macs needs an explicit export (D19).
- **If the key is missing at startup** but a DB exists (restored backup, Keychain reset):
  - the helper **does not** create a new key over it
  - it moves the unreadable DB aside to `muninn.db.orphaned-<date>`, reports the situation to the UI and `doctor`, and starts with an empty history only after the user confirms

  Unreadable data is never silently discarded.

#### Session lock: Muninn locks when the Mac locks

`AfterFirstUnlock` is needed so the helper can run in the background after login. But it means the Keychain keeps returning the key **after the first unlock until the next restart, even while the screen is locked**. The Keychain class alone therefore can't make Muninn inaccessible on a locked Mac, so the helper enforces that itself.

**The guarantee is the policy gate:** while locked, no data leaves the helper. Wiping keys from memory is **defense in depth**: the helper can re-read the key without the user, so the wipe only helps against reading memory on a locked Mac, which is out of scope (§1.1). Making the wipe meaningful requires user presence to reopen, which is D25.

- **Signals:**
  - screen lock and unlock
  - fast user switching (`NSWorkspace` session resign/become active)
  - sleep and wake

  Which documented APIs give lock state reliably to a background agent is part of PROOF-003.
- **On lock** (and on switching away from the user's session):
  1. Stop serving data. Every data request returns `locked` (CLI exit 6, `reason: locked`); `status` still answers.
  2. End all sessions (§4.12).
  3. Pause capture. Clipboard changes on a locked Mac don't come from the user.
  4. Stop the worker and pause the job queue.
  5. *Defense in depth:* close every DB connection, clear the key from a zeroizing buffer, run SQLCipher with memory security on, and drop caches and in-flight payloads.
- **On unlock:** the helper reads the key from the Keychain, reopens the connections, resumes capture and jobs, and the raven returns to *recording*. Sessions don't come back; they must be approved again.
- **Limits, stated:** wiping our buffers doesn't guarantee that no plaintext remains in memory the OS has already compressed or paged out. macOS encrypts swap, and FileVault protects the disk, but a process with debugger access to an unlocked session is out of scope (§1.1).
- **Stricter mode** (D25): requiring Touch ID or a password **in Muninn** after every unlock or restart, enforced at the key level, needs a key protected by access control (`.userPresence`) and the app passing an authenticated context to the helper. That's not in v2's default; the lock behavior above is.

### 4.5 Background execution

- The helper is registered with `SMAppService.agent(plistName:)` from the app bundle. launchd owns its lifecycle: start at login, `KeepAlive`, crash restart.
- `HelperManager`'s `Process()` spawn/restart logic is removed.
- The first-run panel handles the "Allow in Login Items" approval state (`.requiresApproval`).

### 4.6 IPC: protocol and authentication

#### Authentication (identity)

Layered, cheapest first. Checked once per connection, before any request is read:

1. **Filesystem:** socket directory `0700`, socket `0600`, owned by the user.
2. **Peer UID:** `getpeereid()` must equal the helper's UID.
3. **Code identity:** obtain the peer's audit token (`LOCAL_PEERTOKEN`) and validate it with `SecCode` against a designated requirement: same Team ID and an identifier in {app, CLI}. The result, **`client = app | cli`**, is attached to the connection and used by the access policy (§4.12).

Release builds always apply all three layers. Dev builds use layers 1–2 against the separate dev data (§4.1).

#### Transport: pending PROOF-002 (D21)

A launchd `MachServices` **XPC endpoint** with `xpc_connection_set_peer_code_signing_requirement` provides much of what the socket protocol below rebuilds by hand: code-identity checks, message framing, concurrent requests, out-of-band data, connection lifecycle. PROOF-002 compares the two on **reliability and implementation cost**.

If the socket stays, these are the XPC features we deliberately rebuild, and why:

| Rebuilt | Why it's worth rebuilding |
|---|---|
| handshake and versioning | one wire format the CLI, app and `muninn debug send` all share, and that's readable |
| `requestId` multiplexing, `cancel` / `supersedes` | needed by type-ahead search either way |
| binary bodies (or `SCM_RIGHTS` file-descriptor passing, the cheaper alternative to evaluate) | streaming `paste` |
| event subscriptions and keepalive | live panel updates and approval prompts |
| audit-token code-identity check | the same `SecCode` machinery XPC uses internally |

#### Protocol v2 (if the socket is kept)

The protocol is still line-oriented JSON, so it stays readable, but v1's one-request-per-connection model can't support cancellation, binary payloads or prompts pushed to the app. v2 defines:

- **Frames.**
  - Every frame is one JSON object on one line.
  - A frame may declare `"bodyLength": N`. Exactly N raw bytes follow the newline, which is how `payload` carries images and PDFs without base64.
  - Maximum line length is 1 MB; maximum body is the asset size cap.
- **Handshake.** The first frame on a connection is `hello { protocolVersion, client, clientVersion }`. The helper replies with its own versions and capabilities. An incompatible major version → `version_mismatch` and the connection is closed. This is the case where a stale CLI symlink is talking to a newer helper; the CLI reports it with exit 8.
- **Multiplexing.** Every request carries a client-chosen `requestId`, and every response echoes it. Several requests can be in flight on one connection, which is what makes `supersedes` / `cancel` (§4.7) work.
- **Events.** A client may `subscribe { topics }` and then receives `event` frames with no `requestId`:
  - `itemAdded` / `itemUpdated` / `itemDeleted`: the panel updates live instead of polling.
  - `approvalRequested`: the app shows the prompt (§4.12).
  - `sessionChanged`, `pausedChanged`, `jobsProgress`.
- **Errors.** Errors keep v1's `{category, message}` shape, plus a stable `code` string that the CLI maps to exit codes.

**Inspecting the protocol.** With dev builds, `socat - UNIX-CONNECT:…/Muninn-Dev/muninn.sock` works as before. Against a release helper, `muninn debug send` reads frames from stdin and prints the replies. It authenticates as the signed CLI, so inspection never needs a hole in authentication.

### 4.7 Search — `SearchService`

**One search engine.** `SearchService` (module `MuninnSearch`) runs inside the helper. The menu bar panel and the CLI both reach it through the same IPC `search` method. Neither client has any search logic of its own, so both always get the same results for the same query.

#### Indexes

| Index | Tokenizer | Good at |
|---|---|---|
| `search_words` | `unicode61 remove_diacritics 2` | Words and prefixes in prose. `acao` finds `ação` and `Ação`, and Portuguese and English mix freely. **No Porter stemmer**: it is English-only and would distort Portuguese. |
| `search_trigram` | `trigram` (case-insensitive) | Substrings: URL fragments (`/api/v2/inv`), identifiers (`WebhookHandl`), UUID pieces, code (`func handle(`). Also speeds up `LIKE`/`GLOB`. |

Both indexes cover text representations (plain text, plus text derived from HTML/RTF) and `extracted_text` (OCR, PDF), so a screenshot is found by the words inside it.

Things PROOF-004 must establish against the SQLite bundled with SQLCipher:
- **trigram options:** SQLite documents restrictions when combining the trigram tokenizer's diacritic removal and case handling with **index-accelerated `LIKE`/`GLOB`**. Benchmark each tokenizer configuration and don't rely on `LIKE` acceleration in a configuration where SQLite says it doesn't apply.
- the trigram index's size cost on the 100k corpus (it's typically several times the text size, see D16)

#### Query planning

1. Parse the query into terms and filters. Quoted phrases are kept as phrases. CLI flags and UI chips become structured filters.
2. **Words stage:** `search_words MATCH`, with a prefix on the last term for type-ahead.
3. **Substring stage:** `search_trigram MATCH` for terms of ≥ 3 characters. It runs when a term contains non-word characters (`/ . _ - : ( )`), when the term is camelCase or snake_case, or when the words stage returns fewer than one page.
4. Terms shorter than 3 characters use only the words prefix match.
5. Candidates from both stages are merged per content item (reciprocal-rank fusion), then filtered and ranked.

#### Structured filters

These compose with either stage, and are applied in SQL before ranking:

| Filter | Source |
|---|---|
| `since` / `until` | `capture_events.captured_at`: the item matches if *any* capture falls in the range |
| `app` | `capture_events.source_bundle_id` / `source_app_name`, any capture |
| `type` | `representations.uti`, with UTType conformance resolved to a UTI set in the helper |
| `saved` / `pinned` | `saved_items` |
| (policy) | items the caller's session doesn't cover are excluded (§4.12) |

An **empty query plus filters** is a valid search (e.g. "all PDFs from Safari this week"), ordered by recency.

#### Ranking

- Primary signal: text relevance (FTS5 `bm25()`, fused across both stages).
- Secondary signal: **recency**, an exponential decay on `last_captured_at` (starting half-life: 7 days).
- Small boosts: saved/pinned, `capture_count`, exact phrase match.
- Tie-break: `last_captured_at DESC`, then `id DESC`. Ranking is deterministic.
- All weights are named constants in `MuninnSearch`, tuned against the benchmark relevance cases, never ad hoc.

#### Pagination

Two needs, two simple mechanisms. Neither keeps state in the helper.

- **`list`: stateless keyset "as of" the first page** (built on the append-only event log).
  - The first page records `asOf`, the highest `capture_events.id` at that moment.
  - Every page orders items by **their latest capture event with `id ≤ asOf`**, then by id. A re-copy after `asOf` doesn't move an item, and new items don't appear until a new `list`. Pages never duplicate or skip; deleted items simply drop out.
  - `nextCursor` is opaque and carries `(asOf, last position)`. It holds no secret, so it isn't signed; the helper only validates it.
  - This needs an index on `capture_events(content_item_id, id)`.
- **`search`: top-N, no cursors.**
  - Returns up to `--limit` results (default 20), plus `total` and `hasMore`.
  - `--all` streams the complete ranked result inside **one SQLite read transaction**: WAL gives that transaction a consistent snapshot, so the stream is stable.
  - The panel replaces its results on every keystroke, so search doesn't need stable paging. If real use shows a need, result snapshots can be added then.
- A malformed cursor, or one used with a different query → exit 1 (`invalid_cursor`). v1's `--offset` is removed.

#### Cancellation

- Each IPC `search` carries a `requestId`. The panel sends a new search on each keystroke (with a short debounce) and marks it `supersedes: <previous requestId>`.
- The helper cancels the superseded `Task`.
- The SQLite read connection checks for cancellation via `sqlite3_progress_handler` and aborts mid-query. A cancelled search never sends results.
- Explicit `cancel { requestId }` is also supported. A dropped connection cancels its in-flight searches.

#### Semantic search: an optional later stage

The pipeline is `retrieve → filter → rank`. A future semantic stage would plug in as an extra retriever (embeddings stored per content item, built by a processing job) or as a re-ranker over the top N. It would not change indexes, IPC or clients. v2 ships without it, with no model and no vector DB.

#### Acceptance benchmark (PROOF-004 in gate A; full system in gate B)

**Corpus:** a generated **100,000+ item** corpus. The generator is in `benchmarks/` and seeded, so runs are reproducible. Mix:
- Portuguese and English prose, including mixed-language items and accents
- code: Swift, TypeScript, SQL, shell, JSON, stack traces
- URLs, UUIDs, hashes, file paths, emails
- OCR-style noisy text from screenshots
- a long tail of large items (logs)

**Relevance cases.** Each must return the expected item in the top 5:
- `acao` → `Ação`
- `webhook` → `stripeWebhookHandler`
- `/api/v2/inv` → a full invoice URL
- the middle 8 characters of a UUID
- `func handle(`
- a Portuguese word inside an English sentence
- a word that appears only in a screenshot's OCR text

**Latency targets** (Apple silicon, warm cache):

| Query type | p95 | p99 |
|---|---|---|
| Type-ahead first page | ≤ 50 ms | ≤ 150 ms |
| Substring query | ≤ 100 ms | — |
| Filtered empty query | ≤ 30 ms | — |

Cancellation must abort a deliberately slow query within 20 ms.

**Reported:** index size versus raw text size, and capture-to-searchable time. The target for capture-to-searchable is under 1 s.

### 4.8 Capture and processing pipeline

**Heavy processing is a separate pipeline, never part of capture.** OCR, PDF parsing, preview generation and rich-text parsing are slow, use a lot of memory, parse untrusted input and sometimes crash. If they ran during capture, they would add latency and could make Muninn miss copies. So capture only decides and persists; everything else is a job.

```text
Clipboard changed
       │
       ▼
Validate capture policy        paused? concealed/transient? excluded? self-copy? rate/size limits? (§4.14)
       │                       → skip, coalesce, or continue
       ▼
Persist original content       ONE DB transaction: capture_event + content_item (dedup)
       │                       + representations + asset chunks + enqueue jobs
       ▼
Index plain text               helper `index` step, right after commit
       │
       ▼
Queue heavy jobs ──► muninn-worker: text (HTML/RTF) · ocr · pdf · preview
                         └─► outputs applied by the helper, then `index` again
```

**Capture-path targets** (measured in PROOF-008): commit within tens of milliseconds for text, and roughly 100 ms for a large screenshot. Only hashing and the encrypted write run synchronously.

#### Capture guarantees (best effort, explicit)

| Guaranteed | Not guaranteed |
|---|---|
| Every clipboard state Muninn **observes** is persisted, coalesced into an existing item's counter, or counted as skipped with a reason | States overwritten between two polls. macOS keeps no history of past pasteboard contents, so they can't be recovered. |
| Observed states persist in the order they were observed | Capture while paused, locked, without clipboard access, or for excluded or concealed content |
| Gaps are **detected**: a `changeCount` jump of more than 1 is counted as `missedChanges` | Representations a source app promised but couldn't deliver in time (`omitted: "timeout"`) |

Counters shown in `status` and `doctor`:
- `missedChanges`
- `coalescedRepeats` (§4.14)
- `droppedBackpressure` (below)
- skips by reason (rate limit, size, disk)

#### Muninn's own writes

- When the helper writes the pasteboard (for `copy`, or a copy from the panel), it adds v1's **self-copy marker type** (`MuninnPaths.pasteboardMarkerType`) carrying the item id, plus `org.nspasteboard.source`.
- When the monitor sees the marker, it records **exactly one** `capture_event` with source `muninn` for that existing item. Recency then reflects use, and no content is re-read or duplicated.
- `transform --copy` runs in the CLI and writes **without** the marker. Its result is captured normally as new content, because it is new content the user made.

#### Backpressure

Reading must happen when a change is observed, because the next change overwrites the pasteboard. Persisting can lag, for example under disk contention.
- The pending set is **one capture in flight** (of any size up to the per-capture cap) plus a **small queue of text-only captures**.
- A capture that doesn't fit is **not read**: a non-text capture while one is in flight, or text over the queue's byte cap. Only its metadata is counted, as `droppedBackpressure`.
- Text captures in a full queue push out the oldest pending text capture, because the most recent state is the most valuable.
- Pending plaintext is therefore bounded by one maximum-size capture plus a small text buffer, which fits the memory budget. The capture loop itself never blocks.

#### Where work runs: three tiers

| Tier | Runs in | Steps | Why |
|---|---|---|---|
| 1. Materialization | helper | `index` (rebuild an item's FTS rows), applying worker outputs | Needs the DB and key; parses nothing untrusted |
| 2. Light text work | helper | none in v2. Reserved for cheap, well-bounded steps added when a feature needs them (e.g. URL detection) | Avoids a worker cold start per copy |
| 3. Heavy and untrusted parsing | `muninn-worker` (sandboxed, on demand) | `text` (HTML/RTF → plain), `ocr`, `pdf`, `preview` | Isolation and memory (§4.13) |

**Plain text never touches the worker.** It's indexed by the helper right after commit, so ordinary copying is searchable without a worker cold start. Indexing small plain text **inside** the capture transaction would be faster still, but it puts work on the capture path. Whether it's cheap enough is measured in PROOF-008 (D30).

#### Processors (worker tier)

Each processor is an independent, versioned unit:

```swift
protocol Processor: Sendable {
    static var id: String { get }       // "ocr"
    static var version: Int { get }     // bump to reprocess
    func accepts(_ item: ProcessorInput) -> Bool
    func process(_ item: ProcessorInput) async throws -> ProcessorOutput   // pure: no DB access
}
```

| Processor | Apple technology | Output |
|---|---|---|
| `text` (HTML/RTF → plain) | Foundation, AppKit (`NSAttributedString`) | `extracted_text` |
| `ocr` (screenshots, images) | Vision, with recognition languages from user settings (e.g. pt-BR, en-US) | `extracted_text` (`source = ocr`) |
| `pdf` | PDFKit | `extracted_text` (`source = pdf`), page count → `annotations` |
| `preview` | **In memory only:** ImageIO thumbnails for images, PDFKit first-page render for PDFs | `previews` (+ asset). Every other type gets a generic type icon, rendered by the app from the UTI. |

- Processors are **pure**: they receive bytes and metadata and return output. The helper applies all outputs to the DB.
- **Deferred until a feature needs them** (D28): annotation producers for type, language, URLs and image metadata. Capture already records UTIs, and OCR languages come from settings.

#### Idempotency

A crash at *any* point must not duplicate history or corrupt the search index.

1. **History is written only by capture,** never by jobs. Re-running any job can't create a `capture_event`.
2. **Enqueue is idempotent.** `INSERT OR IGNORE` on the unique key `(content_item_id, processor_id, processor_version)`.
3. **Each job's output commits in a single transaction:** delete this processor's previous outputs for the item, insert the new ones, mark the job `done`. A crash before commit leaves the old state intact. Re-running produces the same final state.
4. **The `index` step rebuilds its item's index rows completely,** in one transaction.
5. **On startup,** `running` jobs are reset to `pending`. Failures retry with backoff, then become `failed`. A failure in one processor never blocks the others.

#### Reprocessing

Bumping a processor's `version` (e.g. a better OCR model) re-enqueues it for every item it `accepts`, at low priority. Old outputs stay searchable until the new ones commit. No schema change is needed.

#### Resource behavior

- The worker starts on demand and exits when idle. Jobs are batched, so it starts once per burst rather than once per job.
- Heavy jobs run one at a time, and each has a timeout.
- Heavy jobs are deferred in Low Power Mode or under serious thermal pressure.

### 4.9 Testing

- **Unit:** Swift Testing per module (store, migrations, FTS queries, IPC codec, auth decisions).
- **Integration:** helper started under `swift test` on a temp socket and temp encrypted DB, with test `KeyProvider`/`PeerAuthenticator` injected; CLI tests run against it (extends the existing CLI suite).
- **CLI contract:** every command's `--json` output is validated against `docs/cli-schemas/`; every documented exit code has at least one test; stdout/stderr separation is checked per command; truncation notices appear exactly when a limit applies.
- **Policy:**
  - every scope × command pair
  - text queries refused under `metadata`
  - protected exclusion that doesn't leak into counts
  - session binding (same terminal reuses it; another terminal and no-terminal callers don't)
  - expiry and ceilings
  - lock/unlock (sessions end, data requests → `locked`)
  - every `reason` for exit 6
- **Processing idempotency:** a fault-injection harness kills the runner at each step of a job (before outputs, mid-transaction, after commit but before the next job) and restarts it. After each restart, the final DB must be identical to a clean run: same `capture_events` count, same `extracted_text`, and an FTS index that passes `integrity-check`.
- **Processors:** unit tests on fixtures (screenshots with PT/EN text, PDFs, RTF/HTML) without a DB.
- **Search:** relevance cases and latency targets from §4.7, run by `swift run -c release muninn-bench search`. Results are recorded per commit, but the benchmark is not part of `swift test`.
- **Migration:** fixture v1 plaintext DB → v2 encrypted DB, with row-for-row verification.
- **Abuse suite** (§4.14), run against a dev helper. Each case must keep the helper within its memory budget, leave the DB consistent and surface the right counter:
  - clipboard flood script and repeat flood
  - 2 GB text and a 500 MB TIFF
  - 50k×50k PNG and a 20k-page PDF
  - deeply nested HTML
  - a 100k-file Finder copy
  - a slow promise provider
  - simulated full disk
  - IPC connection and request floods while the panel stays responsive
- **UI:** XCUITest in the Xcode project for panel open, search, navigate and copy (XCUITest is XCTest-based; this is the one XCTest exception).
- **Pagination stability:** page through `list` while captures (including re-captures of listed items), deletions and reprocessing run. Assert there are no duplicates and no skips other than deleted items. `search --all` must be stable under the same load.
- **Asset atomicity:** kill the helper during capture and deletion of large assets. Assert an asset is either complete (every chunk present, hash verified) or absent, never partial.
- **Release-signed tests:** a nightly job builds a **release-signed, notarized** bundle and runs it on a real macOS account. It checks Keychain access groups and accessibility, peer code-identity checks, pasteboard access onboarding, session lock and helper registration. Mocks and dev builds can't validate signing-dependent security, so nothing in that area counts as done until it passes here.
- **CI build flags:** `--explicit-target-dependency-import-check error`.

### 4.10 Distribution

- Developer ID signing, hardened runtime, notarization and stapling, scripted.
- Output is a signed `Muninn.app` (zip or DMG) for local installation. No auto-update in v2 (D8).

### 4.11 CLI interface

```text
muninn status
muninn list [--limit N] [--cursor C] [--all]
muninn search [<query>] [--app <name|bundle-id>] [--type <kind|uti>] [--pinned]
                        [--since <date>] [--until <date>] [--limit N] [--all]
muninn history <id>
muninn get <id>
muninn copy <id>
muninn paste <id>
muninn transform <id> --format <fmt> [--copy]
muninn open [<id>]
muninn pause | resume
muninn pin <id> | unpin <id> | delete <id>
muninn session start [--scope metadata|read|manage|protected] [--for <duration>] | status | end
muninn doctor
```

#### CLI contract

These rules are part of the public interface. Breaking one is a breaking change.

1. **Stable JSON schemas.**
   - Every `--json` output has a JSON Schema committed under `docs/cli-schemas/` (one per command, plus a shared `error.json`).
   - Every object carries `schemaVersion`. Within a major version, changes are **additive only**: new optional fields may appear, and existing fields are never renamed, removed, retyped or given new meanings.
   - Field naming is fixed: `camelCase` keys, ISO-8601 UTC timestamps, ids as integers.
   - CLI tests validate every command's output against its schema.
2. **Predictable exit codes.** Codes are fixed and documented. Each command's documentation lists which codes it can return.

   | Code | Meaning |
   |---|---|
   | 0 | Success |
   | 1 | Usage error (bad flags or arguments) |
   | 2 | Not found |
   | 3 | Helper unreachable |
   | 4 | Authentication rejected (caller identity) |
   | 5 | `doctor` found problems |
   | 6 | Denied by policy (§4.12); `reason`: `no_session`, `scope`, `declined`, `timeout`, `non_interactive`, `locked`, `app_unreachable` |
   | 7 | Internal error |
   | 8 | Incompatible helper version (stale CLI or helper, see `doctor`) |

3. **stdout for results, stderr for errors.**
   - stdout carries only the successful result: human text, JSON, or the raw bytes from `paste`.
   - Errors, warnings and progress go to stderr. With `--json`, the error is a JSON object (`error.json`) **on stderr**, and stdout stays empty.
   - (v1 printed `{"ok": false, …}` on stdout. v2 doesn't keep v1 compatibility; the contract starts fresh at `schemaVersion: 1`.)
4. **No silent truncation.**
   - Results are never cut short unless an explicit limit applies. Wherever a limit applies, the output says so.
   - **Result count:** `list` and `search` default to `--limit 20`, which is documented. JSON always includes `total` (when known) and `hasMore`; `list` also returns `nextCursor`. Human output ends with `showing 20 of 340 — use --limit/--all` **on stderr**. `--all` removes the limit.
   - **Content length:**
     - `get`, `paste` and `transform` **never** truncate content.
     - `list` and `search` don't return content. They return `preview`, an explicitly named field with a documented 1 KB maximum, plus `byteSize`, so the reader always knows there's more and how much (§4.13).
     - The human table also cuts previews at `--width` (default: terminal width, or 80 when not a TTY), and every cut is marked with `…`.
5. **Hand-written argument parsing.** swift-argument-parser would be a dependency; revisit only if the hand-written parser starts costing more than it saves.
6. **Builds and tests without Xcode.** `swift build` and `swift test` build and test the CLI and every library (§4.1, §4.9).

| Command | Behavior | Needs |
|---|---|---|
| `status` | Helper state, versions, item and capture counts, paused, encrypted, pending/failed jobs, active session (with expiry), storage used vs. warning thresholds, the capture counters (§4.8), current memory, uptime. | IPC `status` (extended) |
| `list` | Content items by most recent capture, paged with an "as of" cursor (§4.7). A re-copied item moves to the top on the next `list`; it never appears twice. | IPC `list` |
| `search` | Through `SearchService` (§4.7): words, substrings and structured filters. `--app` matches bundle ID or app name, case-insensitive. `--type` accepts a kind (`text`, `rich_text`, `html`, `image`, `pdf`, `file`) or a UTI; the helper resolves it through UTType conformance. | IPC `search` v2 |
| `history` | An item's capture events: when, and from which app. | IPC `history` |
| `get` | Item, representations (uti, size, role, availability for file references), annotations and derived text. | IPC `get` (extended) |
| `copy` | Puts **all stored representations** back on the pasteboard, so the target app picks its best type (image, PDF, file URL, RTF, plain text). The helper writes the pasteboard with the self-copy marker and records exactly one capture event with source `muninn` (§4.8), so recency reflects use. It never stores a duplicate item. | IPC `copy`, representations (§4.3) |
| `paste` | Writes **one representation's raw bytes to stdout**: `muninn paste 125 > shot.png`, `muninn paste 98 \| jq`. `--as <kind\|uti>` picks the representation; the default is the primary one. The terminal counterpart of `pbpaste`, by id. | IPC `payload` (binary body) |
| `transform` | Converts an item's text with a pure function and prints the result. With `--copy`, the result is put on the pasteboard **and recorded as a new item**, because it's new content the user made. Initial formats: `json` (validate and pretty-print), `json-min`, `text` (strip formatting from RTF/HTML), `base64`, `base64-decode`, `url-encode`, `url-decode`, `trim`, `lower`, `upper`. Unknown format or invalid input → exit 1 with a reason. | `MuninnTransform`, run client-side |
| `open` | Opens the menu bar panel; with an id, opens it with that item selected. Goes through a `muninn://open[?id=N]` URL handled by the app. The URL scheme only *selects*; it never returns content. | URL scheme in the app target |
| `pause` / `resume` | As in v1. | — |
| `debug send` | Raw protocol frames, stdin to stdout (§4.6). | — |
| `doctor` | Runs checks and prints ✓/✗ with a fix hint per check; exit 5 if any fail. | IPC `diagnostics` |

`doctor` checks:

1. CLI path resolves inside a signed `Muninn.app`, and the symlink on `PATH` points at the current bundle.
2. Helper registered (`SMAppService` status), including the `.requiresApproval` case.
3. Socket exists with the expected owner and permissions.
4. Connect succeeds and authentication is accepted.
5. CLI and helper report the same version and protocol version.
6. Helper reports the DB key present in the Keychain, the DB opens, and `PRAGMA cipher_integrity_check` passes; no orphaned DB pending (§4.4).
7. Search index is healthy: FTS `integrity-check` passes on both indexes, every item with text has been indexed at the current `index` processor version, and no `index` job has been pending for more than 1 minute.
8. Processing is healthy: failed jobs are counted and listed by processor, with `last_error`.
9. Pasteboard capture is active: not paused, and the last capture time is reported.
10. Storage is below warning thresholds and the disk floor isn't reached (D18).

#### Design notes

- **Why `paste` prints to stdout instead of typing into the frontmost app.** When run from a terminal, the frontmost app *is* the terminal, and simulating ⌘V needs Accessibility permission. Printing to stdout is composable and needs no permission. Simulated paste stays a UI-only feature of the panel (D10).
- **Why `transform` runs client-side.** It's a pure function of the item's content, so the helper doesn't need it. Putting it in a library lets the menu bar panel reuse it later.
- **Why `open` doesn't use the helper.** The panel lives in the app process. A URL scheme avoids opening a second IPC channel into the UI and works even when the helper is down.
- **What `--app` relies on.** `source_app` is captured as the frontmost application at capture time. That is a best guess: it can be wrong for clipboard managers, scripts and background copies, and the docs say so.

#### IPC changes for the CLI

| Method | Change |
|---|---|
| framing | `requestId` on every request and response; optional binary bodies (§4.6). |
| `hello` | **New.** Handshake with protocol/client versions and capabilities. |
| `subscribe` | **New.** Event stream (items, approvals, sessions, jobs). |
| `search` | Add `app`, `type`, `pinned`, `since`, `until`, `all`, `requestId`, `supersedes`; the query becomes optional. |
| `list` | Replace `offset` with an "as of" `cursor`. |
| `cancel` | **New.** Cancels an in-flight request by `requestId`. |
| `history` | **New.** An item's capture events. |
| `get` | Include `uti`, `source_app`, `byte_size`, and derived text. |
| `payload` | **New.** One representation's bytes as a binary body; the header frame carries `uti` and `bodyLength`. |
| `status` | Add `version`, `protocolVersion`, `encrypted`, `lastCaptureAt`. |
| `diagnostics` | **New.** Helper-side results for `doctor` checks 6–8. |
| `session` | **New.** `start` / `status` / `end` for scoped CLI sessions; `start` triggers `approvalRequested` in the app (§4.12). |

### 4.12 Access policy

**Principle: identity is not authorization.** IPC authentication (§4.6) proves a caller *is* Muninn's CLI. It says nothing about *who or what is driving it*. Any script, cron job, agent or malware running as the user can execute the signed CLI. So **no history is readable through the CLI by default**, protected or not. Every read needs authorization the user grants deliberately, in the app, with user presence.

**What we can and can't know.** No design can reliably determine the *intent* of another process running as the same user.
- A controlling terminal (TTY) suggests a human, but a script can allocate one (`script`, `expect`), and a process started inside an authorized terminal inherits its authorization.
- Parent-process names are context, not proof.

So the model doesn't try to tell humans from automation by guessing. It **anchors every session in a user-presence prompt shown by the app** (LocalAuthentication), keeps grants **scoped and short-lived**, binds them to **something the helper observes itself**, and **audits** everything. What remains is stated in §1.1: anything running inside an authorized terminal during an active session has that session's access, just as with `sudo`'s cached credentials.

#### Scopes

| Scope | Allows | Doesn't allow |
|---|---|---|
| *(none)* | `status`, `doctor`, `pause`, `--version`, `help` | any item data. `status` shows counts only. |
| `metadata` | `list` and **filter-only** `search` (app, type, date, saved), returning ids, kinds, UTIs, source app, timestamps, sizes, `notProcessed` labels; `history` | previews, content, **text queries** (a text query is a content oracle: matches reveal what's inside) |
| `read` | everything in `metadata`, plus text search, `preview`, `get`, `paste`, `copy`, `transform` on **unprotected** items | protected items (excluded from search, redacted in lists) |
| `protected` | `read` on protected items too | — |
| `manage` | `delete`, `pin`/`unpin`, `resume` | — |

- `resume` needs `manage` because if the user paused capture for privacy, a script must not be able to turn it back on. `pause` needs nothing, since it only reduces what's captured.
- The menu bar UI isn't subject to scopes. It is the user's session (code identity `client = app`, §4.6), and exposes no automation surface that returns content: no AppleScript dictionary, no Shortcuts or App Intents returning content, and a URL scheme that only selects. Adding any such surface later makes it a new client under this policy. Protected items in the UI can additionally require Touch ID to reveal (D13).

#### Interactive sessions: terminal use

- `muninn session start [--scope read] [--for 15m]` asks for a session. A data command run without one starts the same flow automatically, unless `--no-interactive` is set.
- The helper sends `approvalRequested` to the app, launching it if needed. The app shows a LocalAuthentication prompt naming:
  - the scope and duration
  - the terminal and its process chain (e.g. *"zsh in Terminal"*, labeled as context, not proof)
  - when the CLI has no controlling terminal: *"not attached to a terminal"*, shown prominently
- The CLI never shows a prompt and never handles credentials. If the app can't be reached → exit 6, never a fallback.
- **Binding:** the session is bound to the requesting process's **controlling terminal and its audit session**, which the helper reads **from the kernel** using the peer's audit token (not from anything the CLI claims). Later CLI invocations in the **same terminal** reuse it. Other terminals, other users and processes without a controlling terminal don't.
- **Lifetime:** each scope has a default and a ceiling, in `MuninnLimits`. Longer for `metadata`, short for `read` and `manage`. `protected` is per request by default.
- Sessions live only in helper memory. They end early on `muninn session end`, when the terminal closes, and **when the Mac locks** (§4.4).
- `muninn session status` shows the active session, its scope and its time left.

#### Automation: deferred (D27)

Scripts, cron jobs and agents without a terminal get **no** access to history in v2. Non-interactive grants (scope, expiry and caller restrictions, created only in the app after user presence) are designed only when D1 decides whether agent access is part of the product. Until then, the CLI's data commands need an interactive session.

#### Protected items

An item is protected if the user marked it, or if it was copied from an app on the protected-apps list (password managers by default) (D12). Concealed or transient pasteboard items are never stored at all (D7). Protected content needs the `protected` scope, which in practice means a per-request Touch ID approval.

#### Enforcement and audit

- Everything is enforced in the helper. Clients can't opt out, and nothing a client says about itself is trusted.
- Search applies scope and protection **inside the query**. Excluded items don't affect counts, `total` or `hasMore`.
- The audit log records:
  - every session: created, used, ended
  - every CLI data request: scope, command, item ids, decision

  It never records content. It's viewable in the app and through `muninn status --audit` (which needs the `metadata` scope).
- **Denials → exit 6** with a stable `reason`: `no_session`, `scope`, `declined`, `timeout`, `non_interactive`, `locked`, `app_unreachable`.

**Dev and test builds** don't relax this policy. Tests inject a scripted approver, which approves or declines on cue, into the helper started by the test harness (§4.9).

### 4.13 Memory

Muninn runs all day, every day, so memory is a design constraint (invariant 9). The principle: **the always-running processes stay small, and heavy work runs in a process that exits when it's done.**

| Process | Lifetime | Holds | Must not hold |
|---|---|---|---|
| `muninnd` (helper) | always | pasteboard monitor, one writer + small reader pool, IPC, job scheduler, `index` step | Vision, PDFKit, Core Image, decoded images, payloads beyond the capture in flight (§4.8) and the request being served |
| `muninn-worker` | on demand, exits when idle | one job's input and the framework it needs | anything between jobs |
| `Muninn` (app) | always (hotkey, approvals) | menu bar item, hotkey, IPC subscription | panel views, thumbnails or results while the panel is closed |
| `muninn` (CLI) | per command | one response | — |

**Mechanisms:**
- **Streaming:** asset reads and writes use incremental BLOB I/O, chunk by chunk; `paste` and `copy` stream; hashing is incremental.
- **No full decode in the helper:** dimensions come from ImageIO properties; thumbnails and OCR input are downsampled in the worker.
- **Bounded SQLite:** a small page cache per connection and a process-wide heap limit; memory is released when idle and under pressure.
- **Lean responses:** `list` and `search` return a size-capped `preview` and `byteSize`, never full content.
- **Bounded caches:** every cache has a byte limit and is cleared under memory pressure. The panel's caches go when it closes.

**How we know** (PROOF-009 and PROOF-016): idle footprint with 100 vs. 100k items (scale independence), a capture-and-paste round trip of a large payload, a nightly soak (no upward trend), and `leaks` in CI. `status` and `doctor` show the helper's and app's current memory. The budget numbers are hypotheses recorded in PROOF-009, not part of this design.

### 4.14 Guardrails: big files and clipboard abuse

**Principle: know our limits and say so.** Muninn doesn't have to do everything with every copy. It has to work well for normal use and be **clear** when it doesn't do something.
- **Limits are published.** `MuninnLimits` in code is the single source of every value: defaults, hard ceilings, and what users may change in settings. The in-app *What Muninn doesn't do* page and `muninn status --limits` are generated from it. This document says *what* is limited and *what happens*, not the numbers.
- **Beyond a limit, Muninn does less, cleanly. It never does part of the job.** A giant PDF is kept, but nothing is extracted from it.
- **Every skipped step is labeled on the item** with the reason and the limit, e.g. *"Not searchable inside: PDF has 1,240 pages (limit 300)"*. In `get` JSON this is `notProcessed: [{step, reason, limit, actual}]`.
- **Limits are simple thresholds checked before work starts,** never adaptive heuristics.

The clipboard is an **untrusted input**. Any app, script or web page can put anything on it, as large and as often as it likes.

| Case | What's limited | Where | Past the limit |
|---|---|---|---|
| Huge payload | bytes per representation and per capture | capture policy, while reading | stored as **metadata only** (`omitted: "size"`), labeled |
| Fan-out (⌘C on many files) | file references per capture | capture policy | no references kept, only count and common folder (all or nothing) |
| Flood | captures per source over time | capture policy, before reading | not read; counted; sustained floods pause capture (below) |
| Repeat flood | identical captures from one source in a short window | capture policy | coalesced: no event, `coalescedRepeats` incremented |
| Slow promised data | time to read one capture | capture | remaining representations `omitted: "timeout"` |
| Crafted or huge files | per-processor eligibility (size, pixels, pages) and run-time timeouts and memory | scheduler (from metadata) and worker | not processed, labeled; output over its cap is discarded, never truncated |
| Crashing inputs | worker crashes per job | runner | quarantined after repeated crashes, labeled, retryable manually |
| Disk pressure | free space | capture | below a warning floor: binaries `omitted: "disk"`, text continues; below a hard floor: capture pauses, user notified. Muninn never fills the disk. |
| Client floods | connections, in-flight requests, frame size, partial-frame time | IPC | `busy` / disconnect. The app's connection has a reserved slot. |

#### Read as little as possible

- Read only representations we keep, compact ones first. When PNG/JPEG/HEIC exist, TIFF is never read.
- macOS doesn't expose a representation's size before it's read, so peak memory follows the payload for the one capture in flight (§4.8).
- Reads happen off the main actor (PROOF-001).

#### Floods: act on attribution confidence

`source_app` is often a guess (the frontmost app), and a background script flooding the clipboard would be blamed on whatever app happens to be in front. So the response depends on how confident attribution is:

| Attribution | Example | Response |
|---|---|---|
| **High confidence** | `org.nspasteboard.source` is set, or the change followed user interaction with that app | Per-app rate limit; a sustained flood pauses capture from that app for a while, with a notice offering *Resume* and *Always ignore* |
| **Low confidence** | frontmost-app guess only | A short, **global, metadata-only** slowdown that lifts automatically. **Never** offers *Always ignore*. The notice is worded honestly: *"something changed the clipboard 340 times while Safari was frontmost"*. |

`CapturePolicy` stays a pure function. Both modes are tested in PROOF-015.

#### Storage growth: history is permanent (D18)

- Original content is **never deleted automatically just because it's old.**
- Growth is controlled at capture time (the limits above) and by pruning **regenerable** data (previews, caches).
- Past the warning thresholds the app shows a notice with **user-driven cleanup tools**, each previewing what it will remove: delete items older than…, remove original binaries from unsaved items older than…, delete everything from app X.

#### Visibility

Every drop or cap is counted and explained in `status` and `doctor`: rate-limit drops and pauses, `coalescedRepeats`, `missedChanges`, `droppedBackpressure`, `omitted` by reason, `notProcessed` labels, quarantined jobs. Privacy skips (concealed, transient, excluded) are the exception: by invariant 4 they leave no trace.

### 4.15 Observability and log privacy

- **Logging:**
  - `os.Logger` with subsystem `com.muninn` and one category per module.
  - Clipboard content, extracted text, file paths and search queries are **never** logged in release builds. Dynamic values use `privacy: .private` by default, and only ids, counts, durations, UTIs and error categories are `.public`.
  - A test greps release log output during the integration suite for seeded canary strings.
- **Signposts** (`OSSignposter`) on the capture path, each job and each search. These are how the capture budget (§4.8) and search latency (§4.7) are measured in Instruments and in the benchmarks.
- **Crash handling:** processor crashes are caught as job failures where possible. Because of the pure processor interface, a crash report contains only stack and ids, never content.
- **No telemetry.** Nothing leaves the machine (non-goal: network).

### 4.16 Leveraging macOS

Use what the platform already does well, rather than rebuilding it, and be explicit about what we deliberately *don't* use. Status values: **use** (in the design), **adopt** (add in v2), **proof** (depends on a named PROOF in `docs/proofs.md`), **no** (deliberately not used).

#### ⚠️ Pasteboard privacy: the platform constraint that shapes capture

Since macOS 15.4, `NSPasteboard.accessBehavior` governs **programmatic** reads of the general pasteboard. From the SDK headers (Xcode 27.2):
- An app that has **never** triggered a pasteboard-access alert reports **`.default`** and is **not listed** in System Settings.
- The **first programmatic read** shows a system alert, and the state becomes `.ask`. Only then does the app appear in System Settings, where the user can choose *Ask*, *Always Allow* or *Always Deny*.
- Reads that are both user-originated and paste-related are always allowed, without an alert.

So the user **can't** just open System Settings and pick *Always Allow* beforehand: there's nothing to pick until the first alert has happened. Onboarding has to create that first alert deliberately.

**Onboarding flow (first run):**

| Step | State | What Muninn does |
|---|---|---|
| 1 | `.default` | First-run panel explains what Muninn records and why it needs clipboard access. Primary button: **Enable Clipboard Monitoring**. Nothing reads the pasteboard before this click. |
| 2 | → alert | The click causes **one deliberate programmatic read**, made by **the process that will read from then on** (D23). The system alert appears right away, in direct response to the user's action, so it isn't a surprise. |
| 3 | `.ask` (or `.alwaysAllow` / `.alwaysDeny` if the alert offers it) | The panel moves on: *"One more step: allow Muninn to read the clipboard without asking each time."* There's a button to open the right System Settings pane (deep link where available, otherwise step-by-step instructions with a screenshot), and the panel shows the current state live. |
| 4 | `.alwaysAllow` | Detected by re-checking `accessBehavior` when the app becomes active and while the panel is open. Capture starts, the raven switches to *recording*, and the panel confirms. |
| — | `.alwaysDeny` | The panel explains that Muninn can't work without access and how to change it. There's no nagging and no repeated reads. |

**Steady state:**
- The capture loop checks `accessBehavior` before every read, and reads **only in `.alwaysAllow`**.
  - `.default`: it never reads, so there's no alert outside the onboarding click.
  - `.ask` / `.alwaysDeny`: it reads nothing, and the raven shows *access not granted* with a *Fix…* action that reopens step 3.
- If the user later changes the setting, the next check picks it up. Muninn never triggers repeated alerts to "re-ask".
- Prefer checks that don't read content:
  - `changeCount` to notice changes
  - `types` and `detectMetadata(for: [.contentType])` for the type checks in the capture policy
  - `detectPatterns(for:)` where it can stand in for reading

**PROOF-001 must establish (spike, before any capture code is written):**
1. **Background helper as reader.** Can a UI-less launchd agent present the access alert at all? What name and icon does the alert show? Does the helper appear in System Settings as "Muninn", as "muninnd", or not at all? Is its permission shared with the app or separate?
2. **Which calls trigger an alert:** `types`, `detectMetadata`, `detectPatterns` and `changeCount`, on macOS 27.
3. **Whether the alert offers persistent choices itself,** or only allow-once.
4. **Deep-link** availability for the pasteboard privacy pane.

The answers decide **D23**:
- If the helper can be the reader with a clear "Muninn" identity in both the alert and System Settings, the helper reads.
- Otherwise the **app** reads and hands captures to the helper over IPC. In that case the app's onboarding click is the trigger, and the helper's capture path starts at "Persist original content" (§4.8).

**Constraints if the app becomes the reader** (designed in full only if PROOF-001 chooses it):
- a **one-way capture channel** from app to helper, with its own frame type, accepted only from `client = app`, and never mixed with UI requests
- the app **streams** representations to the helper as it reads them; it never buffers a whole payload, so the app's memory budget still holds
- the app becomes part of capture availability: if it crashes, captures are missed and counted
- capture latency now includes the IPC hop, and stays within the capture targets

#### What we use, and how

| Need | macOS feature | Status | Notes |
|---|---|---|---|
| **Security** | | | |
| Key storage | **Data-protection keychain** (`kSecUseDataProtectionKeychain`) | use | A private access group via the `keychain-access-groups` entitlement on the helper only (§4.4). Provisioning-profile requirement: PROOF-003. |
| Hardware-bound key | Secure Enclave key wrapping the DB key | **D22** | A stolen keychain plus the login password still couldn't unwrap the key off this Mac. Adds entitlement and provisioning work. |
| User presence | LocalAuthentication | use | CLI sessions, protected reads, reveal of protected items |
| Session lock state | screen lock, fast user switching, sleep notifications | use (PROOF-003) | Muninn locks with the Mac (§4.4) |
| Caller identity | audit token + `SecCode` requirement checks | use | Same machinery XPC uses internally |
| Process hardening | Hardened Runtime, library validation, notarization, Gatekeeper | use | |
| Parser isolation | **XPC service + App Sandbox** for `muninn-worker` | use | No network, no file access: bytes in, results out |
| Disk encryption | FileVault | rely on | Recommended in the UI; covers what an app can't (swap, snapshots, v1 remnants) |
| **Lifecycle & scheduling** | | | |
| Helper lifecycle | `SMAppService.agent`, launchd `KeepAlive`, `ProcessType = Adaptive`, `ThrottleInterval` | use | launchd restarts the helper and throttles crash loops for us |
| Socket ownership | launchd `Sockets` key (launchd creates the socket with correct permissions) | adopt | Removes v1's stale-socket cleanup code and permission races |
| Deferrable work | `NSBackgroundActivityScheduler` | adopt | Reprocessing, incremental vacuum and preview pruning, run when the Mac is idle and on power |
| Power and thermal | `ProcessInfo.isLowPowerModeEnabled`, `thermalState` | use | Defer heavy jobs |
| Memory pressure | `DispatchSource` memory-pressure events | use | Drop caches, release SQLite memory |
| **Content** | | | |
| Types | UniformTypeIdentifiers | use | |
| Pasteboard conventions | nspasteboard.org types: `ConcealedType`, `TransientType`, `AutoGeneratedType`, `org.nspasteboard.source` | use | Password managers mark secrets as concealed; `source` gives a better source-app attribution than the frontmost app |
| Text, OCR, PDF, images, previews, language | Foundation/AppKit, Vision, PDFKit, ImageIO + Core Image, NaturalLanguage | use | All in the sandboxed worker, all from in-memory buffers |
| File references | security-scoped/regular bookmarks (`URL.bookmarkData`) | use | Survive renames and moves |
| Cheap copies | APFS clones (`copyfile` with `COPYFILE_CLONE`) | adopt | Instant, space-free pre-migration backups |
| **Observability** | | | |
| Logs and timing | `os.Logger`, `OSSignposter`, Instruments | use | |
| On-device diagnostics | MetricKit | **not in v2** | Revisit only if a real problem in the field needs diagnosing; the soak benchmark and `leaks` in CI cover memory | Feeds `doctor` without sending anything anywhere |
| **System integration** | | | |
| Global hotkey | Carbon `RegisterEventHotKey` | use | Needs **no** Accessibility or Input Monitoring permission |
| Spotlight | `.metadata_never_index` in the data dir | use | Keeps the system from indexing our files (ciphertext anyway) |
| Backups | Time Machine | use as-is | DB and assets are ciphertext. Restoring on the same Mac works; on another Mac it doesn't (§4.4). |

#### What we deliberately don't use (v2)

| Feature | Why not |
|---|---|
| `QLPreviewPanel` / Quick Look of item content | Needs a file URL, which would mean writing decrypted content to disk (invariant 1). We render previews ourselves. |
| **QuickLookThumbnailing** (`QLThumbnailGenerator`) | Its requests take a **file URL**, not bytes. The worker is sandboxed with no file access, and decrypted content is never written to disk, so it doesn't fit. Images and PDFs are previewed in memory with ImageIO and PDFKit; every other format gets a generic icon. A file-based preview path would need its own explicitly secure design (D26), and **the no-plaintext-temp-files rule won't be weakened to get more thumbnail formats.** |
| Shortcuts / App Intents / AppleScript returning content | A new client surface that would need its own policy row (§4.12). Not in v2. |
| Services menu, Share extensions | Same reason. |
| Simulated ⌘V (Accessibility) | Extra permission (D10). |
| Core Data / SwiftData | Can't give us SQLCipher, FTS5 control or the schema guarantees we need. |
| iCloud / CloudKit sync | Non-goal (no network). |
| Universal Clipboard | Not something to use, but something to **handle**: content arriving from another device has no local source app. It's captured with `source = universal-clipboard` (where detectable) and treated as untrusted like everything else. |

### 4.17 Look and feel

Lives in **`docs/brand.md`**: the scratched raven (app icon and menu bar icon with its four status modes), the ASCII raven for the terminal, and the palette. It's a separate track (D24). The only design requirements here:
- the menu bar icon reflects helper state (recording, paused, no clipboard access, needs attention), always with a text label
- the app UI uses native controls and system semantic colors

---

## 5. Migration from v1

1. On first v2 launch, the helper detects a plaintext `muninn.db` (`schema_version` 0 or 1: a v1 DB that was never migrated has version 0).
2. It creates the key and a new encrypted DB with the v2 schema.
3. Each v1 row maps to:
   - one `content_items` row
   - one `capture_events` row (`captured_at` = v1 `created_at`, source app unknown)
   - **text rows:** one `representations` row (`public.utf8-plain-text`)
   - **non-text rows:** no representation (v1 never stored payloads); v1 `metadata` is kept as an `annotations` row (`kind = v1_metadata`)
   - **pinned rows:** a `saved_items` row
   - v1 rows with the same `content_hash` merge into one item with several events.
4. The `index` step runs for the migrated text.
5. **It verifies, per v1 row:** content hash, timestamp, pinned state, kind and metadata survive; duplicate v1 rows map to the expected item with the right capture count; and totals match (v1 rows = v2 events). Only then does it atomically swap files and delete the plaintext DB and its WAL/SHM files.
6. On failure the plaintext DB is left untouched and the error is surfaced in the UI. The helper does not run half-migrated.
7. **We say this plainly:** deleting the plaintext file does not erase it from the SSD's free blocks or from existing Time Machine and APFS snapshots. The UI says so after migration, and recommends FileVault, which is the real protection for data that existed before v2.

---

## 6. Decisions

Decisions live in **`docs/decisions.md`**: accepted, revised, pending a proof, and open, each with an ID (D1…). This document states the design that results from them. When a decision changes, both files change in the same commit.

---

## 7. Delivery: evidence gates

v2 is delivered through **four evidence gates**, not a long list of phases. Each gate ends with a **working system plus an evidence record** (`docs/proofs.md`, `docs/evidence/`), not just code and documentation. Work inside a gate is limited to what the gate's proofs have justified.

| Gate | Goal | Must be demonstrated | Proofs |
|---|---|---|---|
| ✅ 0 | Toolchain | Swift 6.4, Swift Build, import checks | — |
| **A** | **Platform feasibility** | On this Mac, with throwaway spike code (`spikes/`, never production): pasteboard access and onboarding for a signed app and helper, IPC caller identity, Keychain lifecycle across lock and restart, SQLCipher + FTS5 from the exact package | PROOF-001…004 |
| **B** | **Secure minimum engine** | A minimal working system: encrypted capture of text and representations, storage v2 with chunked assets, `SearchService`, the CLI with its contract, the access policy **enforced** with approval through the scripted test approver (unit-level evidence; the real prompt arrives with the app in gate C), the IPC transport chosen in PROOF-002, dev-build isolation, concurrency conventions. No UI and no file processing yet. | PROOF-005…009 |
| **C** | **Migration and daily usability** | v1 history migrated safely; the restructure listed in §4.1 (Xcode project, `App/`, `MuninnUI`, `SMAppService.agent`); onboarding; the **real approval prompt** (sessions approved with Touch ID in the app); panel, hotkey and icon modes (placeholder art); session lock; restart and crash recovery; release-signed nightly run | PROOF-010…012 |
| **D** | **Rich content and retrieval** | The worker (sandboxed XPC), processors (`text`, `ocr`, `pdf`, `preview`), limits and abuse suite, memory soak; final raven artwork (`docs/brand.md`) | PROOF-013…016 |

**Rules:**
- **Platform and security proofs come before reorganizing the repository.** The §4.1 restructure (exactly the list there) happens in gate C, once gates A and B have shown the architecture holds.
- **Detail follows the gate.** Sections for later gates state intent, constraints and the proof that decides them. They're expanded when their gate starts, not before.
- **A failed or inconclusive proof changes the design.** We update `docs/designs/muninn-v2.md` and `decisions.md` before building past it; we never build around it.
- **Proofs never touch real user data.** They use disposable data directories, synthetic corpora, a *copy* of a v1 database, and where needed a separate macOS user account.

Mapping from the earlier phase plan: gate B covers the old phases 1, 3, 4 and 5 (minus the app); gate C covers phase 2 and the migration; gate D covers phases 6–8.

---

## 8. Glossary

| Term | Meaning |
|---|---|
| **Capture (event)** | One observed pasteboard change that passed the capture policy. Immutable. |
| **Item (content item)** | Canonical deduplicated content; what ids in the CLI/UI refer to. |
| **Representation** | One stored form of an item (plain text, RTF, PNG, file reference, …). |
| **Asset** | Stored binary bytes, deduplicated by hash, kept as chunks inside the encrypted DB. |
| **Derived content** | Anything recomputable from an item: extracted text, previews, annotations, index rows. |
| **Processor / job** | A pure, versioned transformation, and one scheduled run of it for one item. |
| **Protected item** | An item the CLI can read only with a per-request approval (`protected` scope). |
| **Session** | A user-approved, scoped, time-limited permission for CLI reads, bound to one terminal. Lives only in helper memory. |
| **Automation grant** | *Deferred (D27).* A future non-interactive permission for scripts and agents. It would never cover `protected` or `manage`. |
| **Client** | A verified caller identity: `app` or `cli`. |

This document is changed only through reviewed commits. Decisions keep their IDs once assigned; a reversed decision is marked **Revised** with its date, not deleted.
