# Muninn v2 — Design

Status: **Draft** · Started 2026-11-08

This is **what we are building and why**. It works with these documents:

| Document | Holds |
|---|---|
| `docs/designs/muninn-v2.md` (this) | architecture, invariants, interfaces |
| `docs/proofs.md` | claims, experiments, expected and **observed** results |
| `docs/decisions.md` | decisions (D1…), with the alternatives considered and why they were rejected |
| `docs/reviews/` | fresh-context design reviews (EGM "Goldfish" reviewers) and how each finding was resolved |
| `docs/brand.md` | the ravens: app and menu bar icons, terminal art |

**Proof-oriented development.** We prove architectural assumptions before committing to them. Statements marked with a proof ID, like *(PROOF-004)*, are **hypotheses until that proof passes**. Delivery runs through evidence gates (§7), and each gate produces a working system plus an evidence record.

**v2 is a rewrite, not an increment.** v1's interfaces and data layout are not compatibility constraints; the only thing carried over is the user's history (§5). Why we rewrite rather than evolve v1 is D32.

**Security is a baseline requirement.** A clipboard history holds passwords, tokens, private messages and documents. Every choice below is made under the threat model in §1.5, and an encrypted database is not optional.

---

## 1. Problem, goals and non-goals

### 1.1 Problem

v1 works, but it fails the job in ways that can't be patched individually (rows refer to §2):
1. **History is plaintext on disk** (Storage): anything that can read the user's files can read every password and token ever copied.
2. **Any local process can read all history** (IPC): the socket has no peer authentication, and the CLI needs no approval.
3. **Screenshots, rich text and files are labels, not content** (Non-text): their bytes are never stored, so they can't be restored or searched.
4. **Search doesn't scale or rank** (Search): an unranked `LIKE` scan, with no substrings in OCR'd or rich content.
5. **The app isn't a real macOS app** (Targets, Background, Distribution): no bundle, no signing, and the helper is a child process.

Fixing 1, 3 and 4 together changes the storage model at its root, which is why v2 rewrites rather than evolves (D32).

### 1.2 Goals

1. **Private by default at rest.** History, assets and indexes are encrypted on disk. The key is stored only in the Keychain, and clipboard content never appears in logs.
2. **Faithful, best-effort capture.** For every clipboard change Muninn observes, keep the compatible representations (text, rich text, images, file references) and when and where it was copied, without storing duplicates. Polling can miss changes overwritten between checks; Muninn counts those gaps (§4.8).
3. **One fast search engine** for panel and CLI: words, substrings, filters and recency-aware ranking, holding up at 100k+ items with mixed PT/EN text and code.
4. **Capture is never slowed by heavy processing.** OCR, extraction and previews run in a separate, resumable, idempotent pipeline.
5. **Identity ≠ authorization.** Only Muninn's signed clients can connect, and reading history from the CLI needs a user-approved session.
6. **A real macOS app and a dependable CLI.** A signed `.app` from one Xcode project, the helper as a user-level background service, and a CLI with stable JSON schemas and exit codes.
7. **Modern Swift end to end.** Swift 6 strict concurrency, actors for state, no shared mutable singletons.

**Success** is the gates' evidence (§7) plus daily use: Muninn runs on the maintainer's Mac for a month with no lost history, no unexplained memory growth, and search answering type-ahead within its targets.

### 1.3 Non-goals (v2)

- Sync, accounts, or any network access.
- Mac App Store distribution (sandboxing conflicts with the CLI and helper model).
- Plugin or extension systems; cross-platform support.
- Semantic search, embedding models, or a vector database (§4.7 leaves room for a later stage).
- Product features beyond the platform work, including `muninn transform`, snippets, collections and agent access. These wait for D1.

### 1.4 Product changes from v1

- **Reading history from the CLI needs approval.** The first data command in a terminal asks for Touch ID or the user's password in the app, and the session expires. The app itself still needs no setup.
- **Scripts, cron jobs and agents have no access to history** in v2 (§4.12, D27).
- **Clipboard access must be granted once** through macOS's pasteboard privacy setting (§4.16).
- **Minimum macOS is 27**, the version the proofs run on (D5).

### 1.5 Security model

**What we protect:** clipboard content and everything derived from it (representations, assets, extracted text, previews, indexes), plus metadata that reveals behavior (which app, when).

**What we promise and what we don't.** Muninn **never intentionally persists plaintext**: not in its database, assets, temp files, logs or the backups it makes. It can't promise that plaintext never reaches disk *anywhere*, because these are outside its control:
- **macOS swap and memory compression** (swap is encrypted by macOS)
- **system diagnostics:** crash reports, sysdiagnose, spindumps (content is kept out of what we log, §4.15)
- **terminal output:** `muninn get` and `paste` print content by design; scrollback, shell history and pipes are the user's
- **the system pasteboard itself:** other apps, clipboard sync and Universal Clipboard see what's copied regardless of Muninn

FileVault is the control for those. Any app can also choose not to be recorded, by marking its pasteboard content concealed or transient (D7).

| Threat | In scope? | Mitigation |
|---|---|---|
| Disk theft, lost Mac, copied backups, another macOS user reading files | ✅ | Everything, binary assets included, lives in the SQLCipher DB; no plaintext temp files (§4.3); key only in the Keychain, device-only (§4.4) |
| A process running as the user **reading Muninn's files** | ✅ | Files are ciphertext; the key sits in a private access group granted only to the helper (§4.4, PROOF-003) |
| A process running as the user **connecting to the helper** | ✅ | Code-identity check before any request; only the signed Muninn app and CLI (§4.6) |
| A script, cron job or agent **driving the signed CLI** | ✅ | No history without a user-approved, scoped, short-lived session bound to one terminal; callers without a terminal are refused; every request audited (§4.12) |
| A process running **inside a terminal that has an active session** | ⚠️ accepted | It inherits the session until it expires, the terminal's session leader exits, or the Mac locks. This is the same trade-off as `sudo`'s cached credentials; we can't reliably tell the intent of a same-user process, so scope and duration are limited and everything is audited (§4.12). |
| A **compromised Muninn app** | ⚠️ accepted | Session approval trusts the signed app: compromising the app grants sessions. Whether the helper verifies the user-presence result itself is D33. |
| Access while the Mac is **locked** | ✅ | The helper serves no data while locked and ends all sessions (§4.4) |
| Leaks through logs, crash reports, temp files, Spotlight, Quick Look caches | ✅ | Log privacy (§4.15); in-memory temp store; data dir excluded from Spotlight; previews kept inside the encrypted DB |
| Malicious content (crafted PDFs, images, HTML) attacking parsers | ⚠️ partial | Parsers run only in the sandboxed, on-demand worker (§4.8; D17, pending PROOF-013), with eligibility limits and timeouts |
| Code injection into Muninn's processes | ⚠️ partial | Hardened runtime, library validation, no `get-task-allow` in release, no dynamic plugin loading |
| Plaintext v1 remnants on disk | ⚠️ partial | Deleted after migration; the UI says SSD free blocks and existing snapshots aren't erased and recommends FileVault (§5) |
| root or kernel compromise; malware with debugger access to an unlocked session; someone at the unlocked Mac | ❌ | Out of scope; FileVault and screen lock are the user's controls |

### 1.6 Invariants

These bind **release builds**, and each is enforced from the gate that delivers it (§7). Nothing before gate C runs on real user data. Breaking an invariant is a bug, whatever else the change achieves.

