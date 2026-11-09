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
4. **Capture is never slowed by processing.** OCR, extraction and previews run in a separate, resumable, idempotent pipeline.
5. **Identity ≠ authorization.** Only Muninn's signed clients can connect, and protected content still needs a deliberate user grant.
6. **A real macOS app and a dependable CLI.** A signed `.app` from one Xcode project, with the helper as a user-level background service. The CLI has stable JSON schemas and exit codes.
7. **Modern Swift end to end.** Swift 6 strict concurrency, actors for state, no shared mutable singletons. Unsafe escape hatches exist only in the allow-listed C-interop layer.

### Non-goals (v2)

- Sync, accounts, or any network access.
- Mac App Store distribution (sandboxing conflicts with the CLI and helper model).
- Plugin / extension system.
- Cross-platform support.
- Semantic search, embedding models, or a vector database. The search design leaves room for an optional second stage later (§4.7).

> **Open:** product-level features beyond the platform work (snippets, collections, retention policies, agent/MCP access) are not yet scoped. See §6.

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
| Disk theft, lost Mac, copied backups, another macOS user reading files | ✅ | SQLCipher DB, AES-GCM external assets, no plaintext temp files (§4.3); key only in the Keychain, device-only (§4.4) |
| A process running as the user **reading Muninn's files directly** | ✅ | Files are ciphertext. The Keychain item's access is tied to the helper's code signature, so another process can't take the key without a prompt. |
| A process running as the user **connecting to the socket** | ✅ | Peer UID and code-identity checks; only signed Muninn app/CLI (§4.6) |
| A script, cron job or agent **driving the signed CLI** | ✅ | No history without a user-approved, scoped, short-lived session bound to a terminal, or an app-created automation grant. Every request is audited (§4.12). |
| A process running **inside a terminal that has an active session** | ⚠️ accepted | It inherits that session until it expires, ends, or the Mac locks, the same tradeoff as `sudo`'s cached credentials. No design can reliably tell the intent of a same-user process; we limit scope and duration and audit instead (§4.12). |
| Access while the Mac is **locked** | ✅ | When the session locks, Muninn locks: the DB closes, key material is wiped from memory, sessions end and grants are suspended (§4.4). The Keychain class alone wouldn't enforce this. |
| Leaks through logs, crash reports, temp files, Spotlight, Quick Look caches | ✅ | Log privacy (§4.15); in-memory temp store; data dir excluded from Spotlight (`.metadata_never_index`); previews stored as encrypted assets, never in shared caches |
| Malicious content (crafted PDFs/images) attacking parsers | ⚠️ partial | Processors are pure, time-limited and rate-limited; out-of-process isolation is D17 |
| Code injection into Muninn's own processes | ⚠️ partial | Hardened runtime, library validation, no `get-task-allow` in release, no dynamic plugin loading |
| Plaintext v1 remnants on disk | ⚠️ partial | Deleted after migration; we tell the user that SSD free blocks and existing snapshots aren't erased, and recommend FileVault (§5) |
| root / kernel compromise; malware with debugger access to an unlocked session; someone at the unlocked Mac | ❌ | Out of scope. No app-level design can defend against these; FileVault and screen lock are the user's controls. |

### 1.2 Invariants

These must hold in every phase and every build. Breaking one is a bug, whatever else the change achieves.

1. **Muninn never intentionally persists plaintext.** Clipboard content and anything derived from it is written by Muninn only encrypted: DB, assets, temp files, logs. What's outside Muninn's control is listed in §1.1.
2. **Only the helper holds the key and opens the database, and only while the user's session is unlocked.** The UI and CLI see data only through IPC.
3. **Being signed doesn't grant access.** The CLI reads no history without a user-approved, scoped, short-lived session or an app-created grant. Every request is audited, and search never reveals what a caller can't read.
4. **Capture is policy-first and never waits.** A skipped copy leaves no trace, and processing never slows capture.
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
     ProcessingRunner ◄── processing_jobs ──► Processors (pure, versioned)
       │  writes outputs + marks job done                text · ocr · pdf · image · type
       └─► StoreWriter (one transaction per job)         preview · language · index
                                                                      
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
| `ProcessingRunner` | actor; pulls jobs, runs processors in a `TaskGroup` with a concurrency limit, per-job timeouts and background QoS. |
| `IPCServer` | accept loop as a `Task`; one child task per connection, with one child task per in-flight request inside it (requests are multiplexed by `requestId`, §4.6). Cancellation on shutdown and on disconnect. Replaces detached threads. |
| Helper ↔ watcher | `await`-based calls instead of `DispatchQueue.main.sync`. |

#### Swift conventions (enforced)

1. **Swift 6 language mode with complete strict concurrency** on every target. This is already the default with tools-version 6.4 and is stated explicitly in `Package.swift` (`swiftLanguageModes: [.v6]`). Concurrency warnings are errors.
2. **Actors for stateful services:** `StoreWriter`, `ProcessingRunner`, `SearchService`'s connection pool, IPC session state and grant state. Stateless logic (`CapturePolicy`, processors, transforms, query parsing) is plain `Sendable` value types and functions.
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
| `assets` | Stored binary content, deduplicated by hash | `id`, `sha256` (unique), `byte_size`, `storage` (`inline`/`external`), `data` (BLOB, inline only), `external_key` |
| `extracted_text` | OCR and document extraction results | `id`, `content_item_id`, `representation_id`, `source` (`ocr`/`pdf`/`html`/`rtf`), `text`, `language`, `confidence`, `extractor_version` |
| `saved_items` | Pinned or explicitly saved content | `content_item_id`, `saved_at`, `label`, `is_pinned` |
| `processing_jobs` | Resumable background processing | `id`, `content_item_id`, `processor_id`, `processor_version`, `state` (`pending`/`running`/`done`/`failed`), `attempts`, `last_error`, `priority`, `updated_at`. **Unique** on `(content_item_id, processor_id, processor_version)` |
| `schema_migrations` | Versioned, recoverable migrations | `version`, `name`, `applied_at`, `checksum` |
| *`previews`* (addition) | Generated thumbnails | `content_item_id`, `asset_id`, `max_dimension` |
| *`annotations`* (addition) | Small derived facts | `content_item_id`, `kind` (`url`, `classification`, …), `value` (JSON), `producer_version` |
| `search_words`, `search_trigram` | The two FTS5 indexes (§4.7) over `representations.text` and `extracted_text.text` | written **only** by the `index` processing job, never by triggers |
| `settings` | Helper-owned configuration: protected-apps list, size caps, storage budget, processor toggles | `key`, `value` (JSON), `updated_at`. Edited by the UI via IPC; never read from files |
| `grants` | Non-interactive access grants (§4.12) | `id`, `scope`, `created_at`, `expires_at`, `revoked_at` |
| `audit_log` | Protected reads and policy decisions | `id`, `at`, `client` (signing identifier), `operation`, `content_item_id`, `decision` (`allowed`/`denied`/`approved`), `grant_id` |

#### Encryption parameters

- **Keying:** SQLCipher 4 defaults (AES-256, HMAC-SHA512 page authentication). The key is a random 256-bit **raw key** (`PRAGMA key = "x'…'"`), so PBKDF2 is skipped. Nothing user-memorable is involved, and startup stays fast.
- **What is encrypted:** the WAL and the rollback journal are encrypted by SQLCipher.
- **Temp files:** `PRAGMA temp_store = MEMORY` keeps plaintext out of temp files.
- **External assets:** chunked authenticated encryption with keys derived via HKDF from the DB key (see "Asset file format" below).
- **Memory:** clipboard content is plaintext in the helper's memory while in use. That's accepted; the threat model is data at rest and other local callers, not a compromised user session.

Embeddings are **not** in v2. When they come, they get their own table keyed by `content_item_id` plus the model version. Nothing else needs to change.

#### Deduplication — two levels

1. **Content level.** `content_hash` = SHA-256 over the sorted `(uti, sha256(representation bytes))` pairs. Copying the same thing again adds a `capture_event` and bumps `last_captured_at` / `capture_count`. No new content is stored. History keeps every copy; storage keeps one item.
2. **Asset level.** Assets are keyed by their own hash. The same image bytes appearing in two *different* content items (e.g. the same screenshot copied once alone and once with a caption) are stored once.

Assets are reference-counted by query. A periodic sweep deletes assets that no representation or preview references.

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

#### Binary storage: inline vs. external — decided by benchmark

- **Text, metadata and indexes:** always in SQLCipher.
- **Binary assets:** `assets.storage` supports both modes from day one.
  - **inline:** a BLOB in the encrypted DB.
  - **external:** an encrypted file under `Application Support/Muninn/assets/`, named by an HMAC of the content hash (a raw hash would let anyone holding the file confirm a guess of its contents). Format and crash safety are below.
- The **size threshold** between the two is chosen by a benchmark (PROOF-005). Measure across realistic sizes (10 KB–50 MB):
  - insert latency
  - `list`/`search` latency as the DB grows to 10k/100k items
  - DB file size and WAL growth
  - `VACUUM` / backup / migration time
  - delete-and-reclaim behavior
- Hypothesis to test: inline up to ~256 KB–1 MB, external above that.

#### Asset file format: bounded-memory, independently verifiable chunks

One AES-GCM operation over a whole file doesn't give bounded-memory streaming: the tag can only be checked at the end, so a streaming reader would release unverified plaintext. External assets therefore use a **chunked AEAD** in the style of the STREAM construction:

- **Header:** format version, key version, asset id, chunk size (64 KB), total plaintext length. The header is authenticated as associated data (AAD) on every chunk.
- **Each chunk** is sealed with AES-GCM using a nonce derived from (file nonce prefix, chunk index), with a **final-chunk flag** in the AAD. A chunk can't be reordered, dropped, duplicated or moved to another file, and truncation is detected.
- **Readers verify each chunk before releasing its plaintext.** Memory stays bounded by the chunk size; `paste` and `copy` stream chunk by chunk.
- Inline assets use SQLite incremental BLOB I/O; SQLCipher authenticates those pages.

#### Asset crash safety: files are outside the transaction

A SQLite transaction can't atomically commit changes to files outside the database. So "one transaction" (§4.8) covers **database rows only**, and external files follow a protocol whose rule is: **a DB reference may only point to a complete, verified, published file**. Orphan files are allowed; dangling references are not.

**Write (capture, snapshot, re-encryption):**
1. Stream-encrypt to `assets/tmp/<uuid>.partial`. Only ciphertext ever touches disk.
2. `fsync` the file, then **verify** it: re-read, check every chunk's authentication, and compare the decrypted hash with the expected content hash.
3. **Publish:** `rename()` to the final name (atomic within the volume), then `fsync` the directory. If the final file already exists (dedup), drop the temp file.
4. **Commit** the DB transaction that references it.
- A crash before step 4 leaves an unreferenced file, which reconciliation removes. A crash can never leave a reference to a missing or partial file.

**Delete (user delete, eviction of derived caches, key rotation):**
1. In the DB transaction, remove the reference and insert the file name into `asset_tombstones`.
2. **After commit,** unlink the file, `fsync` the directory, and remove the tombstone.
- A crash between leaves a tombstone, which is retried on startup. The file is never deleted before the reference is gone.

**Key rotation** (manual in settings, or after suspected compromise):
- Keys are versioned (`com.muninn.db.k<N>`), and each asset row records its key version.
- **DB:** `sqlcipher_export` into a new file under the new key, verify it, then atomically swap. The old key stays in the Keychain until the swap is complete.
- **Assets:** re-encrypted one by one as a resumable job, using the write protocol above (a new file under the new key version, commit, then delete the old file). Readers use whichever version the row says.
- The old key is removed only when no row references it. Rotation can be interrupted at any point and resumes.

**Reconciliation** runs on startup and daily (via `NSBackgroundActivityScheduler`):
- delete `tmp/*.partial` files
- delete files with no reference, older than 1 hour
- retry tombstones
- for references whose file is missing or fails verification: mark the representation `assetMissing`, visible in `get`, the UI and `doctor`. Never silently.

#### Deletion