1. **Muninn never intentionally persists plaintext.** Clipboard content and anything derived from it is written by Muninn only encrypted: DB, temp files, logs. What's outside Muninn's control is listed in §1.5.
2. **Only the helper holds the key and opens the database, and it serves data only while the user's session is unlocked.** The UI and CLI see data only through IPC.
3. **Being signed doesn't grant access.** The CLI reads no history without a user-approved, scoped, short-lived session. Every request is audited, and search never reveals what a caller can't read.
4. **Capture is policy-first and never waits on heavy work.** A copy skipped for privacy leaves no trace.
5. **History is append-only, and deletion is real.** Capture events are never edited. A deleted item is unreachable when the delete commits, physically purged from the DB within a bounded time (§4.3), and the audit log keeps no reference to it.
6. **Processing is idempotent and only writes derived data.** Re-running any job, including after a crash, changes nothing else.
7. **There is one search engine.** For the same caller permissions, the same query on the same data returns the same results in the panel and the CLI.
8. **Unreadable data is never silently destroyed.**
9. **Idle memory is bounded.** The always-running processes have a small idle footprint that doesn't grow with history size or uptime, and every burst of work returns to it. Heavy work runs only in a process that exits afterwards (§4.13).
10. **Every input is bounded, and limits are explicit.** No burst of copies, crafted file or client can exhaust memory, disk or CPU, or push the user's history out. A single representation must be read before its size is known, so that read is the one peak; every bound applies from there on (§4.14). Past a published limit, Muninn skips the step entirely rather than doing part of it, and says what it skipped.

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
| Storage | System SQLite, WAL, single table `clipboard_entries(id, content, content_hash, created_at, is_pinned, kind, metadata)`, `schema_version` table. **Unencrypted.** |
| Non-text | Kind + metadata only (dimensions, file names). Image bytes and file contents are **not stored**; `content` holds a placeholder. |
| Search | `content LIKE '%q%'`: unranked, no index use. |
| Background | Menu bar app launches `muninnd run` as a child `Process` and restarts it on exit. `SMAppService.mainApp` only for the app's own launch at login. |
| IPC | `AF_UNIX` socket at `~/Library/Application Support/Muninn/muninn.sock`. No peer authentication; no explicit socket permissions. |
| Testing | Swift Testing: store, IPC, and CLI (spawns real processes). 100 tests (42 store, 10 IPC, 48 CLI). No UI tests. The CLI tests point the CLI at a mock server through `MUNINN_SOCKET_PATH`, read only in `DEBUG` builds; that seam goes with the v1 socket in gate B. |
| Distribution | README describes `Muninn.app`, but the repo has no bundling, signing or notarization pipeline. |

**Reused from v1, not rewritten:**
- the `packages/` and `apps/` module layout
- `Paths` (extended with dev and release data dirs)
- the self-copy pasteboard marker (`MuninnPaths.pasteboardMarkerType`) and `ClipboardWriter`, both moved to `MuninnCapture`
- the Carbon hotkey (`HotKeyManager`, with its global handler replaced, §4.2)
- the CLI process test harness (`CLITests.swift`)
- the first-run panel structure

---

## 3. Target stack

| Area | v2 choice | Change from v1 |
|---|---|---|
| Concurrency | Swift actors, async/await, structured concurrency | Rework |
| Interface | SwiftUI + selective AppKit | Keep |
| Package management | Swift Package Manager | Keep |
| Build tooling | Swift 6.4, Swift Build, strict target-import checking | Done in gate 0 |
| App packaging | Native Xcode app target | New |
| Storage | SQLCipher; events / content / representations / derived model | New |
| Key management | Data-protection Keychain | New |
| Background execution | `SMAppService.agent` | Rework |
| Process communication | Authenticated local IPC: XPC by default (D21) | Rework |
| Search | Shared `SearchService` over FTS5 (index shape: D35, PROOF-004) | New |
| File processing | Sandboxed on-demand worker: Foundation/AppKit, Vision, PDFKit, ImageIO | New |
| Testing | Swift Testing + integration / UI tests | Extend |
| Distribution | Signed, notarized `.app`, local installation | New |

---

## 4. Architecture

```text
                         Muninn.app (signed, Developer ID)
 ┌──────────────────────────────────────────────────────────────────────┐
 │ Contents/MacOS/Muninn                 menu bar UI (SwiftUI + AppKit)  │
 │ helper (muninnd), via SMAppService    location pending PROOF-003      │
 │ Contents/XPCServices/muninn-worker.xpc  sandboxed parser worker       │
 │ Contents/MacOS/muninn                 CLI                             │
 └──────────────────────────────────────────────────────────────────────┘

 muninnd
   capture path (fast, never blocks on heavy work)
     PasteboardSource ─► CapturePolicy ─► StoreWriter: event + item + representations
       (@MainActor)      (allow/skip)        + asset chunks + enqueue jobs (one transaction)
                                                         │
   processing (separate, resumable)                      ▼
     ProcessingRunner (helper) ◄── processing_jobs
       ├─ helper: index step (rebuild an item's FTS rows), apply outputs
       └─ worker jobs ──► muninn-worker (sandboxed, on demand): text · ocr · pdf · preview

   query path
     IPC server ─ caller identity ─ AccessPolicy ─► SearchService / StoreReader (read-only connections)
                                 SQLCipher DB (WAL) · key ◄── Keychain
```

### 4.1 Repository structure and packaging

**One repository, one Xcode application project, shared Swift packages.**

```text
muninn/
├── Muninn.xcodeproj/          the only Xcode project: app target + UI-test target (gate C)
├── App/                       app-target-only files: @main shell, Info.plist, entitlements, assets, launchd plist
├── Package.swift              shared package: every library, muninnd, worker, CLI, tests
├── packages/
│   ├── MuninnCore/            models, IDs, paths, IPC message types (no I/O)
│   ├── MuninnStore/           SQLCipher, schema, migrations, StoreWriter/StoreReader
│   ├── MuninnSearch/          SearchService
│   ├── MuninnProcessing/      job runner + Processor protocol
│   ├── MuninnProcessors/      Apple-framework processors (Vision, PDFKit, …)
│   ├── MuninnCapture/         PasteboardSource, CapturePolicy, pasteboard writes (v1 ClipboardWriter)
│   ├── MuninnSecurity/        KeyProvider, PeerAuthenticator, AccessPolicy
│   ├── MuninnIPC/             transport client/server
│   └── MuninnUI/              SwiftUI panel, settings, approval prompt
├── apps/
│   ├── muninnd/               helper: composition root only
│   ├── muninn-worker/         on-demand processor worker
│   └── muninn-cli/            CLI
├── benchmarks/                muninn-bench: search, asset storage, memory; corpus generator
├── spikes/                    throwaway proof code (never production)
└── docs/                      design, decisions, proofs, evidence/, reviews/, cli-schemas/, brand
```

**Dependency rules,** enforced by `--explicit-target-dependency-import-check error`:
- `MuninnCore` depends on nothing of ours.
- `MuninnProcessors` depends only on `MuninnCore` and Apple frameworks; processors never see the database.
- `MuninnUI` and `muninn-cli` depend only on `MuninnCore` and `MuninnIPC`. **Clients never link the store or search.**
- `muninnd` is the only target that links `MuninnStore`, `MuninnSearch`, `MuninnProcessing` and `MuninnSecurity`. It does **not** link `MuninnProcessors`; only `muninn-worker` and tests do, so Vision, PDFKit and Core Image never load into the always-running helper.

**The Xcode project** contains only the app target and its UI tests. It embeds the helper, the worker (as an XPC service) and the CLI. All logic, the UI included, lives in the package.

**What moves when.**
- **Gate B** adds library modules inside the existing layout (`MuninnSearch`, `MuninnSecurity`, `MuninnProcessing`). That isn't a restructure.
- **Gate C** is the restructure: add `Muninn.xcodeproj` and `App/`; extract the menu bar UI into `packages/MuninnUI`; rename `MuninnClipboard` to `MuninnCapture`; replace `HelperManager`'s `Process()` with `SMAppService.agent`; update `.gitignore`.
- **Gate D** adds `apps/muninn-worker` and `MuninnProcessors`.

**Build and test rules:**
- `swift build` and `swift test` build and test everything except the app bundle without opening Xcode. CI runs both.
- Signing- and platform-dependent behavior sits behind protocols that tests replace: `KeyProvider` (Keychain vs. in-memory key), `PeerAuthenticator` (code signature vs. UID-only), `PasteboardSource` (system pasteboard vs. scripted source), and the session approver (app prompt vs. scripted approver). Release builds never accept the test variants; only test code injects them, never flags or environment variables.
- **Dev builds are isolated, not weakened.** A `DEBUG` `muninnd` uses its own data directory (`~/Library/Application Support/Muninn-Dev/`) and Keychain service, and authenticates peers by UID only (unsigned binaries have no stable code identity). This is decided at compile time; release binaries have no dev path. The access policy applies unchanged in every build.