"Immutable" means events are never *edited*. They can still be deleted.
- `delete <id>` removes the content item, its events, representations, derived rows and jobs in **one DB transaction**. External asset files that are no longer referenced are then removed by the delete protocol above.
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
- Asset-encryption keys are derived from it with HKDF and never stored.
- **Consequences, stated in the UI:**
  - Losing the key means losing the history.
  - Because the key is device-only, Time Machine restores and Migration Assistant to a new Mac bring back the encrypted DB **without** its key, so the history is unreadable there. Moving history between Macs needs an explicit export (D19).
- **If the key is missing at startup** but a DB exists (restored backup, Keychain reset):
  - the helper **does not** create a new key over it
  - it moves the unreadable DB aside to `muninn.db.orphaned-<date>`, reports the situation to the UI and `doctor`, and starts with an empty history only after the user confirms

  Unreadable data is never silently discarded.

#### Session lock: Muninn locks when the Mac locks

`AfterFirstUnlock` is needed so the helper can run in the background after login. But it means the Keychain keeps returning the key **after the first unlock until the next restart, even while the screen is locked**. The Keychain class alone therefore can't make Muninn inaccessible on a locked Mac, so the helper enforces that itself.

- **Signals:**
  - screen lock and unlock
  - fast user switching (`NSWorkspace` session resign/become active)
  - sleep and wake

  Which documented APIs give lock state reliably to a background agent is part of PROOF-003.