### 4.2 Concurrency model

| Component | Isolation |
|---|---|
| `PasteboardSource` (system) | `@MainActor` (NSPasteboard). Emits observed changes via `AsyncStream`. |
| `CapturePolicy` | Pure, synchronous decision: store, skip or coalesce. No I/O. |
| `StoreWriter` | actor owning the **single write connection**. |
| `StoreReader` / `SearchService` | small pool of **read-only connections** (WAL allows concurrent readers), so a slow search never blocks capture |
| `ProcessingRunner` | actor in the helper: schedules jobs, runs helper steps, sends worker jobs to `muninn-worker`. Never runs parsers in the helper. |
| IPC server | one task per connection and per in-flight request; cancelled on disconnect and shutdown |

#### Swift conventions (enforced)

1. **Swift 6 language mode with complete strict concurrency** on every target (`swiftLanguageModes: [.v6]`). Concurrency warnings are errors.
2. **Actors for stateful services:** `StoreWriter`, `ProcessingRunner`, `SearchService`'s connection pool, IPC and session state. Stateless logic (`CapturePolicy`, processors, query parsing) is plain `Sendable` values and functions.
3. **AppKit and SwiftUI state lives on the main actor.** `MuninnUI` and the system `PasteboardSource` use `defaultIsolation(MainActor.self)`; view models are `@MainActor @Observable`.
4. **No shared mutable singletons.** No `static var shared` and no mutable globals. Dependencies are created once in a composition root (`muninnd/main.swift`, the app's `@main`) and passed through initializers. v1's `nonisolated(unsafe)` hotkey handler becomes a main-actor-owned registration.
5. **Escape hatches are allow-listed.** `@unchecked Sendable`, `nonisolated(unsafe)` and `@preconcurrency` appear only in the C-interop layers (SQLCipher wrapper, socket or XPC handles, Carbon bridge), each with a `// SAFETY:` comment. A CI grep fails the build on any other use.
6. **No GCD or locks** outside those wrappers.
7. **Structured concurrency first.** Unstructured `Task {}` only at boundaries, always stored so it can be cancelled; no `Task.detached`.
8. **Cancellation is honored** at loop boundaries in search, processors and IPC reads.

### 4.3 Storage — data model

v1 models a copy as *one string plus a kind*. v2 separates three concepts:

| Concept | Question it answers | Mutability |
|---|---|---|
| **Capture event** | *When* was something copied, from *which app*, with *which pasteboard types* available? | Immutable (deletable) |
| **Content item** | *What* was copied: the canonical item and its **representations** (plain text, HTML, RTF, image, file reference) | Representations are append-only |
| **Derived content** | What do we *know* about it: OCR text, PDF text, previews, index rows | Recomputable |

#### Schema

```text
capture_events ──► content_items ──► representations ──► assets ──► asset_chunks
                         │
                         ├──► extracted_text ─┐
                         ├──► previews ──► assets
                         ├──► annotations     ├─► search index (FTS5, written by the index step)
                         └──► processing_jobs │
            representations.text ─────────────┘
 schema_migrations · settings · audit_log  (standalone)
```

| Table | Purpose | Key columns |
|---|---|---|
| `capture_events` | Immutable history of copy events | `id`, `content_item_id`, `captured_at`, `source_bundle_id`, `source_app_name`, `source_confidence`, `change_count`, `available_types` (JSON) |
| `content_items` | Canonical content, reused across events | `id`, `content_hash` (unique, nullable, see Identity), `primary_kind`, `first_captured_at`, `last_captured_at`, `capture_count`, `is_pinned`, `is_protected`, `indexed_version` |
| `representations` | One row per stored representation | `id`, `content_item_id`, `uti`, `role` (`primary`/`alternate`), `text` (text-like types), `asset_id` (binary), file-reference fields (`url`, `bookmark`, `file_size`, `file_mtime`), `byte_size`, `omitted` (reason, if not stored) |
| `assets` | Stored binary content, deduplicated by hash | `id`, `sha256` (unique), `byte_size`, `chunk_size`, `storage` (`inline`; `external` reserved, D15) |
| `asset_chunks` | The asset's bytes, in chunks inside the encrypted DB | `asset_id`, `idx`, `data` |
| `extracted_text` | OCR and document extraction results | `content_item_id`, `representation_id`, `source` (`ocr`/`pdf`/`html`/`rtf`), `text`, `language`, `confidence`, `extractor_version` |
| `previews` | Generated thumbnails | `content_item_id`, `asset_id`, `max_dimension` |
| `annotations` | Small derived facts | `content_item_id`, `kind`, `value` (JSON), `producer_version`. In v2, written only by migration (`v1_metadata`) and `pdf` (page count) (D28). |
| `processing_jobs` | Resumable worker jobs | `content_item_id`, `processor_id`, `processor_version`, `state`, `attempts`, `last_error`, `priority`. Unique on `(content_item_id, processor_id, processor_version)` |
| search index | FTS5 over `representations.text` and `extracted_text.text` | shape decided by PROOF-004 (D35) |
| `settings` | Helper-owned configuration, edited via IPC | protected apps, overrides of `MuninnLimits` within ceilings, storage warning thresholds |
| `audit_log` | Sessions and every CLI data request | `at`, `client`, `session_id`, `operation`, `content_item_id` (nulled when the item is deleted), `decision`. Retention bound in `MuninnLimits`. |
| `schema_migrations` | Versioned migrations | `version`, `name`, `applied_at`, `checksum` |

#### Identity and deduplication

- **Text items:** identity is the hash of the normalized plain-text representation. Copying the same text from a browser (plain + HTML) and from a terminal (plain only) is **one item**; a later capture may add representations the item doesn't have yet.
- **Non-text items:** identity is the hash of the primary representation's bytes.
- **Items whose primary representation was omitted or absent** (size, timeout, disk, or v1 non-text rows) are **never deduplicated**: `content_hash` is null and each such capture is its own item.
- Copying the same thing again adds a `capture_event` and bumps `last_captured_at` and `capture_count`. History keeps every copy; storage keeps one item.
- **Assets** are deduplicated by their own hash across items, and deleted with their chunks in the same transaction that removes their last reference.

#### Which representations are kept

- **Keep** public, interoperable types: plain text, RTF, HTML, PNG/JPEG/HEIC/TIFF, PDF, file URLs.
- **Don't read TIFF when a compact raster type is offered.** `copy` restores the stored types.
- **Skip** private or dynamic types (`dyn.*`, app-internal types) unless allowlisted.
- `available_types` on the capture event records everything offered, so we know what we chose not to keep.

#### Files copied from Finder

- **Reference, don't duplicate.** Store the URL and the resource values the pasteboard provides at capture time. The file's contents are not copied.
- **The helper never touches referenced files in the background.** Creating a bookmark, checking availability or taking a snapshot happens only on an explicit user action, performed by the app, so any privacy (TCC) prompt is attributed to an action the user just took (PROOF-001).
- **A snapshot** (an encrypted copy of the contents) is an explicit capability: per item, or a setting with a size cap. It becomes an asset like any other binary.
- If a reference is stale, the item keeps its metadata and shows "file unavailable"; `copy` fails with exit 2.
- Extracting text from referenced files without a snapshot is D14.

#### Encryption parameters

- **Keying:** SQLCipher 4 defaults (AES-256, HMAC-SHA512 page authentication) with a random 256-bit raw key, so no PBKDF2 runs.
- **WAL and journal** are encrypted by SQLCipher; `PRAGMA temp_store = MEMORY` keeps plaintext out of temp files.
- **Binary assets** live in the same DB, so they get the same encryption and authentication. There's no separate crypto format.
- **Memory:** content is plaintext in the helper while in use; the threat model is data at rest and other local callers (§1.5).

#### Binary storage: chunked, inside SQLCipher

Every binary asset is split into `asset_chunks` rows and written and read with incremental BLOB I/O, so memory stays bounded by the chunk size. Asset writes and deletes commit or roll back with the capture or delete transaction: there are no files outside the transaction to reconcile. `paste` and `copy` stream chunk by chunk.

PROOF-005 decides whether this holds up, against a sizing target (light, typical and heavy users at 1 and 3 years). It measures DB size, `VACUUM` and backup cost, Time Machine behavior on one large file, WAL bursts, latency, and chunk size. `assets.storage` reserves `external`, so a separate store could be added without a schema change, but it's designed only if PROOF-005 shows inline is unacceptable (D15). Excluding the DB from Time Machine is D34. Key rotation is not in v2 (D29).

#### Deletion

- `delete <id>` removes the item, its events, representations, derived rows, jobs and any asset left unreferenced, in **one transaction**. Audit rows for the item keep the request but null its id.
- **Physical purge:** `PRAGMA secure_delete` is on, a `TRUNCATE` checkpoint follows user deletes, and the search index is merged in idle time. Within those bounds, deleted content leaves the DB file.
- **DB copies:** the pre-migration copy (below) is removed after the next successful start; an orphaned DB (§4.4) is the user's to keep or delete, and the UI says it may contain deleted items.

#### Migrations

- An ordered list of migrations in code. Each runs in a transaction and is recorded in `schema_migrations` with a checksum; a mismatch on startup is an error.
- Before a destructive migration, the helper copies the DB to `muninn.db.pre-<version>` (an APFS copy-on-write clone of ciphertext) and removes it after the next successful start.

### 4.4 Key management

- On first run, the helper generates a random 256-bit key and stores it in the **data-protection keychain** (`kSecUseDataProtectionKeychain`): service `com.muninn.db`, not synchronizable, accessibility class per PROOF-003 (below).
- **Only the helper reads the key** (D3). Data-protection keychain access is governed by access groups from signing entitlements, so the key sits in one private group, `<TeamID>.com.muninn.helper`, granted through `keychain-access-groups` on the helper alone. No access group is shared with the app, CLI or worker.
- Whether that entitlement needs a provisioning profile, and therefore whether the helper ships as a bundle (`Contents/Library/LoginItems/`) instead of a bare executable, is PROOF-003.
- **Consequences, stated in the UI:** losing the key means losing the history. The key is device-only, so a restore or migration to another Mac brings back the DB without its key (D19).
- **If the key is missing at startup but a DB exists:** the helper never creates a new key over it. It moves the DB aside to `muninn.db.orphaned-<date>`, reports this to the UI and `doctor`, and starts empty only after the user confirms.

#### When the Mac locks

The helper must be readable in the background after login. With `AfterFirstUnlock`, the Keychain keeps returning the key while the screen is locked, so the Keychain alone doesn't enforce "no data while locked". The helper does:

- **On lock** (and when switching away from the user's session):
  1. Stop serving data. Data requests return `locked` (CLI exit 6); `status` answers from in-memory counters.
  2. End all sessions (§4.12).
  3. Pause capture.
  4. Stop the worker and pause the job queue.
- **On unlock:** resume capture and jobs. Sessions must be approved again.
- **PROOF-003 tests `WhenUnlockedThisDeviceOnly`.** If macOS really makes the key unreadable while locked, the OS enforces the rule and the steps above become defense in depth. The helper would then gain a "wait for unlock" state, and must tell `errSecInteractionNotAllowed` (locked) apart from a missing key, so a restart while locked never triggers the orphan path.
- Closing connections and wiping key buffers on lock is not part of v2 (it helps only against an out-of-scope threat); a stricter mode with user presence on reopen is D25.

### 4.5 Background execution

- The helper is registered with `SMAppService.agent(plistName:)` from the app bundle. launchd owns its lifecycle: start at login, `KeepAlive`, crash restart.
- `HelperManager`'s `Process()` spawn/restart logic is removed.
- The first-run panel handles the "Allow in Login Items" approval state (`.requiresApproval`).

### 4.6 IPC

**Transport: XPC by default** (D21). The helper exposes a launchd `MachServices` endpoint and checks callers with `xpc_connection_set_peer_code_signing_requirement`. A Unix socket is used only if PROOF-002 shows a concrete need that XPC can't meet.

**Requirements on the transport**, whichever is chosen:
- **Caller identity before any request:** only the signed Muninn app and CLI; the verified identity (`client = app | cli`) is attached to the connection and used by the access policy. Dev builds check UID only, against dev data (§4.1).
- **Version handshake:** an incompatible CLI or helper is reported with exit 8.
- **Concurrent requests with cancellation,** for type-ahead search (`supersedes`, `cancel`).
- **Streamed binary payloads** for `paste` and `copy`, never buffered whole.
- **Event subscriptions** (items, approvals, sessions, pause state, job progress), with liveness checks for subscribed connections.
- **Limits** on connections, in-flight requests, message size and slow readers (§4.14).
- **Errors** carry a stable `code` that the CLI maps to exit codes.

**`muninn debug send`** reads JSON messages on stdin and prints replies, whatever the transport, authenticating as the signed CLI.

The message-level spec is written in gate B, once D21 is decided.

### 4.7 Search — `SearchService`

**One search engine.** `SearchService` runs inside the helper. The panel and the CLI reach it through the same IPC `search` method; neither has search logic of its own.

#### Index shape (PROOF-004, D35)

- **Baseline to test first:** one FTS5 index with the `trigram` tokenizer (case-insensitive, diacritics removed where SQLite supports it), plus a prefix/`LIKE` fallback for terms under 3 characters.
- **Adopt two indexes** (`unicode61 remove_diacritics 2` for words, plus `trigram` for substrings) with rank fusion **only if** the baseline fails specific relevance cases.
- **No Porter stemmer** in either case: it's English-only and distorts Portuguese.
- Indexed text covers text representations, text derived from HTML/RTF, and `extracted_text` (OCR, PDF), so a screenshot is found by the words inside it.
- The index step rebuilds an item's rows whenever its text changes or the index version changes; `content_items.indexed_version` records what's current.

#### Structured filters

Applied in SQL, composing with text queries:

| Filter | Source |
|---|---|
| `since` / `until` | any capture of the item falls in the range |
| `app` | any capture's source app (bundle ID or name) |
| `type` | any representation's UTI, by UTType conformance |
| `pinned` | `content_items.is_pinned` |
| (policy) | items outside the caller's session scope are excluded (§4.12) |

An empty query plus filters is a valid search, ordered by recency.

#### Ranking

- Primary signal: text relevance (FTS5 `bm25()`).
- Secondary signal: **recency**, an exponential decay on `last_captured_at`.
- Small boosts: pinned, `capture_count`, exact phrase match.
- Tie-break: `last_captured_at DESC`, then `id DESC`, so ranking is deterministic.
- Weights are named constants in `MuninnSearch`, tuned against the benchmark relevance cases.

#### Results and streaming

- `list` and `search` return up to `--limit` results (default 20) with `total` and `hasMore`.
- `--all` streams the complete result inside **one SQLite read transaction**, whose WAL snapshot keeps the stream consistent. A stream has a deadline in `MuninnLimits`; a reader too slow to finish within it is cut off with an explicit error, so no stream can hold the WAL open indefinitely.
- No cursors: the panel replaces results on each keystroke and uses subscriptions; `--all` covers everything else. Paging can be added if real use needs it.

#### Cancellation

- Each `search` carries a `requestId`; the panel debounces keystrokes and marks each search `supersedes: <previous>`.
- The helper cancels the superseded task; the read connection aborts mid-query via `sqlite3_progress_handler`. A cancelled search never sends results. A dropped connection cancels its in-flight requests.

#### Semantic search: a possible later stage

A future semantic stage would plug in as an extra retriever or a re-ranker over the top N, without changing indexes, IPC or clients. v2 ships without it.

#### Acceptance benchmark (PROOF-004; full system in gate B)

**Corpus:** a seeded, generated **100,000+ item** corpus: PT/EN prose with accents and mixed-language items; Swift, TypeScript, SQL, shell, JSON and stack traces; URLs, UUIDs, hashes, paths and emails; OCR-style noisy text; a long tail of large logs.

**Relevance cases** (expected item in the top 5): `acao` → `Ação`; `webhook` → `stripeWebhookHandler`; `/api/v2/inv` → a full invoice URL; the middle 8 characters of a UUID; `func handle(`; a Portuguese word inside an English sentence; a word that appears only in a screenshot's OCR text.

**Latency targets** (Apple silicon, warm cache): type-ahead first page p95 ≤ 50 ms and p99 ≤ 150 ms; substring query p95 ≤ 100 ms; filtered empty query p95 ≤ 30 ms. Cancellation aborts a slow query within 20 ms. Reported alongside: index size relative to text size, and capture-to-searchable time (target under 1 s).

### 4.8 Capture and processing pipeline

**Heavy processing is a separate pipeline, never part of capture.** OCR, PDF parsing, previews and rich-text parsing are slow, memory-hungry, parse untrusted input and sometimes crash. Capture only decides and persists; everything else is a job.

```text
Observed change (changeCount moved)
       │
       ▼
Capture policy        paused? concealed/transient? excluded? self-copy? rate/size limits? (§4.14)
       │              → skip, coalesce, or continue
       ▼
Persist               ONE DB transaction: capture_event + content item (identity rules, §4.3)
       │              + representations + asset chunks + enqueue worker jobs
       ▼
Index step            helper, right after commit (D30)
       │
       ▼
Worker jobs ──► muninn-worker: text (HTML/RTF) · ocr · pdf · preview
                    └─► outputs applied by the helper, then the index step again
```

Capture-path latency targets are set and measured in PROOF-008.

#### Capture guarantees (best effort, explicit)

Terms: an **observed change** is a pasteboard state the helper saw; a **capture event** is a persisted row.

| Guaranteed | Not guaranteed |
|---|---|
| Every observed change is persisted, coalesced into an existing item's counter, counted as skipped with a reason, or (for privacy skips) dropped without trace (invariant 4) | States overwritten between two polls; macOS keeps no history of past pasteboard contents |
| Observed changes persist in the order observed | Capture while paused, locked, without clipboard access, or for excluded or concealed content |
| Gaps are **detected**: a `changeCount` jump of more than 1, excluding Muninn's own writes, is counted as `missedChanges` | Representations a source app promised but didn't deliver in time (`omitted: "timeout"`) |

Counters in `status` and `doctor`: `missedChanges`, `coalescedRepeats`, `droppedBackpressure`, and skips by reason.

#### Muninn's own writes

- When the helper writes the pasteboard (`copy`, or a copy from the panel), it adds the self-copy marker type carrying the item id, plus `org.nspasteboard.source`.
- On seeing the marker, the monitor records **exactly one** capture event with source `muninn` for that item, re-reads nothing, and doesn't count the change as missed.
- Another app could spoof the marker, but that only suppresses its own capture, which any app can already do with `ConcealedType` (§1.5).

#### Backpressure

Reading must happen when a change is observed, because the next change overwrites the pasteboard. Persisting can lag.
- Pending work is **one capture in flight** (any size up to the per-capture cap) plus a **small text-only queue**.
- A capture that doesn't fit is **not read**: its metadata is counted as `droppedBackpressure`. Text in a full queue pushes out the oldest pending text.
- Pending plaintext is therefore bounded by one maximum-size capture plus a small text buffer; whether that fits the memory budget is measured in PROOF-008 and PROOF-009.

#### Where work runs

| Runs in | Steps | Why |
|---|---|---|
| helper | the index step, applying worker outputs | needs the DB; parses nothing untrusted |
| `muninn-worker` (sandboxed, on demand) | `text` (HTML/RTF → plain), `ocr`, `pdf`, `preview` | isolation and memory (§4.13) |

Plain text never touches the worker: the index step makes it searchable right after commit.

#### Processors (worker)

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
| `text` | an HTML/RTF-to-text extractor that works in a sandbox with no network or file access; whether `NSAttributedString` (WebKit-backed for HTML) qualifies is part of PROOF-013 | `extracted_text` |
| `ocr` | Vision, recognition languages from settings (e.g. pt-BR, en-US) | `extracted_text` |
| `pdf` | PDFKit | `extracted_text`, page count annotation |
| `preview` | in memory only: ImageIO thumbnails, PDFKit first page | `previews`; other types get a generic icon rendered by the app |

Processors are pure; the helper applies all outputs. Annotation producers (type, language, URLs, image metadata) wait until a feature needs them (D28).

#### Idempotency

1. **History is written only by capture,** never by jobs.
2. **Enqueue is idempotent:** `INSERT OR IGNORE` on `(content_item_id, processor_id, processor_version)`.
3. **Each job's output commits in one transaction:** delete the processor's previous outputs for the item, insert the new ones, mark the job done, and clear `indexed_version` so the index step runs again. A crash before commit leaves the old state.
4. **The index step** is not a job row: it rebuilds an item's index rows in one transaction and sets `indexed_version`. On startup, items whose `indexed_version` is stale are re-indexed.
5. **On startup,** running jobs reset to pending; failures retry with backoff, then become failed. One processor's failure never blocks the others.

**Reprocessing:** bumping a processor's `version` re-enqueues it for every item it accepts, at low priority. Old outputs stay searchable until new ones commit.

**Resource behavior:** the worker starts on demand, takes jobs in batches and exits when idle. Heavy jobs run one at a time with timeouts, and are deferred in Low Power Mode or under thermal pressure.

### 4.9 Testing

- **Unit:** Swift Testing per module (store, identity rules, migrations, search, IPC codec, policy decisions).
- **Integration:** the helper under `swift test` with injected test seams (§4.1) on a temp DB; CLI tests run against it.
- **CLI contract:** every command's `--json` output validated against `docs/cli-schemas/`; every exit code exercised; stdout/stderr separation checked per command.
- **Policy:** every scope × command pair, text queries refused under `metadata`, protected items excluded without leaking into counts, session binding (same terminal reuses it; another terminal, a reused tty, and callers with no terminal don't), expiry, lock and unlock, every exit-6 reason.
- **Processing:** fault injection kills the runner at each step of a job and restarts it; the final DB must equal a clean run. Processors are unit-tested on fixtures without a DB.
- **Assets:** kill the helper during large captures and deletes; an asset is complete or absent, never partial.
- **Search:** relevance and latency via `swift run -c release muninn-bench search`, recorded per commit, not part of `swift test`.
- **Migration:** v1 fixture DBs → v2, with the per-row checks in §5.
- **Abuse and limits:** the suite defined in PROOF-015.
- **UI:** XCUITest in the Xcode project (the one XCTest exception).
- **Release-signed:** a nightly job builds a signed, notarized bundle and runs it on a real macOS account (Keychain access, caller identity, pasteboard onboarding, lock behavior, helper registration). Nothing signing-dependent counts as done until it passes there.
- **CI build flags:** `--explicit-target-dependency-import-check error`.

### 4.10 Distribution

- Developer ID signing, hardened runtime, notarization and stapling, scripted.
- Output is a signed `Muninn.app` (zip or DMG) for local installation. No auto-update in v2 (D8).

### 4.11 CLI interface

```text
muninn status [--limits] [--audit]
muninn list [--limit N | --all]
muninn search [<query>] [--app <name|bundle-id>] [--type <kind|uti>] [--pinned]
              [--since <date>] [--until <date>] [--limit N | --all]
muninn history <id>
muninn get <id>
muninn copy <id>
muninn paste <id> [--as <kind|uti>]
muninn open [<id>]
muninn pause | resume
muninn pin <id> | unpin <id> | delete <id>
muninn session start [--scope metadata|read|manage] [--for <duration>] | status | end
muninn doctor
muninn debug send

Global: --json, --no-interactive, --width <cols>, --version, help
```

The complete flag and exit-code reference is generated from `docs/cli-schemas/` in gate B; this synopsis and the table below are the design-level summary.

#### CLI contract

These rules are part of the public interface; breaking one is a breaking change.

1. **Stable JSON schemas.** Every `--json` output has a JSON Schema in `docs/cli-schemas/` (plus a shared `error.json`) and carries `schemaVersion`. Within a major version, changes are additive only. Keys are `camelCase`, timestamps ISO-8601 UTC, ids integers.
2. **Predictable exit codes:**

   | Code | Meaning |
   |---|---|
   | 0 | Success |
   | 1 | Usage error |
   | 2 | Not found |
   | 3 | Helper unreachable |
   | 4 | Caller identity rejected |
   | 5 | `doctor` found problems |
   | 6 | Denied by policy; `reason`: `no_session`, `scope`, `declined`, `timeout`, `non_interactive`, `locked`, `app_unreachable` |
   | 7 | Internal error |
   | 8 | Incompatible helper version |
   | 9 | Helper busy (a limit was hit; retry later) |

3. **stdout for results, stderr for errors.** stdout carries only the successful result (text, JSON, or `paste` bytes). Errors and progress go to stderr; with `--json`, the error is an `error.json` object on stderr and stdout stays empty.
4. **No silent truncation.** `list` and `search` default to `--limit 20`, which is documented; JSON includes `total` and `hasMore`, and human output ends with a "showing 20 of N" notice on stderr. `get` and `paste` never truncate. `list` and `search` return a size-capped `preview` plus `byteSize`, never full content; the human table also cuts previews at `--width` and marks each cut with `…`.
5. **Hand-written argument parsing** (no dependency).
6. **Builds and tests without Xcode.**

| Command | Behavior | Scope (§4.12) |
|---|---|---|
| `status` | Helper state, versions, counts, paused, active session, storage vs. warning thresholds, capture counters, current memory. `--limits` prints `MuninnLimits`; `--audit` prints the audit log. | none (`--audit` needs `metadata`) |
| `list` | Items by most recent capture. | `metadata` |
| `search` | Through `SearchService`. A text query needs `read`; filters alone need `metadata`. `--type` takes a kind (`text`, `rich_text`, `html`, `image`, `pdf`, `file`) or a UTI. | `metadata` / `read` |
| `history` | An item's capture events. | `metadata` |
| `get` | Item, representations (uti, size, role, `omitted`), derived text, `notProcessed` labels. | `read` |
| `copy` | Puts all stored representations back on the pasteboard, with the self-copy marker (§4.8). | `read` |
| `paste` | Streams one representation's raw bytes to stdout; `--as` picks which. | `read` |
| `open` | Opens the panel through `muninn://open[?id=N]`, handled by the app; the URL scheme only selects, never returns content. | none |
| `pause` / `resume` | Pause or resume capture. | none / `manage` |
| `pin` / `unpin` / `delete` | Change or delete an item. | `manage` |
| `session` | Start, inspect or end a session (§4.12). | — |
| `doctor` | Runs checks and prints ✓/✗ with a fix hint each; exit 5 if any fail. | none |
| `debug send` | JSON messages on stdin, replies on stdout (§4.6). | per message |

`doctor` checks:
1. The CLI resolves inside a signed `Muninn.app`, and the symlink on `PATH` points at the current bundle.
2. The helper is registered (`SMAppService`), including `.requiresApproval`.
3. The helper is reachable and accepts the CLI's identity.
4. CLI and helper versions are compatible.
5. The key is present, the DB opens, and `PRAGMA cipher_integrity_check` passes; no orphaned DB is pending.
6. The search index passes `integrity-check`, and no item's `indexed_version` has been stale for more than a minute.
7. Failed and quarantined jobs, by processor, with `last_error`.
8. Capture is active (access granted, not paused), with the last capture time and the capture counters.
9. Storage is below warning thresholds and above the disk floor.
10. Current helper and app memory.

**Why `paste` prints to stdout:** run from a terminal, the frontmost app *is* the terminal, and simulating ⌘V needs Accessibility permission. Stdout is composable and needs none (D10).

**What `--app` relies on:** `source_app` is the best available attribution (`org.nspasteboard.source` if present, otherwise the frontmost app) and is recorded with its confidence (§4.14).

**IPC methods (v2):** `hello`, `status`, `diagnostics`, `list`, `search`, `cancel`, `history`, `get`, `payload` (streamed bytes of one representation), `copy`, `pause`, `resume`, `pin`, `unpin`, `delete`, `session`, `subscribe`.

### 4.12 Access policy

**Principle: identity is not authorization.** Caller identity (§4.6) proves a caller *is* Muninn's CLI, not *who or what is driving it*: any script, agent or malware running as the user can execute the signed CLI. So **no history is readable through the CLI by default**. Every read needs a session the user approves in the app, with user presence.

**What we can and can't know.** No design can reliably determine the intent of another process running as the same user. A terminal suggests a human, but a script can allocate one, and a process started inside an authorized terminal inherits its authorization. So the model doesn't guess: it anchors every session in a user-presence prompt, keeps sessions scoped and short-lived, binds them to something the helper observes itself, and audits everything.

**The trust chain.** The Touch ID or password prompt runs in the app, and the helper accepts "approved" because the message comes from the verified `client = app`. So session approval trusts the signed app; whether the helper verifies the LocalAuthentication result itself is D33.

#### Scopes

| Scope | Allows | Doesn't allow |
|---|---|---|
| *(none)* | `status`, `doctor`, `pause`, `open`, `--version`, `help` | any item data; `status` shows counts only |
| `metadata` | `list`, `history`, filter-only `search` (app, type, date, pinned), `status --audit`. Results carry ids, kinds, UTIs, source app, timestamps, sizes and `notProcessed` labels. | previews, content, **text queries** (a match would reveal content) |
| `read` | everything in `metadata`, plus text search, previews, `get`, `paste`, `copy` on unprotected items | protected items |
| `manage` | `pin`, `unpin`, `delete`, `resume` | reading content (combine with `read` if needed) |

- **`metadata` serves this story:** "In this terminal, let me browse and filter what I copied (by app, type, date) without granting the terminal access to the contents." It's the scope to grant a terminal that runs other people's scripts.
- **Scopes nest:** `read` includes `metadata`. `manage` is separate; one session may hold `read,manage`.
- **`resume` needs `manage`:** if the user paused capture for privacy, a script must not be able to turn it back on. `pause` needs nothing, since it only reduces capture.
- **Protected items** are excluded from every result for every scope (not redacted, so their existence doesn't leak). Reading one takes a **per-request approval**; it is never a session scope.
- The menu bar UI isn't subject to scopes: it is the user's session (`client = app`), and it exposes no automation surface that returns content. Adding such a surface later makes it a new client under this policy. Protected items in the UI can require Touch ID to reveal (D13).

#### Sessions

- `muninn session start [--scope …] [--for …]` asks for a session. A data command without one starts the same flow, asking for the scope that command needs with the default duration, unless `--no-interactive` is set.
- The helper sends `approvalRequested` to the app (launching it if needed). The app's prompt names the scope, the duration, and the terminal's process chain, labeled as context, not proof.
- **A caller with no controlling terminal is always refused** (`non_interactive`). There is no approval path for it in v2 (D27).
- **Binding:** a session belongs to the terminal's **session-leader process**, identified from the kernel through the caller's audit token (not from anything the CLI claims). It can't outlive that process, and it can't pass to a new terminal that reuses the same tty. How this is identified and detected is PROOF-002.
- **Lifetime:** each scope has a default and a ceiling in `MuninnLimits`. Sessions live only in helper memory and end on `muninn session end`, when the session leader exits, and when the Mac locks.

#### Automation: deferred (D27)

Scripts, cron jobs and agents without a terminal get no access to history in v2. Non-interactive grants are designed only when D1 decides whether agent access is part of the product.

#### Enforcement and audit

- Everything is enforced in the helper; nothing a client says about itself is trusted.
- Search applies scope and protection inside the query, so excluded items never affect `total` or `hasMore`.
- The audit log records every session (created, used, ended) and every CLI data request (scope, command, item ids, decision), never content, within the retention bound in `MuninnLimits`. Deleting an item nulls its id in the log.
- Denials exit with code 6 and a stable `reason` (§4.11).
- **Dev and test builds** don't relax the policy; tests inject a scripted approver.

### 4.13 Memory

Muninn runs continuously, so memory is a design constraint (invariant 9). The principle: **the always-running processes stay small, and heavy work runs in a process that exits when done.**

| Process | Lifetime | Holds | Must not hold |
|---|---|---|---|
| `muninnd` (helper) | always | capture, one writer + small reader pool, IPC, job scheduler, index step | Vision, PDFKit, Core Image, decoded images, payloads beyond the capture in flight (§4.8) and the request being served |
| `muninn-worker` | on demand | one job's input and the framework it needs | anything between jobs |
| `Muninn` (app) | always (hotkey, approvals) | menu bar item, hotkey, IPC subscription | panel views, thumbnails or results while the panel is closed |
| `muninn` (CLI) | per command | one response | — |

**Mechanisms:**
- **Streaming:** asset I/O is chunked; `paste` and `copy` stream; hashing is incremental.
- **No full decode in the helper:** dimensions come from ImageIO properties; thumbnails and OCR input are downsampled in the worker.
- **Bounded SQLite:** a small page cache per connection, a process-wide heap limit, and memory released when idle and under pressure.
- **Lean responses:** `list` and `search` return a size-capped `preview`, never full content.
- **Bounded caches:** each has a byte limit and is cleared under memory pressure; the panel's caches go when it closes.

**How we know** (PROOF-009, PROOF-016): idle footprint with 100 vs. 100k items, a large capture-and-paste round trip, a nightly soak with no upward trend, and `leaks` in CI. `status` and `doctor` show current memory. The budget numbers are hypotheses recorded in PROOF-009.

### 4.14 Guardrails: big files and clipboard abuse

**Principle: Muninn knows its limits and says so.** It doesn't have to do everything with every copy; it has to be clear when it doesn't.
- **Limits are published.** `MuninnLimits` in code is the single source of every value (defaults, ceilings, what settings may change). The *What Muninn doesn't do* page and `muninn status --limits` are generated from it. This section says *what* is limited and *what happens*, not the numbers.
- **Past a limit, a step is skipped entirely,** never done partially. A giant PDF is kept, but nothing is extracted from it.
- **Every skipped step is labeled on the item**, e.g. *"Not searchable inside: PDF has 1,240 pages (limit 300)"*. In `get` JSON this is `notProcessed: [{step, reason, limit, actual}]`.
- **Limits are simple thresholds checked before work starts.**

The clipboard is an **untrusted input**: any app, script or web page can put anything on it, as large and as often as it likes.

| Case | What's limited | Where | Past the limit |
|---|---|---|---|
| Huge payload | bytes per representation and per capture | capture, while reading | metadata only (`omitted: "size"`), labeled, never deduplicated (§4.3) |
| Fan-out (⌘C on many files) | file references per capture | capture policy | no references kept; count and common folder only |
| Flood | captures per source over time | capture policy, before reading | not read; counted; sustained floods pause capture (below) |
| Repeat flood | identical captures from one source in a short window | capture policy | coalesced: no event, `coalescedRepeats` incremented |
| Slow promised data | time to read one capture | capture | remaining representations `omitted: "timeout"` |
| Crafted or huge files | per-processor eligibility (size, pixels, pages), run-time timeouts and memory | scheduler and worker | not processed, labeled; oversized output discarded, never truncated |
| Crashing inputs | worker crashes per job | runner | quarantined after repeated crashes; labeled; manual retry |
| Disk pressure | free space | capture | below a warning floor, binaries are `omitted: "disk"` and text continues; below a hard floor, capture pauses and the user is notified |
| Client floods | connections, in-flight requests, message size, slow readers and stream duration | IPC | `busy` (exit 9) or disconnect; the app's connection has a reserved slot |

**Reading:** only kept representations are read, compact ones first (TIFF isn't read when a compact raster type is offered). macOS doesn't expose a representation's size before it's read, so the one capture in flight is the memory peak; PROOF-001 measures it for 500 MB and 2 GB reads. Reads happen off the main actor if PROOF-001 shows that's safe.

#### Floods: act on attribution confidence

| Attribution | When | Response |
|---|---|---|
| **High** | `org.nspasteboard.source` names the app | Per-app rate limit; a sustained flood pauses capture from that app for a while, with a notice offering *Resume* and *Always ignore* |
| **Low** | frontmost-app guess only | A short, global, metadata-only slowdown that lifts automatically, with no *Always ignore*. The notice says "something changed the clipboard 340 times while Safari was frontmost". |

#### Storage growth: history is permanent (D18)

- Original content is never deleted automatically because it's old.
- Growth is controlled at capture time (the limits above) and by pruning regenerable data (previews, caches).
- Past the warning thresholds, the app offers cleanup tools that preview what they'll remove: items older than…, original binaries of unpinned items older than…, everything from app X.

#### Visibility

Every drop or cap is counted in `status` and explained by `doctor`: rate-limit drops and pauses, `coalescedRepeats`, `missedChanges`, `droppedBackpressure`, `omitted` by reason, `notProcessed` labels, quarantined jobs. Privacy skips are the exception: they leave no trace (invariant 4).

### 4.15 Observability and log privacy

- **Logging:** `os.Logger` with subsystem `com.muninn`, one category per module. Clipboard content, extracted text, file paths and search queries are never logged in release builds; dynamic values default to `privacy: .private`, and only ids, counts, durations, UTIs and error categories are public. The integration suite greps release log output for seeded canary strings.
- **Signposts** (`OSSignposter`) on the capture path, each job and each search, for measuring the targets in Instruments and the benchmarks.
- **Crash handling:** worker crashes become job failures; a crash report contains stacks and ids, never content.
- **No telemetry.** Nothing leaves the machine.

### 4.16 Platform features

What macOS provides, and how we use it. **Status:** **use** (part of the design), **proof** (depends on a named proof), **deferred** (not in v2, may return), **external** (outside Muninn, relied on), **no** (deliberately not used).

#### Platform constraint: pasteboard privacy

`NSPasteboard.accessBehavior` (present on every supported macOS) governs **programmatic** reads of the general pasteboard. From the SDK headers (Xcode 27.2):
- An app that has never triggered an access alert reports `.default` and isn't listed in System Settings.
- The first programmatic read shows a system alert and the state becomes `.ask`; only then can the user choose *Ask*, *Always Allow* or *Always Deny*.
- Reads that are both user-originated and paste-related are always allowed.

So onboarding has to create that first alert deliberately:

| Step | State | What Muninn does |
|---|---|---|
| 1 | `.default` | The first-run panel explains what Muninn records. Button: **Enable Clipboard Monitoring**. Nothing reads the pasteboard before this click. |
| 2 | → alert | The click causes **one deliberate read** by the process that will read from then on (D23); the alert appears in direct response to the user's action. |
| 3 | `.ask` | The panel asks the user to allow Muninn without asking each time, offers to open the right System Settings pane, and shows the current state live. |
| 4 | `.alwaysAllow` | Detected on re-check; capture starts and the raven switches to *recording*. |
| — | `.alwaysDeny` | The panel explains how to change it. No repeated reads, no nagging. |

**Steady state:** the capture loop checks `accessBehavior` before every read and reads only in `.alwaysAllow`. Otherwise it reads nothing, and the menu bar shows *access not granted* with a *Fix…* action. Checks that don't read content (`changeCount`, `types`, `detectMetadata`, `detectPatterns`) are preferred wherever they suffice.

**PROOF-001 establishes**, as one layout matrix with PROOF-003: whether a background agent can present the alert and under what name; which calls trigger it; whether the alert offers persistent choices; deep-link availability; and how all of this combines with the helper's location, the worker launch and the Keychain group. The answers decide **D23**:
- If the helper can read with a clear "Muninn" identity, the helper reads.
- Otherwise the **app** reads and streams captures to the helper over a one-way capture channel, accepted only from `client = app` and never mixed with UI requests. The app then never buffers a whole payload, a crash of the app means missed captures (counted), and capture latency includes the IPC hop.

#### What we use

| Need | macOS feature | Status | Notes |
|---|---|---|---|
| Key storage | data-protection keychain | use | private access group on the helper only (§4.4); provisioning: PROOF-003 |
| Hardware-bound key | Secure Enclave wrapping | deferred | D22 |
| User presence | LocalAuthentication | use | sessions, protected reads, revealing protected items |
| Lock state | screen lock, user switching, sleep notifications | proof | PROOF-003 |
| Caller identity | XPC peer code-signing requirement | proof | D21, PROOF-002 |
| Process hardening | Hardened Runtime, library validation, notarization | use | |
| Parser isolation | XPC service + App Sandbox for `muninn-worker` | proof | PROOF-013 (D17) |
| Disk encryption | FileVault | external | recommended in the UI |
| Helper lifecycle | `SMAppService.agent`, launchd `KeepAlive`, `ProcessType = Adaptive`, `ThrottleInterval` | use | launchd restarts the helper and throttles crash loops |
| Deferrable work | `NSBackgroundActivityScheduler` | use | reprocessing, index merges, incremental vacuum, preview pruning |
| Power and thermal | Low Power Mode, `thermalState` | use | defer heavy jobs |
| Memory pressure | memory-pressure events | use | drop caches, release SQLite memory |
| Types | UniformTypeIdentifiers | use | |
| Pasteboard conventions | nspasteboard.org: `ConcealedType`, `TransientType`, `AutoGeneratedType`, `org.nspasteboard.source` | use | privacy skips and source attribution |
| Content | Vision, PDFKit, ImageIO, Core Image | use | worker only, from in-memory buffers |
| File references | `URL.bookmarkData` | use | created only on explicit user action (§4.3) |
| Migration copies | APFS copy-on-write clones | use | |
| Logs and timing | `os.Logger`, `OSSignposter`, Instruments | use | |
| Global hotkey | Carbon `RegisterEventHotKey` | use | needs no Accessibility or Input Monitoring permission |
| Spotlight | `.metadata_never_index` in the data dir | use | |
| Backups | Time Machine | external | ciphertext; restores work on the same Mac only; exclusion is D34 |

#### What we deliberately don't use (v2)

| Feature | Why not |
|---|---|
| Quick Look of item content, QuickLookThumbnailing | Both need file URLs, which would mean writing decrypted content to disk (invariant 1). Previews are rendered in memory; other formats get a generic icon (D26). |
| MetricKit | No field problem needs it; the soak benchmark and `leaks` cover memory (D31). |
| launchd `Sockets` | Needs an absolute, per-user path that a bundle-signed plist can't hold. |
| Shortcuts, App Intents, AppleScript, Services, Share extensions returning content | Each would be a new client under §4.12; not in v2. |
| Simulated ⌘V (Accessibility) | Extra permission (D10). |
| Core Data / SwiftData | Can't give us SQLCipher, FTS5 control or these schema guarantees. |
| iCloud / CloudKit | No network (§1.3). |
| Universal Clipboard | Not used, but handled: content from another device has no local source app and is treated as untrusted like everything else. |

### 4.17 Look and feel

Lives in `docs/brand.md`: the scratched raven (app icon and menu bar icon with four status modes), the ASCII raven for the terminal, and the palette. It's a separate track (D24). Design requirements here: the menu bar icon reflects helper state (recording, paused, no clipboard access, needs attention), always with a text label; the app uses native controls and system semantic colors.

---

## 5. Migration from v1

1. On first v2 launch, the helper detects a plaintext v1 `muninn.db`: a `clipboard_entries` table, with `schema_version` 1 or with no `schema_version` table at all (a DB older than v1's migration).
2. It creates the key and a new encrypted DB with the v2 schema.
3. Each v1 row maps to one `capture_events` row (`captured_at` = v1 `created_at`, source unknown) and to an item:
   - **text rows:** the v2 identity is **recomputed** from the text (§4.3); rows with the same text merge into one item with several events. The v1 `content_hash` is used only as an input check.
   - **non-text rows:** never merged, because v1 stored no bytes. Each becomes its own item with no representation and a null `content_hash`; v1 `metadata` is kept as an `annotations` row.
   - **pinned rows** set `is_pinned`.
4. The index step runs for the migrated text.
5. **Verification, per v1 row:** the text (or metadata), timestamp, pinned state and kind survive; text duplicates map to the expected item with the right capture count; non-text rows each map to their own item; totals match (v1 rows = v2 events). Only then does the helper atomically swap files and delete the plaintext DB and its WAL/SHM files.
6. On failure, the plaintext DB is left untouched and the error is shown in the UI. The helper doesn't run half-migrated.
7. Deleting the plaintext file doesn't erase it from SSD free blocks or existing Time Machine and APFS snapshots. The UI says so after migration and recommends FileVault.

---

## 6. Decisions

Decisions, including the alternatives considered for each, live in `docs/decisions.md`. This document states the design that results from them; when a decision changes, both files change in the same commit. Decision IDs are never reused, and a reversed decision is marked **Revised** with its date.

---

## 7. Delivery: evidence gates

v2 is delivered through **four evidence gates**. Each ends with a **working system plus an evidence record** (`docs/proofs.md`, `docs/evidence/`). Work inside a gate is limited to what its proofs justify.

| Gate | Goal | Must be demonstrated | Proofs |
|---|---|---|---|
| ✅ 0 | Toolchain | Swift 6.4, Swift Build, import checks (`swift build --explicit-target-dependency-import-check error` passes; there's no CI yet, so nothing runs it automatically until gate B adds CI) | — |
| **A** | **Platform feasibility** | With throwaway spikes on the minimum OS, one **layout matrix**: helper location × which process reads the pasteboard × worker launch × Keychain group × referenced-file access, plus caller identity and SQLCipher search | 001 pasteboard access and layout · 002 caller identity, session binding, transport · 003 Keychain and lock · 004 encrypted search and index shape |
| **B** | **Secure minimum engine** | Encrypted capture through an **injected `PasteboardSource`** (L1); storage v2 with chunked assets; `SearchService`; the CLI and its contract; the access policy enforced with the scripted approver (L1); the chosen IPC transport; dev-build isolation; concurrency conventions. No UI, no file processing. | 005 asset storage at size · 006 policy vs. a scripted CLI · 007 `--all` stability and stream limits · 008 capture guarantees · 009 memory baseline |
| **C** | **Migration and daily use** | The restructure in §4.1; real pasteboard capture in the signed bundle; onboarding; the real approval prompt; panel, hotkey and icon modes; session lock; restart and crash recovery; release-signed nightly run; v1 migration | 010 migration of a v1 copy · 011 lock behavior · 012 crash recovery |
| **D** | **Rich content** | The sandboxed worker and its processors; limits and the abuse suite; memory soak; final raven artwork | 013 worker isolation · 014 processing idempotency · 015 abuse suite · 016 memory soak |

**Rules:**
- **Platform and security proofs come before the restructure,** which happens in gate C, once gates A and B show the architecture holds.
- **Detail follows the gate.** Sections for later gates state intent, constraints and the deciding proof; they're expanded when their gate starts.
- **A failed or inconclusive proof changes the design** before anyone builds past it. Each gate A proof names its fallback in `proofs.md`.
- **Proofs never touch real user data.**

---

## 8. Glossary

| Term | Meaning |
|---|---|
| **Helper** (`muninnd`) | The always-running background process; the only one that holds the key and opens the DB. |
| **Worker** (`muninn-worker`) | The sandboxed, on-demand process that runs heavy parsers. |
| **Observed change** | A pasteboard state the helper saw (`changeCount` moved), before the capture policy. |
| **Capture event** | A persisted record of one observed change that passed the capture policy. Immutable. |
| **Item** (content item) | Canonical deduplicated content; what ids in the CLI and UI refer to. |
| **Representation** | One stored form of an item (plain text, RTF, PNG, file reference, …). |
| **Asset** | Stored binary bytes, deduplicated by hash, kept as chunks inside the encrypted DB. |
| **Derived content** | Anything recomputable from an item: extracted text, previews, annotations, index rows. |
| **Processor / job** | A pure, versioned transformation run by the worker, and one scheduled run of it for one item. |
| **Index step** | The helper's rebuild of one item's search-index rows. |
| **`omitted` / `notProcessed`** | Labels for a representation not stored, and a processing step skipped, each with a reason. |
| **`MuninnLimits`** | The single in-code source of every limit value. |
| **Pinned** | An item the user marked to keep at hand; boosted in ranking and filterable. |
| **Protected item** | An item excluded from all CLI results; reading it takes a per-request approval. |
| **Scope** | What a CLI session may do: `metadata`, `read`, `manage`. |
| **Session** | A user-approved, scoped, time-limited permission for CLI use, bound to one terminal's session leader. |
| **Gate** | A delivery milestone that ends with a working system and evidence (§7). |
| **Evidence level** | L1 behavioral, L2 integration and security, L3 operational (`proofs.md`). |