- **On lock** (and on switching away from the user's session):
  1. Stop serving data. Every data request returns `locked` (CLI exit 6, `reason: locked`); `status` still answers.
  2. End all interactive sessions and suspend automation grants (§4.12).
  3. Pause capture. Clipboard changes on a locked Mac don't come from the user.
  4. Stop the worker and pause the job queue.
  5. **Close every DB connection and wipe key material:**
     - the raw key and the HKDF-derived keys are held in a zeroizing buffer and cleared with `memset_s`
     - SQLCipher runs with `PRAGMA cipher_memory_security = ON`, so its own buffers are wiped when freed
     - caches, previews and in-flight payloads are dropped
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

#### Protocol v2

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
  - `grantChanged`, `pausedChanged`, `jobsProgress`.
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
| (policy) | protected items are excluded for clients without a grant (§4.12) |

An **empty query plus filters** is a valid search (e.g. "all PDFs from Safari this week"), ordered by recency.

#### Ranking

- Primary signal: text relevance (FTS5 `bm25()`, fused across both stages).
- Secondary signal: **recency**, an exponential decay on `last_captured_at` (starting half-life: 7 days).
- Small boosts: saved/pinned, `capture_count`, exact phrase match.
- Tie-break: `last_captured_at DESC`, then `id DESC`. Ranking is deterministic.
- All weights are named constants in `MuninnSearch`, tuned against the benchmark relevance cases, never ad hoc.

#### Pagination: cursors, not offsets

A capture-id bound alone isn't enough. Ranking uses mutable values (`last_captured_at`, `capture_count`), so an old item copied again could move between pages even when its new event falls outside the bound. Pagination therefore **materializes the result order**:

- **First page:** the helper runs the query once, ranks it, and stores the ordered list of item ids as a **result snapshot**.
  - Up to 10,000 ids (~80 KB), kept in memory.
  - At most 4 snapshots per connection and 32 in total, with LRU eviction and a 5-minute idle TTL.
- **Later pages** read positions from the snapshot and only *load* rows. Order can't change, so pages never duplicate or skip.
  - Items deleted since the snapshot are skipped and counted in `skippedDeleted`.
  - Items newly hidden by policy (lock, session end) are filtered at load time.
  - Reprocessing changes text and previews, not positions.
- `nextCursor` (opaque, base64) carries the snapshot id and position, and is **signed** by the helper (HMAC), so it can't be forged or used on another connection's snapshot.
- **Expired or evicted snapshot** → exit 1 with `cursor_expired`, and the client restarts the search. That is explicit, never a silent re-query.
- **Over 10,000 results:** the snapshot holds the first 10,000 and the response says `snapshotCapped: true`. `--all` instead **streams** the full result inside **one SQLite read transaction**: WAL gives that transaction a consistent snapshot, so the stream is stable without materializing.
- `list` uses the same mechanism, ordered by `(last_captured_at, id)` at snapshot time.
- A cursor used with a different query → exit 1 (`invalid_cursor`). v1's `--offset` is removed.

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

### 4.8 Processing pipeline

**Processing is a separate pipeline, never part of capture.** OCR, PDF parsing, preview generation and image conversion are slow, use a lot of memory, and sometimes crash. If they ran during capture, they would add latency and could make Muninn miss copies. So capture only decides and persists; everything else is a job.

```text
Clipboard changed
       │
       ▼
Validate capture policy        CapturePolicy: paused? concealed/transient? protected app? size limits?
       │                       → skip (nothing stored) or continue
       ▼
Persist original content       external assets: encrypt → verify → publish (§4.3), then
       │                       ONE DB transaction: capture_event + content_item (dedup)
       │                       + representations + inline assets + asset refs + enqueue jobs
       ▼
Queue processing jobs          INSERT OR IGNORE into processing_jobs (unique per item/processor/version)
       │
       ├── Extract text        text · ocr · pdf
       ├── Generate previews   preview
       ├── Identify content    type · image-metadata · language · urls
       └── Update search index index (runs after extraction jobs; high priority)
```

**Capture-path budget:** the polling tick through commit must finish in **≤ 20 ms p95** for text and **≤ 100 ms p95** for a large screenshot. Only hashing and the encrypted write run synchronously. Anything slower is a job.

#### Capture guarantees (best effort, explicit)

| Guaranteed | Not guaranteed |
|---|---|
| Every clipboard state Muninn **observes** is either persisted or counted as skipped, with a reason | States overwritten between two polls (0.5 s). macOS keeps no history of past pasteboard contents, so they can't be recovered. |
| Observed states persist in the order they were observed | Capture while paused, locked, without clipboard access, or for excluded or concealed content |
| Gaps are **detected**: a `changeCount` jump of more than 1 means intermediate states were missed, and is counted as `missedChanges` (shown in `status` and `doctor`) | Representations a source app promised but couldn't deliver in time (`omitted: "timeout"`) |

**Backpressure.** Reading must happen when a change is observed, since the next change overwrites the pasteboard. Persisting can lag behind, for example under disk contention. Observed captures go into a **bounded queue**: 16 captures or 200 MB, whichever is reached first.
- When the queue is full, the **oldest pending** capture is dropped. The most recent clipboard state is the most valuable, and it's what the user just copied.
- Dropped captures are counted as `droppedBackpressure`, with no content kept.
- The capture loop itself never blocks.

#### Processors

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
| `ocr` (screenshots, images) | Vision (`RecognizeTextRequest`), with recognition languages from `language` / user settings (pt-BR, en-US) | `extracted_text` (`source = ocr`) |
| `pdf` | PDFKit | `extracted_text` (`source = pdf`), page count → `annotations` |
| `image` (metadata, conversion) | ImageIO, Core Image | dimensions/EXIF → `annotations`; normalized representations when needed |
| `type` | UniformTypeIdentifiers | canonical UTI, kind → `annotations` |
| `preview` | **In memory only:** ImageIO (`CGImageSourceCreateThumbnailAtIndex` from a data source) for images; PDFKit (`PDFDocument(data:)`, first page rendered) for PDFs | `previews` (+ `assets`). Every other type gets a **generic type icon**, rendered by the app from the UTI. Nothing touches disk. |
| `language` | NaturalLanguage (`NLLanguageRecognizer`) | dominant language(s) → `annotations` |
| `urls` | Foundation (`NSDataDetector`) | detected URLs → `annotations` |
| `index` | — (SQLite FTS5) | `search_words`, `search_trigram` rows |

- Processors are **pure**: they receive bytes and metadata and return output. The **runner** owns all database writes. This makes processors unit-testable without a DB, and swappable.
- Dependencies between jobs are declared by processor (for example, `index` depends on `text`, `ocr` and `pdf` for that item). The runner schedules `index` once its dependencies are done or not applicable.

#### Idempotency

A crash at *any* point must not duplicate history or corrupt the search index.

1. **History is written only by capture,** never by jobs. Re-running any job cannot create a `capture_event`.
2. **Enqueue is idempotent.** `INSERT OR IGNORE` on the unique key `(content_item_id, processor_id, processor_version)`.
3. **Each job commits in a single transaction:**
   - delete this processor's previous outputs for the item
   - insert the new outputs
   - mark the job `done`

   A crash before commit leaves the old state intact. Re-running produces the same final state.

   Jobs that produce external assets (large previews) publish them with the asset write protocol (§4.3) **before** this transaction, so the transaction only ever references complete files.
4. **The `index` job rebuilds its item's index rows completely.** It deletes all FTS rows for the item, then inserts them from current text, in one transaction. There is no partial or incremental update to get wrong.
5. **On startup,** `running` jobs are reset to `pending`. Jobs retry with backoff and become `failed` after N attempts, with `last_error` recorded. A failure in one processor never blocks the others.

#### Reprocessing

- Bumping a processor's `version` (e.g. a better OCR model) makes the runner enqueue that processor for every item it `accepts`, at low priority.
- Old outputs stay in place and searchable until the new ones commit (step 3 replaces them atomically). No schema change is needed.

#### Resource behavior

- Jobs run in the on-demand `muninn-worker` process, never in the helper (§4.13). Heavy jobs run one at a time and light ones up to 2 at a time, at background QoS.
- Each job has a timeout and is treated as failed when the timeout expires.
- Heavy processors (`ocr`, `pdf`, `preview`) are deferred in Low Power Mode or under serious thermal state.
- Parsing untrusted PDFs and images is an attack surface. Moving processors into an XPC service, so a crash or exploit stays out of the helper, is D17.

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
  - automation grants can't reach `protected` or `manage`
  - lock/unlock (sessions end, grants suspend, data requests → `locked`, key buffers zeroed)
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
- **Pagination stability:** page through results while captures (including re-captures of listed items), deletions and reprocessing run concurrently. Assert there are no duplicates, no skips except counted deletions, and `cursor_expired` exactly when the TTL or eviction applies.
- **Asset crash safety:** fault injection at every step of the write, delete and rotation protocols, then restart. Assert no dangling references, orphans cleaned up, tombstones completed, and `assetMissing` only for deliberately corrupted files.
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
                        [--since <date>] [--until <date>] [--limit N] [--cursor C]
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
   - **Result count:** `list` and `search` default to `--limit 20`, which is documented. JSON always includes `total` (when known), `hasMore` and `nextCursor`. Human output ends with `showing 20 of 340 — use --limit/--all` **on stderr**. `--all` removes the limit.
   - **Content length:**
     - `get`, `paste` and `transform` **never** truncate content.
     - `list` and `search` don't return content. They return `preview`, an explicitly named field with a documented 1 KB maximum, plus `byteSize`, so the reader always knows there's more and how much (§4.13).
     - The human table also cuts previews at `--width` (default: terminal width, or 80 when not a TTY), and every cut is marked with `…`.
5. **Hand-written argument parsing.** swift-argument-parser would be a dependency; revisit only if the hand-written parser starts costing more than it saves.
6. **Builds and tests without Xcode.** `swift build` and `swift test` build and test the CLI and every library (§4.1, §4.9).

| Command | Behavior | Needs |
|---|---|---|
| `status` | Helper state, versions, item and capture counts, paused, encrypted, pending/failed jobs, active session or grant (with expiry), storage used vs. warning thresholds, `missedChanges`, uptime. | IPC `status` (extended) |
| `list` | Content items by most recent capture, with cursor pagination. A re-copied item moves to the top rather than appearing twice. | cursors (§4.7) |
| `search` | Through `SearchService` (§4.7): words, substrings and structured filters. `--app` matches bundle ID or app name, case-insensitive. `--type` accepts a kind (`text`, `rich_text`, `html`, `image`, `pdf`, `file`) or a UTI; the helper resolves it through UTType conformance. | IPC `search` v2 |
| `history` | An item's capture events: when, and from which app. | IPC `history` |
| `get` | Item, representations (uti, size, role, availability for file references), annotations and derived text. | IPC `get` (extended) |
| `copy` | Puts **all stored representations** back on the pasteboard, so the target app picks its best type (image, PDF, file URL, RTF, plain text). The helper writes the pasteboard and records a capture event with source `muninn`, so recency reflects use. It never stores a duplicate item. | IPC `copy`, representations (§4.3) |
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
10. Storage is below warning thresholds, the disk floor isn't reached, and asset reconciliation found nothing missing (D18).

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
| `subscribe` | **New.** Event stream (items, approvals, grants, jobs). |
| `search` | Add `app`, `type`, `pinned`, `since`, `until`, `cursor`, `requestId`, `supersedes`; the query becomes optional. |
| `list` | Replace `offset` with `cursor`. |
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

So the model doesn't try to tell humans from automation by guessing. It **anchors every grant in a user-presence prompt shown by the app** (LocalAuthentication), keeps grants **scoped and short-lived**, binds them to **something the helper observes itself**, and **audits** everything. What remains is stated in §1.1: anything running inside an authorized terminal during an active session has that session's access, just as with `sudo`'s cached credentials.

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
- **Lifetime** (defaults / ceilings):

  | Scope | Default | Ceiling |
  |---|---|---|
  | `metadata` | 1 h | 8 h |
  | `read` | 15 min | 4 h |
  | `manage` | 15 min | 1 h |
  | `protected` | per request | 15 min |

  Sessions end early on `muninn session end`, when the terminal closes, and **when the Mac locks** (§4.4).
- `muninn session status` shows the active session, its scope and its time left.

#### Automation grants: non-interactive use

- For scripts, cron jobs and agents with no terminal. Created **only in the app's settings, after LocalAuthentication**. No CLI flag, environment variable, config file or IPC call can create or extend one.
- Each grant has:
  - a **scope** (`metadata` or `read`; `protected` and `manage` are not available to automation)
  - an **expiry** (default 1 h, ceiling 24 h)
  - an optional **caller restriction**: the code-signing identity or path of the parent executable, best effort and labeled as such
- Grants are **suspended while the Mac is locked**.
- The menu bar raven shows the *needs attention* mode while an automation grant is active, so the user can see it at a glance.

#### Protected items

An item is protected if the user marked it, or if it was copied from an app on the protected-apps list (password managers by default) (D12). Concealed or transient pasteboard items are never stored at all (D7). Protected content needs the `protected` scope, which in practice means a per-request Touch ID approval. It is never available to automation grants.

#### Enforcement and audit

- Everything is enforced in the helper. Clients can't opt out, and nothing a client says about itself is trusted.
- Search applies scope and protection **inside the query**. Excluded items don't affect counts, `total` or `hasMore`.
- The audit log records:
  - every session and grant: created, used, ended
  - every CLI data request: scope, command, item ids, decision

  It never records content. It's viewable in the app and through `muninn status --audit` (which needs the `metadata` scope).
- **Denials → exit 6** with a stable `reason`: `no_session`, `scope`, `declined`, `timeout`, `non_interactive`, `locked`, `app_unreachable`.

**Dev and test builds** don't relax this policy. Tests inject a scripted approver, which approves or declines on cue, into the helper started by the test harness (§4.9).

### 4.13 Memory

Muninn runs all day, every day, so memory is a design constraint, not a later optimization. The principle: **the always-running processes stay small, and heavy work runs in processes that exit when they're done.**

#### Process layout

| Process | Lifetime | Holds | Must not hold |
|---|---|---|---|
| `muninnd` (helper) | always | pasteboard monitor, one writer + small reader pool, IPC, job scheduler | Vision, PDFKit, Core Image, decoded images, asset bytes beyond the request in flight |
| `muninn-worker` (processors) | **on demand**; exits after 30 s idle | one job's input + the framework it needs | anything between jobs |
| `Muninn` (app) | always (hotkey, approvals) | menu bar item, hotkey, IPC subscription | panel views, thumbnails or results while the panel is closed |
| `muninn` (CLI) | per command | one response | — |

Moving processors out of the helper (D17, revised) is the largest single saving. Vision's text-recognition models and PDFKit stacks take far more memory than everything else in Muninn put together. In a separate process, that memory goes back to the OS as soon as the queue drains, instead of staying in the helper forever. It's also the security isolation §1.1 wanted for parsing untrusted files.

- **Worker transport:** in the app bundle, the worker is an **XPC service**. It's sandboxed with no network and no file access: it receives bytes and returns output. Under `swift test` and in dev builds, a `WorkerTransport` protocol runs the same processors in-process, so tests don't need the bundle (A1).
- **Batching:** the helper batches jobs so the worker starts once per burst, not once per job. It runs heavy jobs one at a time, and the worker processes each job inside an `autoreleasepool`.

#### Never hold whole payloads

- **Streaming everywhere above a small threshold (64 KB):**
  - hashing (incremental SHA-256)
  - asset writes and reads (SQLite incremental BLOB I/O for inline assets, chunked AES-GCM for external ones)
  - IPC `payload` bodies, which are written straight from storage to the socket
  - `muninn paste` writes chunks to stdout
- **Capture reads each representation once, and its bytes are released when the capture transaction commits.** Oversized representations (over the cap) are discarded right after reading. Lazily provided (promised) pasteboard data is checked for size where the type allows it.
- **Images are never fully decoded in the helper.** Dimensions come from ImageIO properties, which don't decode pixels. Thumbnails are made in the worker with `CGImageSourceCreateThumbnailAtIndex` at display size. OCR gets a downsampled image sized for recognition, not the original.

#### Bounded SQLite

- Page cache per connection: `PRAGMA cache_size = -2048` (2 MB) for the writer, 1 MB per reader, and a pool of at most 2 readers.
- `sqlite3_soft_heap_limit64` for the whole process. On idle and on memory pressure, the helper calls `sqlite3_db_release_memory`.
- FTS queries return ids and scores only. Rows are loaded for **one page** of results.

#### Lean IPC responses

- `list` and `search` return each item's **`preview`**: an explicitly named field with a documented maximum (1 KB of text), plus `byteSize`. They never return full content.
- Full content comes only from `get` and `paste`, one item at a time and streamed.
- Panel thumbnails are fetched per visible row at display size.

#### Caches

- No unbounded caches. Every cache has a size limit in bytes (an LRU with byte cost), and all of them are cleared when the system signals memory pressure (`DispatchSource` memory-pressure source, wrapped in the C-interop layer).
- The panel's thumbnail cache is cleared when the panel closes.

#### App and panel

- Panel views and their view models are created when the panel opens and **torn down on close**. While closed, the app is a status item, a hotkey registration and one IPC connection.
- Lists are lazy (`List`/`LazyVStack`), and only visible rows request previews.

#### Budgets (measured hypotheses)

These numbers are **hypotheses to be measured in PROOF-009**, not architectural invariants. Invariant 9 fixes the *shape*: a small idle footprint that doesn't grow and returns to idle after work. The numbers are adjusted once measured, through a reviewed change to this table.

Measured as `phys_footprint` (what Activity Monitor shows as Memory):

| Process / state | Target |
|---|---|
| helper, idle, 100k items | ≤ 25 MB |
| helper, during a 20 MB image capture | idle + ≤ 1.5× payload, back to idle after commit |
| app, panel closed | ≤ 40 MB |
| app, panel open with thumbnails | ≤ 120 MB |
| worker, OCR peak | ≤ 400 MB; **0 when idle** (process gone) |

#### Making sure it stays that way

- **`status` and `doctor`** report the helper's and app's current `phys_footprint`. `doctor` flags any value over budget.
- **Memory benchmarks** in `benchmarks/`:
  - 10k captures, then 1k searches. Helper footprint growth must stay ≤ 5 MB after a forced idle.
  - A 50 MB payload capture-and-paste round trip, with peak ≤ budget.
  - **Scale independence:** compare idle helper footprint with 100 items and with 100k items. The difference must be ≤ 2 MB.
  - **Soak:** a simulated 30 days of activity (captures, searches, processing bursts, panel open/close cycles), compressed into one run. The idle footprint is sampled after every burst and must not trend upward. The slope is reported and the run fails if it's positive beyond noise. The soak runs nightly, not on every commit.
- **Health in production:** the helper samples its own `phys_footprint` every few minutes and keeps the last 24 h in memory as a fixed-size ring buffer. `status` shows the current value and peak; `doctor` flags anything over budget or trending upward. The samples are never sent anywhere.
- **Leak checks:** the integration suite runs `leaks` against the helper at the end, and any leak fails CI.
- **Profiling:** signposts plus Instruments (Allocations, VM Tracker) templates are checked into `benchmarks/`, so a regression can be investigated the same way every time.
- **launchd:** the helper's plist uses `ProcessType = Adaptive`, so macOS treats it as background work except while it's answering a client.

### 4.14 Guardrails: big files and clipboard abuse

**Principle: know our limits and say so.** Muninn doesn't have to do everything with every copy. It has to work well for normal use and be **clear** when it doesn't do something. So:

- **Limits are published.** One table in code (`MuninnLimits`) is the source for this document, the in-app *What Muninn doesn't do* page, and `muninn status --limits`.
- **Beyond a limit, Muninn does less, cleanly. It never does part of the job.** A giant PDF is kept (as a reference or asset), but nothing is extracted from it. There's no "first 500 pages", because partial results look complete and mislead search.
- **Every skipped step is labeled on the item**, with the reason and the limit, e.g. *"Not searchable inside: PDF has 1,240 pages (limit 300)"*. In `get` JSON this appears as `notProcessed: [{step, reason, limit, actual}]`.
- **Limits are boring on purpose.** They're simple thresholds checked *before* work starts, never adaptive heuristics that are hard to explain.

The clipboard is an **untrusted input**. Any app, script or web page the user interacts with can put anything on it, as large and as often as it likes. A clipboard manager that stores everything faithfully is a natural target. These are the cases to design for:

| Case | Example | Risk |
|---|---|---|
| Huge payload | 2 GB text, 500 MB TIFF screenshot of a giant canvas | memory spike, disk fill, index bloat |
| Flood | a script setting the clipboard in a loop | history pollution, disk fill, CPU, **pushing real history out via the storage budget** |
| Repeat flood | the same value copied every 10 ms | unbounded `capture_events` despite dedup |
| Fan-out | ⌘C on 100k files in Finder | huge representation rows, slow capture |
| Crafted content | decompression bombs (50k×50k PNG), 20k-page PDF, deeply nested HTML/RTF | worker memory blowup, hangs, parser exploits |
| Lazy (promised) data | the source app generates data only when asked, and it's slow or huge | capture stalls, and reading forces the work |
| Client flood | a script hammering IPC with searches or connections | helper CPU/memory, starving the panel |
| Disk pressure | the volume is nearly full | SQLite errors, the user's Mac running out of space |

#### Capture: decide cheaply, read as little as possible

The capture policy (§4.8) now runs these checks **before reading content**, in this order:

1. **Paused / concealed / transient / excluded app** → skip, leaving no trace (invariant 4).
2. **Rate limit per source app** (token bucket):
   - Polling already limits observed changes to 2/s. On top of that, each source app has a burst of 20 captures, refilling at 1 per 5 s. The defaults are tuned from real usage in gate B.
   - **Over the limit:** content isn't read. The drop is counted per source in `status`.
   - **Sustained flood** (default: over 100 dropped in 1 minute): capture from that app pauses for 10 minutes, and the app shows a notice ("Muninn paused recording from *App*: it changed the clipboard 340 times in a minute") with *Resume* and *Always ignore* actions.
3. **Repeat coalescing:** if the new content's hash matches the previous capture from the same source within 5 s, no event is written; only the counter increments. This also stops a repeat flood from growing `capture_events` without bound.
4. **Choose what to read:** read only representations we keep (§4.3), in **most-compact-first** order. When PNG/JPEG/HEIC exist, TIFF is never read, because uncompressed TIFF is where giant payloads usually come from. Promised data is read only for types we keep, and with a deadline (below).
5. **Size caps while reading** (configurable within hard ceilings):

   | Limit | Default | Hard ceiling |
   |---|---|---|
   | text representation | 10 MB | 100 MB |
   | binary representation (image/PDF) | 50 MB | 500 MB |
   | total per capture | 100 MB | 1 GB |
   | file references per capture | 1,000 | 10,000 |

   - **Over the cap:** the representation is stored as a **metadata-only** row (`uti`, `byteSize`, `omitted: "size"`). The item still exists and says what was omitted. `get` and the UI show it, and nothing pretends to be complete.
   - **Over 1,000 files:** no references are stored. The item records only the count and the common parent folder (*"12,400 files from ~/Photos — too many to keep references (limit 1,000)"*). It's all or nothing, consistent with the principle above.
6. **macOS doesn't expose a representation's size before it's read.** For in-memory data (not files), the bytes must be read to know the size. Mitigations:
   - the compact-first order above
   - reading off the main actor, so the panel and hotkey stay responsive (PROOF-001: NSPasteboard reads from a non-main context)
   - releasing oversized data immediately

   This is the one place where peak memory follows the payload, and it's covered by the "idle + 1.5× payload, back to idle after commit" budget (§4.13).
7. **Deadline:** if reading one capture takes longer than 2 s (usually a slow promise provider), the remaining representations are skipped and marked `omitted: "timeout"`.

#### Storage: protect the user's history from being pushed out

- **Original content is never deleted automatically just because it's old** (D18). History means history: a screenshot from months ago still has its original bytes.
- Growth is controlled where it's cheap and honest:
  - **at capture time**, with the size caps, rate limits and flood pause above, so a flood never gets in and never pushes anything out
  - **by pruning regenerable data:** previews and other derived caches can be dropped under pressure and regenerated on demand
- **Warnings, not silent deletion:** when Muninn's storage passes thresholds (default 5 GB, then 20 GB) or the disk-floor warning level is reached, the app shows a notice with **user-driven cleanup tools**. Each shows what will be removed before doing it:
  - *delete items older than…*
  - *remove original images and files from unsaved items older than…, keeping text and previews*
  - *delete everything from app X*
- **Disk floor:**
  - Below `max(5 GB, 5%)` of free space, binary assets stop being stored (they're recorded as `omitted: "disk"`), while text keeps working.
  - Below 1 GB, capture pauses entirely and the user is notified.
  - Muninn never fills the disk.
- **`SQLITE_FULL` / I/O errors** fail the capture transaction cleanly: nothing partial, no corruption. The error is counted and surfaced, and the helper keeps running.

#### Processing: eligibility first, all or nothing

Each processor declares **eligibility limits**. The scheduler checks them from metadata *before* enqueuing, so ineligible work never reaches the worker. Ineligible items get a `notProcessed` label instead of a job.

| Processor | Processed only if | Otherwise |
|---|---|---|
| `ocr` | image ≤ 50 MB and ≤ 40 MP (pixel count from ImageIO properties, no decode) | stored and copyable; *not searchable inside* |
| `preview` | image ≤ 100 MP or PDF ≤ 50 MB, **and** a type ImageIO or PDFKit can render from memory | generic type icon |
| `pdf` | PDF ≤ 50 MB **and** ≤ 300 pages | stored or referenced; *not searchable inside* |
| `text` (HTML/RTF → plain) | input ≤ 2 MB | plain-text representation (if the app offered one) is still searchable |
| `index` | text ≤ 10 MB per representation | item is findable by metadata (app, type, date), not by content |

The worker is sandboxed (§4.13) and still enforces limits at run time, because metadata can lie:
- **Timeouts:** OCR 20 s, PDF 30 s, text 5 s.
- **Memory:** the worker aborts any job over 1 GB.
- **Output size:** output over 5 MB of text is **discarded entirely**, not truncated.

Any run-time abort becomes a `notProcessed` label with the reason (`timeout`, `memory`, `output_too_large`). It's never a partial result.

**Poison jobs:** a job that crashes the worker twice is **quarantined**. It's never retried automatically, it's labeled on the item, and it's listed by `doctor` with a manual *Retry*. One bad file can't keep crashing the worker.

#### IPC: authenticated clients can still misbehave

| Limit | Default |
|---|---|
| concurrent connections | 32 |
| in-flight requests per connection | 8 (more → `busy` error) |
| request line size | 1 MB |
| partial-frame read timeout | 10 s: a frame that starts must finish, which guards against slow clients |
| idle timeout | 30 s, **only for connections with no subscription and no request in flight** |
| subscribed connections | no idle timeout. The helper sends `ping` every 30 s, and a client that doesn't `pong` within 10 s is disconnected. |

- The app's connection has a reserved slot and priority, so a script hammering the CLI can't make the panel sluggish.
- `transform` runs in the CLI on content fetched from the helper. Streamable formats (`base64`, `url-encode/decode`, `lower/upper`) stream. The rest refuse items over 50 MB with exit 1 and a reason, never a partial result.
- `copy` of large representations uses a pasteboard **data provider**: bytes are produced only if the target app actually asks, so the helper doesn't load a 500 MB asset just to offer it.

#### Visibility

Every resource-based drop or cap is countable and explained:
- rate-limit drops per source
- flood pauses
- `omitted` representations by reason (`size`, `timeout`, `disk`)
- `missedChanges` and `droppedBackpressure` (§4.8)
- `assetMissing` (from reconciliation)
- quarantined jobs
- evictions

`status` shows the counts and `doctor` explains them. Privacy skips (concealed/transient/excluded) are the exception: by invariant 4 they leave no trace at all.

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

#### What we use, and how

| Need | macOS feature | Status | Notes |
|---|---|---|---|
| **Security** | | | |
| Key storage | **Data-protection keychain** (`kSecUseDataProtectionKeychain`) | use | A private access group via the `keychain-access-groups` entitlement on the helper only (§4.4). Provisioning-profile requirement: PROOF-003. |
| Hardware-bound key | Secure Enclave key wrapping the DB key | **D22** | A stolen keychain plus the login password still couldn't unwrap the key off this Mac. Adds entitlement and provisioning work. |
| User presence | LocalAuthentication | use | CLI sessions, automation grants, protected reads, reveal of protected items |
| Session lock state | screen lock, fast user switching, sleep notifications | use (PROOF-003) | Muninn locks with the Mac (§4.4) |
| Caller identity | audit token + `SecCode` requirement checks | use | Same machinery XPC uses internally |
| Process hardening | Hardened Runtime, library validation, notarization, Gatekeeper | use | |
| Parser isolation | **XPC service + App Sandbox** for `muninn-worker` | use | No network, no file access: bytes in, results out |
| Disk encryption | FileVault | rely on | Recommended in the UI; covers what an app can't (swap, snapshots, v1 remnants) |
| **Lifecycle & scheduling** | | | |
| Helper lifecycle | `SMAppService.agent`, launchd `KeepAlive`, `ProcessType = Adaptive`, `ThrottleInterval` | use | launchd restarts the helper and throttles crash loops for us |
| Socket ownership | launchd `Sockets` key (launchd creates the socket with correct permissions) | adopt | Removes v1's stale-socket cleanup code and permission races |
| Deferrable work | `NSBackgroundActivityScheduler` | adopt | Reprocessing, asset sweeps, eviction, `VACUUM`, run when the Mac is idle and on power |
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
| On-device diagnostics | MetricKit (hangs, memory, CPU, crashes, delivered locally) | adopt if PROOF-016 shows it delivers on macOS | Feeds `doctor` without sending anything anywhere |
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

Muninn has **two ravens**, one per medium:

| Raven | Medium | Source |
|---|---|---|
| **Scratched raven** | the **app icon** and the **menu bar icon**, plus artwork derived from them (first run, *About*, empty state) | original scratchboard illustration, `design/brand/` |
| **ASCII raven** | the **terminal** only | `muninn.md` (kept as is); a compact variant for `muninn --version` / `muninn help` on a TTY, worked on separately |

#### The scratched raven

- **Style:** scratchboard. Light strokes are scratched out of a dark ground, so the raven appears as if cut into ink. The strokes are rough and hand-made but intentional, never noisy.
- **Recognizable before it's detailed.** The silhouette alone (head, beak, folded wing) must read as a raven. Scratches add character on top and never carry the shape.
- **Original artwork,** drawn for Muninn and not traced from existing raven logos or illustrations.

#### App icon

- **The full illustration:** the raven scratched into an ink-black ground, with bone-white strokes and at most one `ember` accent (the eye).
- **Built as layers** (ink ground, raven body, scratch strokes, eye) in Icon Composer's `.icon` format. macOS then renders the **default, dark, tinted and clear** appearances from one source, instead of us hand-making each variant. *(confirm the format and appearances with the Xcode 27.2 toolchain in gate C)*
- **Tested at every size it ships:** 1024 down to 16 px. Below ~64 px, fine scratches are dropped from the export and only the major strokes remain. That's a separate hand-tuned small-size layer, not a downscale.

#### Menu bar icon

The hardest constraint: about **18×18 pt** (36×36 px @2x), monochrome, rendered by the system as a **template image** so it follows light/dark menu bars and highlight states automatically.

- **The same raven, reduced.** A solid raven silhouette with **2–3 scratch cuts** as negative space (one across the wing, one at the neck, the eye as a cut). The cuts are what make it *the scratched raven* and not a generic bird, so they're drawn on the pixel grid at @1x and @2x and never scaled down from the app icon.
- **States through pose, not color** (template images are single-color). This makes the icon a status light for the helper:

  | State | Menu bar raven |
  |---|---|
  | Recording | standing, eye cut open |
  | Paused | head tucked, no eye |
  | Clipboard access not granted (§4.16) | turned away |
  | Needs attention: flood pause, limits hit, approval waiting | wings slightly raised |

  Four states, deliberately. More poses wouldn't be distinguishable at 18 pt. Every state has an accessibility label and a matching line in the menu, so the icon never carries meaning alone.
- **Acceptance:** recognizable on a crowded menu bar, in light and dark, on a 1× external display and a 2× Retina display, and in the highlighted (clicked) state.

#### Palette (initial)

| Token | Use | Dark | Light |
|---|---|---|---|
| `ink` | icon ground; illustration lines in light mode | warm near-black | warm near-black |
| `bone` | scratches; illustration ground in light mode | warm off-white | warm off-white |
| `ember` | the only accent: the eye in the app icon, attention states, protected badge | muted amber | deeper amber |

The app UI otherwise uses native controls, SF Pro and SF Mono, and system semantic colors, so it respects Increase Contrast and the user's accent color. The character lives in the two icons, not in custom widgets. The raven never appears in the panel's result rows.

#### Assets

- `design/brand/`: vector sources for the app icon layers, the menu bar icon (all 4 states, @1x and @2x pixel-fit), and the derived first-run, *About* and empty-state artwork.
- `App/`: the `.icon` app icon and the menu bar template images.
- `docs/` or CLI resources: the terminal ASCII raven variants.

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
4. Processing jobs are enqueued for the migrated text (URL detection).
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
| **B** | **Secure minimum engine** | A minimal working system: encrypted capture of text and representations, storage v2, `SearchService`, CLI with the contract, sessions and access policy, protocol v2, dev-build isolation, concurrency conventions. No polished UI and no file processing yet. | PROOF-005…009 |
| **C** | **Migration and daily usability** | v1 history migrated safely; the Xcode app, packaging and onboarding; panel, hotkey and icon modes (placeholder art); session lock; restart and crash recovery; release-signed nightly run | PROOF-010…012 |
| **D** | **Rich content and retrieval** | The worker (sandboxed XPC), processors (OCR, PDF, previews in memory), limits and abuse suite, memory soak; final raven artwork | PROOF-013…017 |

**Rules:**
- **Platform and security proofs come before reorganizing the repository.** The §4.1 restructure happens in gate C, once gates A and B have shown the architecture holds.
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
| **Asset** | Stored binary bytes, deduplicated by hash; inline or external. |
| **Derived content** | Anything recomputable from an item: extracted text, previews, annotations, index rows. |
| **Processor / job** | A pure, versioned transformation, and one scheduled run of it for one item. |
| **Protected item** | An item that clients other than the app can read only with approval or a grant. |
| **Grant** | A time-boxed, user-created permission for non-interactive protected reads. |
| **Client** | A verified caller identity: `app` or `cli`. |

This document is changed only through reviewed commits. Decisions keep their IDs once assigned; a reversed decision is marked **Revised** with its date, not deleted.
