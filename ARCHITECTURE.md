# Brewery — Architecture

A native macOS GUI for Homebrew. SwiftUI, macOS 26, zero third-party dependencies.

## Goals

1. Fast fuzzy search over the full Homebrew catalog (formulae + casks) to discover new packages.
2. Package icons: favicon of each package's homepage, with SF Symbol fallbacks.
3. Management of installed items — **v1 is non-destructive only**: install and upgrade (per item + upgrade all).
4. App Store-like cards; native macOS look per Apple HIG.
5. Simple, maintainable code. KISS and YAGNI throughout.
6. **(v2)** Filters and dependency visibility: search scoped to formulae/casks with an option to hide deprecated entries; Installed scoped to directly-installed items (with an "all" escape hatch); per-package installed dependencies; and, for items pulled in as dependencies, who requires them.
7. **(v3)** Richer package pages and a faster shell: provided commands per formula (command-not-found data) and search-by-command; caveats, conflicts, and 90-day install analytics in the detail sheet; a Fonts filter with a native glyph instead of favicons; per-tab search state; item counts in the window subtitle; windowed grid rendering; and a real icon cache.

## Non-goals (v1)

- **No destructive brew commands.** No `uninstall`, `zap`, `cleanup`, `pin`/`unpin`, `--force`. Hard safety requirement — structurally enforced, see [Safety](#safety).
- No taps management, no services, no doctor. No dependency *graph visualization* — v2 shows flat dependency/dependent lists from install receipts, nothing more.
- No analytics-based popularity *ranking* — v3 displays install counts in the detail sheet, but they still don't feed the search scorer (revisit only if search feels bad in practice).
- No Settings pane, no multiple windows, no log persistence across launches.
- No App Store distribution (the app cannot be sandboxed — it execs `brew`).

## How Homebrew actually works (verified against brew 6.x source)

Facts below were verified by reading the Homebrew source (brew 6.x, `Library/Homebrew/...` paths cited). The design depends on them.

### Catalog data

- formulae.brew.sh serves full catalogs: `GET /api/formula.json` (~8.5k formulae, ~30 MB uncompressed) and `GET /api/cask.json` (~7.7k casks, ~17 MB uncompressed; both gzipped over the wire). Entries carry `name`/`token`, `desc`, `homepage`, `versions.stable`/`version`, `deprecated`, `disabled`, cask display `name` array, etc.
- brew 6.x's own local API cache (`~/Library/Caches/Homebrew/api/`) moved to an *internal* per-arch format (`internal/packages.<tag>.jws.json`, built in `api/internal.rb` — undocumented, machine-specific keys, not a public contract); the legacy `formula.jws.json`/`cask.jws.json` may exist on disk but are no longer refreshed. **Therefore the GUI downloads `formula.json`/`cask.json` from formulae.brew.sh itself** rather than parsing brew's cache.
- **(v3)** Catalog entries also carry `caveats` (string, may embed a literal `$HOMEBREW_PREFIX` — verified on `php`) and, for formulae, `conflicts_with` + `conflicts_with_reasons` (parallel arrays; verified on `vim`: `["ex-vi", "macvim", …]` with human-readable reasons). Cask `conflicts_with` is a differently-shaped object — deferred.
- **(v3) Command database**: brew's `command-not-found` data — which executables each formula installs — is generated from the internal API's per-formula `executables` array (`api.rb:282-309`, published at `ghcr.io/v2/homebrew/command-not-found/executables`, `api.rb:314`). formulae.brew.sh serves the same file publicly: `GET /api/internal/executables.txt`, ~350 KB, one line per formula, format `name:cmd1 cmd2 …` (verified live; brew keeps its own copy at `~/Library/Caches/Homebrew/api/internal/executables.txt`). We download the public file with the catalog — no dependence on brew's cache dir; if the endpoint ever moves, the feature degrades to hidden, nothing else breaks.
- **(v3) Analytics**: `GET /api/analytics/install/90d.json` (2.4 MB, 44,938 items incl. tap formulae) → `{"items":[{"formula": "openssl@3", "count": "1,444,028", …}]}` — **counts are comma-formatted strings**. Casks: `GET /api/analytics/cask-install/homebrew-cask/90d.json` (440 KB) → keyed `{"formulae": {"<token>": [{"cask": "<token>", "count": "868"}]}}` — the top-level key really is `formulae` (historical misnaming) and it's a dict, not an array. Both verified live.

### Installed state

- Formulae live in `$(brew --prefix)/Cellar/<name>/<version>/`, casks in `Caskroom/<token>/` (installed version derivable only via the `.metadata` glob — fiddly). Instead of walking directories, use brew's own fast paths:
  - `brew list --formula --versions` and `brew list --cask --versions` — plain text `name v1 [v2...]` per line, implemented in pure Bash (`list.sh`), no Ruby startup, sub-second. (The `--json` variant requires `jq` — avoided.) The `--formula` token is required: bare `brew list --versions` prints casks alongside formulae (verified live: 352 lines vs 309 + 43), which would key every cask into the overlay a second time as `formula:<token>`.
  - `brew outdated --json=v2` → `{"formulae":[{name, installed_versions[], current_version, pinned, pinned_version}], "casks":[...]}`. **Exits 0 even when items are outdated** (only exits 1 when given explicit names). <1 s with a warm cache. Cask `name` is the token; formula `name` is the full name.
- Prefix: probe `/opt/homebrew/bin/brew` (Apple silicon), then `/usr/local/bin/brew` (Intel). `brew --prefix` is canonical; we derive it as the brew binary's grandparent directory — the same rule `bin/brew` itself uses (`HOMEBREW_PREFIX="${HOMEBREW_BREW_FILE%/*/*}"`).

### Install receipts (v2)

Every keg carries an install-time receipt, and it answers all of v2's dependency questions locally — no brew subprocess:

- `Cellar/<name>/<version>/INSTALL_RECEIPT.json` (formulae): `installed_on_request` (bool; brew treats an absent field as `false`, `tab.rb`) and `runtime_dependencies` — an **array** of `{full_name, version, pkg_version, declared_directly}` covering the full flattened runtime closure at install time. Verified live: `wget` → `installed_on_request: true`, deps `libunistring`, `gettext`, `libidn2`, `ca-certificates`…; `abseil` (pulled in as a dep) → `false`.
- `Caskroom/<token>/.metadata/INSTALL_RECEIPT.json` (casks): has `installed_on_request` too, **but `runtime_dependencies` is an object, not an array** (observed live: `{}`) — a different shape than formulae. v2 reads only `installed_on_request` from cask receipts; cask dependency lists are deferred (cask deps are rare, and the non-empty object shape is unverified).
- Receipts are snapshots: a formula upgraded later rewrites its receipt, but the list can drift from what `brew deps` would compute today. Accepted — intersecting with the live installed set (below) prunes stale entries.
- `brew deps --installed` / `brew uses --installed` were considered and rejected: Ruby startup per call, and the receipts already hold the same answer as plain local file reads.
- Cross-check for free: `brew list --installed-on-request` exists (`cmd/list.rb:43`, Ruby path) — used only as a build-step verify, not at runtime.

### Driving brew from a GUI

- **Environment** (set on every invocation):
  - `HOMEBREW_NO_ENV_HINTS=1` — silences hint noise on stderr.
  - `HOMEBREW_NO_ASK=1` — belt-and-braces; brew's ask-mode already auto-skips prompts when stdio is not a TTY (`ask.rb`: `return false if !$stdin.tty?`).
  - `HOMEBREW_NO_AUTO_UPDATE=1` — skips both the git auto-update *and* the API refresh. Critical for two reasons: read commands stay fast, and the auto-update path `exec`s a fresh brew process mid-run (`utils/auto-update.sh`), which would restart our output stream.
  - `HOMEBREW_NO_INSTALL_CLEANUP=1` — **part of the non-destructive guarantee.** By default `brew install`/`upgrade` auto-clean old kegs of the touched formula and, every `HOMEBREW_CLEANUP_PERIODIC_FULL_DAYS` (30) days, run a *full* cleanup of all formulae and caches (`env_config.rb:586`). The command whitelist alone doesn't prevent that; this env var does.
  - `SUDO_ASKPASS=<helper>` on mutating commands (see below).
- **User config can override us**: `bin/brew` loads `brew.env` files (`/etc/homebrew/brew.env`, `$PREFIX/etc/homebrew/brew.env`, `~/.homebrew/brew.env` or XDG) and exports any `HOMEBREW_*`/`SUDO_ASKPASS` line, protecting only variables `bin/brew` itself sets — so a user's `brew.env` beats the env we pass. Treat our env vars as defaults, not invariants; behavioral claims below carry that asterisk.
- **Freshness**: with auto-update disabled, brew's metadata could drift from what the UI shows (bottle 404s, older versions). Mitigation: enqueue one `brew update` operation automatically per app session, before the first mutating operation. (An *explicit* `brew update` is not gated by `HOMEBREW_NO_AUTO_UPDATE` — only the auto-update path checks it, `utils/auto-update.sh` — so it refreshes brew's git taps and API cache even with our env set.) `⌘R` re-fetches installed/outdated state and re-runs the catalog staleness check (downloading if older than 24 h).
- **Sudo (pkg casks)**: cask `pkg` artifacts (and a few others) invoke `sudo`. With piped stdio sudo has no TTY and fails/hangs — unless `SUDO_ASKPASS` points to an executable, in which case brew adds `-A` itself (`system_command.rb`). We ship a tiny osascript helper (written to Application Support at launch, chmod 0700). If the user cancels the dialog, sudo fails fast and the operation logs a readable `Error:` line. A wrong password makes sudo re-invoke the helper up to its retry limit — the same dialog just reappears, with no error context; accepted.
- **Concurrency**: mutating commands take non-blocking flocks in `var/homebrew/locks/` — a second concurrent mutation errors immediately (`OperationInProgressError`) rather than queueing. **The GUI serializes all mutating operations in a FIFO queue, one at a time.** Read commands are safe to run concurrently.
- **Exit codes**: 0 ok, 1 failure (no finer taxonomy — stderr carries `Error:`/`Warning:` lines), 130 on SIGINT.
- **Output**: pipes are not TTYs, so brew emits no color by default (and passes `--silent` to curl, so no progress spam). The log view still strips ANSI escapes — one regex — because a user `brew.env` can force `HOMEBREW_COLOR=1`.
- **`brew install X`** on an installed-but-outdated `X` acts as an upgrade — unless the user's `brew.env` sets `HOMEBREW_NO_INSTALL_UPGRADE` (`cmd/install.rb:32`), in which case it's a no-op with a notice. Acceptable either way: both actions are on the safe list.

## File layout

~16 Swift files, flat in `Brewery/`. Targets use filesystem-synchronized groups — **never edit `project.pbxproj` to add files**.

| File | Responsibility |
|---|---|
| `BreweryApp.swift` | `@main`, WindowGroup (min 900×600), menu `Commands` (Refresh ⌘R, Upgrade All ⇧⌘U), confirm-on-quit while a mutation runs |
| `AppModel.swift` | The single `@Observable` root: catalog, installed/outdated dictionaries, operation queue + pump, refresh orchestration, `status(for:)` merge |
| `Package.swift` | Pure data: `Package`, `PackageKind`, `InstalledInfo`, `OutdatedInfo`, `PackageStatus` |
| `BrewCommand.swift` | The safety whitelist enum — the only source of brew argv in the app |
| `BrewClient.swift` | brew binary discovery, `Process` exec with async line streaming, cancellation; static pure parsers for brew output |
| `BrewOperation.swift` | `@Observable` per-operation: command, state, capped live log buffer |
| `CatalogStore.swift` | download (catalog + executables + analytics) → slim-decode/merge → versioned cache file → `[Package]`; staleness check |
| `Receipts.swift` *(v2)* | `@concurrent` sweep of `INSTALL_RECEIPT.json` files → on-request flags + dependency lists; pure parser |
| `IconStore.swift` *(v3)* | actor: favicon fetch with in-flight dedup → memory `NSCache` + disk LRU (byte-capped); negative-result markers |
| `FuzzySearch.swift` | Pure scorer + `@concurrent` ranking |
| `ContentView.swift` | `NavigationSplitView` shell: sidebar, `.searchable`, operations popover, brew-missing state |
| `PackageGridView.swift` | `ScrollView` + `LazyVGrid` of cards, empty states |
| `PackageCardView.swift` | One card: icon, name, status line, description, action button |
| `PackageDetailView.swift` | Sheet: header, homepage link, warnings, action button, operation log |
| `PackageIconView.swift` | icon view backed by `IconStore` (v3; was `AsyncImage`), SF Symbol fallbacks |
| `OperationLogView.swift` | Monospaced auto-scrolling log for one operation |

Deleted from the template: `Item.swift`, the SwiftData `ModelContainer` boilerplate in `BreweryApp.swift`.

Tests in `BreweryTests/` (Swift Testing — `@Test`/`#expect`); the suites are specified in [Tests](#tests) — how they're grouped into files is the implementer's call.

## Data model

```swift
enum PackageKind: String, Codable { case formula, cask }

struct Package: Codable, Identifiable, Hashable {
    let kind: PackageKind
    let name: String          // formula name or cask token, e.g. "visual-studio-code"
    let displayName: String?  // cask display name, e.g. "Visual Studio Code"; nil for formulae
    let desc: String?
    let homepage: String?     // parsed to URL lazily, only for icons/links
    let version: String       // formula versions.stable / cask version
    let deprecated: Bool
    let disabled: Bool        // disabled packages cannot be installed — disable the button
    let caveats: String?      // v3; display-time: substitute literal "$HOMEBREW_PREFIX" with the real prefix
    let conflicts: [Conflict] // v3, formulae only; zipped from conflicts_with + conflicts_with_reasons
    let commands: [String]    // v3, formulae only; from executables.txt
    let installs90d: Int?     // v3; nil = not in the analytics files
    var id: String { "\(kind.rawValue):\(name)" }
    var isFont: Bool { kind == .cask && name.hasPrefix("font-") }
}

struct Conflict: Codable, Hashable { let name: String; let reason: String? }
```

(Synthesized packages for catalog-missing installed items get empty/nil v3 fields. `Conflict` zips the two parallel API arrays; a length mismatch pads reasons with `nil` rather than crashing.)

Install-state overlays live in `AppModel`, keyed by `Package.ID`, never persisted (they're <1 s to re-query):

```swift
struct InstalledInfo {
    var versions: [String]
    var onRequest: Bool         // v2, from receipt; missing receipt → true (never hide the unknown)
    var dependencies: [String]  // v2, formulae only: installed runtime deps, short names
}

struct OutdatedInfo  { var installed: [String]; var current: String; var pinned: Bool }

enum PackageStatus {
    case notInstalled
    case installed(version: String)
    case outdated(installed: String, current: String)
    case busy                 // a queued/running operation targets this package
}
```

`AppModel.status(for:)` merges the three sources; `busy` wins. A running `upgradeAll` marks every currently-outdated *unpinned* package busy (bare `brew upgrade` skips pinned ones). **Join rule**: `brew outdated` reports formulae by tap-qualified `full_name` (`user/tap/foo`) while `brew list` prints short keg names — normalize both to the last `/`-separated component, so an overlay key is always `kind:shortname`, matching `Package.ID`. Cross-tap name collisions are theoretically possible and accepted for v1.

The views are dumb renderers of `[Package]` + `status(for:)`:

- **Discover** — the full catalog, fuzzy-filtered by search.
- **Installed** — catalog packages present in `installed`, **plus synthesized `Package`s** for installed items missing from the catalog (e.g. from third-party taps): name + kind, `version` = installed version (the only version we know), nil desc/homepage, `deprecated`/`disabled` = false.
- **Outdated** — packages present in `outdated`. Pinned items are shown with the Update button disabled and a "pinned" label (we never touch pins). The section mirrors bare `brew outdated`'s **non-greedy default**: `version :latest` casks never appear, and `auto_updates` casks (browsers, editors) appear only when the installed bundle's `Info.plist` version lags the cask version (`cask/cask.rb`); the `--greedy` variants are deliberately out of scope for v1 — those apps update themselves.

Overlay refresh happens on launch, on ⌘R, and after every mutating operation completes (success or failure). **(v2)** Each refresh also sweeps the receipts (`Receipts.swift`, `@concurrent` — ~350 small JSON reads, tens of ms): the keg read is the one whose version dir matches the *last* version `brew list` reported; `runtime_dependencies` `full_name`s are normalized to short names per the join rule. `AppModel` then inverts the dependency map once into `dependents: [Package.ID: [Package.ID]]` — "who depends on X" is a dictionary lookup, no graph machinery.

**(v2) Filters** are plain view-local state, persisted with `@AppStorage`:

- **Discover**: kind (`All | Formulae | Casks | Fonts` — Fonts (v3) are the `font-`-prefixed casks, in `homebrew/cask` since the fonts-tap merge (verified: `font-fira-code` → `tap: homebrew/cask`); `Casks` excludes them so it means "apps", otherwise the Fonts option would be pointless) + a "Hide deprecated" toggle (hides `deprecated || disabled` — a disabled package is further along the same lifecycle and can't be installed anyway). Applied as a pre-filter to the array handed to `FuzzySearch.rank`, so ranking cost only ever shrinks. (`.searchScopes` was considered for the kind filter and rejected: scopes only surface while search is active, and the filter must also govern empty-query browsing.)
- **Installed**: scope picker `On Request` (default) | `All`. On Request shows `onRequest == true` items; All adds dependency-only items, each carded with a small "dependency" tag.

**(v3) Per-tab search state**: queries live in `AppModel.queries: [Section: String]`, and each section's `.searchable` binds to its own entry — searching "firefox" in Discover, switching to Installed (empty query there), and returning to Discover restores "firefox". A dictionary in the model rather than per-view `@State` because switching sidebar sections destroys the detail view and its state with it.

**(v3) Command index**: after the catalog publishes, `AppModel` builds `commandIndex: [String: [Package.ID]]` (@concurrent, ~60k command names) from each formula's `commands`. Search consults it (below); the detail sheet just reads `package.commands`.

## Safety

Destructive operations are **unrepresentable**, not merely un-called:

```swift
enum BrewCommand: Equatable {
    case listFormulae         // ["list", "--formula", "--versions"]
    case listCasks            // ["list", "--cask", "--versions"]
    case outdated             // ["outdated", "--json=v2"]
    case update               // ["update"]
    case install(name: String, cask: Bool)   // ["install", "--formula"|"--cask", name]
    case upgrade(name: String, cask: Bool)   // ["upgrade", "--formula"|"--cask", name]
    case upgradeAll           // ["upgrade"]

    var arguments: [String] { ... }
    var isMutating: Bool { ... }   // update / install / upgrade / upgradeAll
}
```

- No `uninstall`, `remove`, `rm`, `cleanup`, `pin`, `unpin`, `zap`, or `--force` case exists anywhere.
- `BrewClient.run` accepts only a `BrewCommand`. There is no `run(arguments: [String])`.
- Explicit `--formula`/`--cask` on install/upgrade: the app already knows the kind from the catalog, so brew never has to disambiguate a name that exists as both (which it would resolve with a warning).
- `Process` execs the brew binary directly — no `/bin/sh -c`, so package names are single argv elements with no *shell* injection surface. Names only ever come from decoded catalog/outdated entries, never from a free text field; `enqueue` additionally rejects names starting with `-` so a hostile catalog entry can't be parsed by brew as a flag.
- Brew's *implicit* destruction — the periodic auto-cleanup that install/upgrade trigger by default — is switched off via `HOMEBREW_NO_INSTALL_CLEANUP=1` (see the environment list above). The whitelist covers what we ask brew to do; the env var covers what brew does unasked.
- `BrewCommandTests` asserts every case's argv: first token ∈ `{list, outdated, update, install, upgrade}`, no argv element matches `uninstall|remove|rm|cleanup|pin|zap|--force`, and install/upgrade carry the explicit kind token. A cheap tripwire against future regressions.

## BrewClient

**Discovery** (init, re-run on ⌘R): `FileManager.fileExists` at `/opt/homebrew/bin/brew`, then `/usr/local/bin/brew`. Neither → `AppModel.brewMissing = true`, whole window shows a `ContentUnavailableView` linking to brew.sh — so a user who installs Homebrew while the window is open recovers with a Refresh, no relaunch.

**Invocation** — one core method:

```swift
func run(_ command: BrewCommand,
         onLine: @MainActor @Sendable @escaping (String) -> Void) async throws -> Int32
```

- `Process` with `executableURL` = brew path, `arguments` = `command.arguments`.
- Environment: inherited + `HOMEBREW_NO_ENV_HINTS=1`, `HOMEBREW_NO_ASK=1`, `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_CLEANUP=1`; `SUDO_ASKPASS` when `command.isMutating`.
- stdout and stderr each get a `Pipe`; two child tasks iterate `fileHandleForReading.bytes.lines`, forwarding each line to `onLine`. (brew already prefixes `Error:` / `Warning:` — the log view tints those lines.)
- Exit is awaited via `terminationHandler` bridged into a `CheckedContinuation` — **never `waitUntilExit`**, which would block the main actor: the `@MainActor onLine` callbacks could then never run, the 64 KB pipe buffer fills, brew blocks on write, and nothing ever exits.
- Cancellation via `withTaskCancellationHandler`, `onCancel: { process.interrupt() }` — SIGINT, the Ctrl-C path brew actually traps and cleans up after (`brew.rb:22` maps it to exit 130). `terminate()` would send SIGTERM, which brew doesn't map and which skips its Interrupt cleanup. Exit 130, or an uncaught-signal exit while `Task.isCancelled`, → `.cancelled`.
- Read helpers accumulate lines and hand off to **static pure parsers** (`parseListVersions(String)`, `parseOutdated(Data)`) — testable without a `Process`.

**Operation queue** (in `AppModel`, which is MainActor — no locks needed):

```swift
var operations: [BrewOperation] = []       // session history, newest last
func enqueue(_ command: BrewCommand, title: String)
private func pump()   // if nothing running: run first queued op; on finish, refresh state, repeat
```

- Only mutating commands go through the queue; reads run directly and concurrently.
- Before the first mutating operation of the session, `enqueue(.update)` automatically.
- **Failure policy: continue.** A failed operation — including that session `brew update` when offline — is surfaced in the popover but does not drain or halt the queue; later queued operations still run.
- `BrewOperation.state`: `queued → running → succeeded | failed | cancelled`.
- Each operation's log is capped at 2,000 lines (drop oldest).
- After every mutating op finishes: re-run `listInstalled` + `outdated`, update the dictionaries — the UI flips cards automatically via `@Observable`.

**Askpass helper**: at launch, idempotently write to `Application Support/Brewery/askpass.sh` (chmod 0700):

```sh
#!/bin/sh
/usr/bin/osascript \
  -e 'display dialog "Brewery needs administrator access to continue." default answer "" with hidden answer with title "Brewery"' \
  -e 'text returned of result'
```

## Catalog pipeline

`CatalogStore`, plain struct. **Concurrency note that governs this whole doc**: the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and Approachable Concurrency (`NonisolatedNonsendingByDefault`), under which a plain `nonisolated async` function runs on its *caller's* actor — it does **not** hop off main. Anything that must actually leave the main thread is marked `@concurrent`. Here that's the download/decode entry point; everything else in the app is happily MainActor.

1. **Download** — `async let` all five files via `URLSession.shared`: `formula.json` + `cask.json` (~48 MB raw; decode peaks at a few × that), plus **(v3)** `internal/executables.txt` (~350 KB), `analytics/install/90d.json` (~2.4 MB) and `analytics/cask-install/homebrew-cask/90d.json` (~440 KB). All inside the `@concurrent` entry point, at most once a day — no streaming parser (YAGNI). 90d is the one analytics window we keep: 30d is noisy, 365d is stale, and one number per package is enough for "how popular is this".
2. **Decode & merge** — throwaway `Decodable` structs declaring only the needed keys; `JSONDecoder` ignores the rest. Cask `displayName` = first element of the cask's `name` array. **(v3)** `caveats`/`conflicts` come from the same catalog entries; `commands` joins `executables.txt` lines by formula name; `installs90d` joins the analytics files (strip commas from the string counts; formula items match by `formula` name, cask counts sit in the token-keyed dict). A failed download of any of the three small files degrades that field to nil/empty — the catalog itself never blocks on them.
3. **Cache** — `struct CatalogCache: Codable { let version: Int; let fetchedAt: Date; let packages: [Package] }` → atomic write to `Application Support/Brewery/catalog.json` (~8 MB with the v3 fields). **(v3)** `version` (now `3`) is the schema stamp: a mismatch — or a decode failure, which is what a pre-v3 cache without the field produces — is treated as "no cache" and triggers a fresh download, so schema migrations are free.
4. **Startup** (`AppModel.bootstrap()`): read cache → publish `catalog` immediately → fire `listInstalled`/`outdated` concurrently → if `fetchedAt` > 24 h old (or no cache), download/decode in background and swap `catalog` + rewrite the file. First-ever launch shows `ProgressView("Loading catalog…")` in Discover; Installed works meanwhile via synthesized packages.

## Fuzzy search

`FuzzySearch.swift` — pure functions:

```swift
struct SearchHit: Identifiable {                    // v3: rank returns hits, not bare packages,
    let package: Package                            // so cards can say WHY something matched
    let matchedCommand: String?                     // non-nil when the command index made the match
    var id: Package.ID { package.id }
}

static func score(query: String, candidate: String) -> Int?   // nil = no match
@concurrent static func rank(query: String, in packages: [Package],
                             commands: [String: [Package.ID]]) async -> [SearchHit]
```

(`@concurrent` for the same reason as `CatalogStore` — plain `nonisolated` would stay on the caller's actor.)

Case-insensitive; query lowercased once. Per package, score = max over `name`, `displayName`, and **(v3)** the command index:

| Match | Score |
|---|---|
| exact | 1000 |
| prefix | 900 − candidate length |
| **(v3)** query is exactly a provided command | 850 |
| word-boundary start (after `-` `_` `@` `.` space) | 700 − position |
| **(v3)** query (≥ 2 chars) is a prefix of a provided command | 600 − command length |
| substring anywhere | 500 − position |
| subsequence | 100 + contiguity bonus (adjacent matched pairs) |
| name misses entirely, `desc` contains query as substring | 40 |

Command-exact sits between prefix and word-boundary deliberately: someone typing `convert` almost certainly wants the tool that provides it (imagemagick), but a formula literally *named* what you typed still wins. When the winning score came from the command index, the hit carries `matchedCommand` and the card shows a "Provides `convert`" caption — without it, command matches look like false positives. Two mechanics: the index maps commands to the *whole catalog*, so a command hit only counts when its package is in the `packages` argument (Installed/Outdated pass their subset and must not surface strangers); and the browse path (empty query) wraps its packages in `SearchHit(matchedCommand: nil)` so the grid renders one type.

Tie-break: shorter name, then alphabetical. Search results capped at 200. An **empty query bypasses ranking entirely** and shows the full catalog, alphabetical, uncapped as *data* — rendering is windowed (v3, see Grid below).

Wiring — no Combine, no search actor:

```swift
.task(id: searchText) {
    guard (try? await Task.sleep(for: .milliseconds(120))) != nil else { return }  // debounce: sleep throws on retype → bail
    results = await FuzzySearch.rank(query: searchText, in: model.catalog, commands: model.commandIndex)
}
```

(The `guard` matters: a bare `try? await Task.sleep` swallows the cancellation and the stale task would rank — and assign — anyway.) Scoring 16k items should land in low single-digit milliseconds; step 3's verify includes measuring it, and `@concurrent` keeps even a slow case off the main actor.

## Icons

**(v3: `IconStore` replaces the v1 `AsyncImage` approach.)** Why the change — two field-observed defects, both structural to `AsyncImage`:

1. Grid cells cancel their `AsyncImage` load when scrolled away or re-diffed; the phase sticks at failure, so icons randomly miss in the grid yet appear after opening the detail sheet (whose load survives long enough to complete and warm `URLCache`). That's exactly the reported "loads on click, then grid shows it".
2. `URLCache` obeys response headers, so DuckDuckGo's `cache-control`-less 404s were re-fetched on every card appearance.

Design — one actor, keyed by **host** (many packages share a homepage host; deduping by host is a large win):

- `func icon(for host: String) async -> NSImage?` — checks, in order: memory `NSCache` → disk → network. The network fetch runs in a **shared task per host** (in-flight dedup); a view's cancellation abandons the *await*, never the fetch, so the result always lands in the cache and the next appearance is a hit. This alone fixes defect 1.
- **Disk**: `Application Support/Brewery/Icons/<host>` files (bytes as received; `NSImage` decodes `.ico`/`.png`). Two timestamps do two jobs: *birthtime* = fetch date, *mtime* = last access (touched on read). **Eviction is the user's "sliding window of bytes"**: after each write, if the directory exceeds **50 MB**, delete oldest-mtime files until under the cap — plain LRU, no index file, no database. (~2,000 icons of ~4 KB is ~8 MB; the cap is generous headroom, not a target.)
- **Refresh**: icons rarely change. If a disk hit's birthtime is older than **7 days**, serve the stale image immediately and re-fetch in the background — the grid never waits on a refresh.
- **Negative caching**: a 404 or undecodable body writes a zero-byte marker file with the same 7-day birthtime TTL — unknown domains cost one request a week instead of one per card appearance (closes v1's accepted network-chatter wart). The marker renders as the SF Symbol fallback, *not* DuckDuckGo's embedded globe: an empty file can't decode, so the globe-instead-of-fallback wart closes too, for free.
- **Fonts (v3)**: `isFont` packages never hit the store at all — foundry favicons are meaningless; they always render the `textformat` SF Symbol.
- `URLCache.shared` stays at its default size; icons no longer go through it.
- Fallback SF Symbols in a tinted rounded rect: formula → `terminal.fill`, cask → `macwindow`, font → `textformat`. The loading placeholder is the same symbol dimmed — no spinners in the grid.

Alternatives considered: keeping `URLCache` + retry-on-appear (doesn't fix cancellation, no negative caching, opaque eviction); SQLite/Core Data index (machinery for a problem file mtimes already solve).

## UI structure

- **Window**: single `WindowGroup`, `NavigationSplitView`. Sidebar: Discover (`sparkle.magnifyingglass`), Installed (`checkmark.circle`), Outdated (`arrow.triangle.2.circlepath`) with `.badge(outdatedCount)`. Stock components get Liquid Glass chrome for free.
- **Search**: `.searchable` on the detail column; Discover = full-catalog fuzzy, Installed/Outdated = fuzzy over that section's array. **(v3)** Each section binds to its own query in `AppModel.queries` — queries do not leak across tabs, and each tab's query survives switching away and back.
- **(v3) Counts**: `.navigationSubtitle` — the native macOS spot for this (Mail's message counts live there): browsing shows "16,223 packages" (Discover) / "309 installed" / "12 outdated"; an active search or filter shows "142 results" instead. Counts reflect what the current query + filters actually yield, not raw totals.
- **(v2) Filter controls**: Discover's toolbar gets a filter `Menu` (`line.3.horizontal.decrease.circle`, filled variant when any filter is active) holding the kind `Picker` and the "Hide deprecated" `Toggle`; Installed's toolbar gets the `On Request | All` scope `Picker` inline (two options don't need a menu).
- **Grid**: `LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))])`. Card: 44 pt icon, name (headline), status line (version; "1.2 → 1.3" in orange when outdated, cask comma-versions like `2.1.50,56f0a83` truncated at the comma for display; "deprecated" in red), 2-line description, **(v3)** a "Provides `<cmd>`" caption on command-matched search hits, trailing button — `Install` / `Update` (`.borderedProminent`) / checkmark (installed, disabled) / mini `ProgressView` (busy). `disabled` packages: button disabled with explanation in detail.
- **(v3) Windowed rendering**: clearing a search meant SwiftUI diffing and laying out ~16k card identities at once — a visible hitch. `LazyVGrid` is lazy about *rendering*, not about identity diffing. Fix: the grid renders `items.prefix(window)` with `window` starting at 300; a clear sentinel after the last card extends it by 300 via `onAppear`. `window` resets whenever the query, filters, or section change. **Pagination was considered and rejected**: page controls are a web idiom with no macOS precedent — every native catalog UI (App Store, Music) scrolls continuously; windowing gives the same continuous-scroll UX with a bounded initial layout, in ~10 lines of view-local state.
- **Detail**: `.sheet(item: $selectedPackage)` — App Store-like, keeps grid scroll position. Large icon, name + kind tag, version(s), deprecation/disabled banner, homepage `Link`, action button, and the package's latest operation log if any. **(v2)** Two more sections when installed: **Dependencies** — the receipt's installed runtime deps as tappable rows (icon, name, installed version; `declared_directly` ones sorted first); **Required by** — the inverted map's entries for this package (present for any depended-on item, which is also how a dependency-only item explains why it exists). Tapping a row swaps the sheet's `selectedPackage` in place — no navigation stack.
- **(v3) Detail additions**, each section rendered only when its data exists, in this order after the header (v2's Dependencies / Required by follow them):
  - **Installs** — a stat line under the version: "63,157 installs (90 days)", `chart.bar` symbol, count formatted with grouping separators.
  - **Caveats** — a `GroupBox` with `info.circle`, body text with `.textSelection(.enabled)` (caveats are full of paths and commands people copy); literal `$HOMEBREW_PREFIX` substituted with the real prefix at display time.
  - **Commands** — the formula's executables as selectable monospaced text, `·`-separated ("a2ps · card · fixps …"). A chip-flow layout was considered and rejected: a custom `Layout` for what is fundamentally a copyable word list.
  - **Conflicts with** — one row per `Conflict`: tappable name (swaps the sheet like dependency rows) + the reason as secondary text, e.g. "vim and macvim both install vi* binaries".
- **Operations popover** (Safari-downloads pattern): toolbar item shows a spinner + count while the queue is active; popover lists session operations with state icons — a Cancel button on the running one, a remove (✕) button on queued ones — each expandable into `OperationLogView` (monospaced, `defaultScrollAnchor(.bottom)`, `Error:`/`Warning:` tinted). Auto-presents once on failure.
- **Menu bar**: Refresh ⌘R (brew re-probe + installed + outdated + catalog staleness check), Upgrade All ⇧⌘U; Find (⌘F) focuses the search field via `.searchFocused` — wired explicitly rather than trusting the automatic ⌘F binding, which has historically been inconsistent on macOS.
- **Quit while a mutation runs**: `NSApplicationDelegateAdaptor` + `applicationShouldTerminate` shows a confirm dialog when an install/upgrade is running. On confirmed quit, the running brew gets `interrupt()` (the same SIGINT path as Cancel) and up to 5 s to exit; if it still hasn't (rare — brew traps INT), quit anyway and accept the orphan as the lesser evil versus a hung quit. Queued-but-unstarted operations are simply discarded.
- **Empty states**: `ContentUnavailableView.search` for no results; "Everything is up to date" in Outdated; full-window "Homebrew not found" with a brew.sh link; "Couldn't load catalog" + Retry when no cache and download failed.

## Project setting changes

1. `project.pbxproj`: `ENABLE_APP_SANDBOX = YES` → `NO` in **both** app-target configurations (Debug + Release). The app execs brew — impossible sandboxed. `ENABLE_HARDENED_RUNTIME = YES` stays. (Build settings are the only reason to touch the pbxproj; source files are picked up by the synced groups and must never be added by hand.)
2. Delete `Brewery/Item.swift`; strip SwiftData from `BreweryApp.swift`.
3. Update `CLAUDE.md`'s "SwiftUI + SwiftData" line.
4. Bundle metadata, in both app-target configurations, via `GENERATE_INFOPLIST_FILE`'s build settings rather than a checked-in plist: `INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.developer-tools` (a front end for a package manager is developer tooling) and `INFOPLIST_KEY_NSHumanReadableCopyright`. Everything else in the plist — identifier, versions, `LSMinimumSystemVersion`, `CFBundleIconName` — is derived from settings Xcode already sets.
5. Nothing else: no checked-in Info.plist, no entitlements file, no packages.

## Tests

Swift Testing, unit only — no UI tests in v1, no BrewClient integration tests (they'd depend on machine state).

- **FuzzySearchTests**: ordering exact > prefix > word-boundary > substring > subsequence; case-insensitivity; no-match → nil; desc-only match ranks below any name match; `"git"` ranks `git` above `gitless`/`gitui`; cask found by display name ("visual studio" → `visual-studio-code`).
- **ParsingTests**: `parseListVersions` — normal lines, multi-version lines (`python@3.12 3.12.1 3.12.4`), empty output, trailing newline. `parseOutdated` — fixture with formulae + casks incl. a pinned entry, empty arrays. Catalog slim-decode — inline fixture snippets copied from real `formula.json`/`cask.json` entries; unknown keys ignored; null `desc`/`homepage` ok.
- **BrewCommandTests**: exact argv per case + the destructive-token tripwire described in [Safety](#safety).
- **(v2) ReceiptTests**: fixture receipt JSONs — `installed_on_request` true/false/absent (absent → `false`, matching brew's `tab.rb`); `runtime_dependencies` extraction with a tap-qualified `full_name` normalized to its short name; cask receipt with object-shaped `runtime_dependencies` decodes without error and yields no deps; missing-file default (→ `onRequest: true`); dependents-map inversion on a three-package fixture.
- **(v3) CatalogV3Tests**: executables.txt line parsing (multi-command line, single, empty input); analytics count parsing (`"1,444,028"` → `1444028`; cask token-keyed dict shape); `Conflict` zipping incl. mismatched array lengths; caveats `$HOMEBREW_PREFIX` substitution; cache-version mismatch → treated as stale; `isFont` classification (`font-fira-code` yes, `firefox` no).
- **(v3) FuzzySearch additions**: exact command match ranks its provider above substring name matches but below a name-exact package; command hit carries `matchedCommand`; `≥ 2 chars` guard on command-prefix matching; font/cask/formula kind filtering composes with command hits (a command can only ever surface a formula).
- **(v3) IconStoreTests**: eviction as a pure function — given `[(name, size, mtime)]` and a cap, returns the files to delete (oldest-first, stops at cap); negative-marker freshness logic (fresh marker → no fetch, expired → fetch).

## Build order

Each step builds and is independently verifiable (`xcodebuild ... | xcbeautify` per `CLAUDE.md`):

1. **Skeleton** — sandbox off, SwiftData deleted, empty `AppModel`, sidebar with three placeholder sections. *Verify: builds, window looks native.*
2. **Catalog** — `Package`, `CatalogStore`, bootstrap; Discover grid with a plain `contains` filter. *Verify: ~16k packages render; second launch is instant from cache.*
3. **Search** — `FuzzySearch` + tests; debounced wiring. *Verify: tests pass; "wget" and "visual studio" find the right things.*
4. **Read state** — `BrewCommand` read cases, `BrewClient` + parsers + tests; Installed/Outdated sections; status on Discover cards. *Verify: matches `brew list` / `brew outdated` in Terminal.*
5. **Mutations** — mutating cases, `BrewOperation`, queue + pump, live logs, buttons, popover, post-op refresh, session `brew update`. *Verify: install a tiny formula (e.g. `cowsay`), watch the live log, card flips to installed.*
6. **Icons** — URLCache + `PackageIconView`. *Verify: favicons appear; offline relaunch still shows cached ones.*
7. **Polish** — detail sheet, askpass helper (verify with a pkg cask), menu commands, empty states, Upgrade All.
8. **v2: Filters & dependencies** — `Receipts.swift` + tests, `InstalledInfo` fields, dependents inversion, Discover filter menu, Installed scope picker, detail Dependencies/Required-by sections. *Verify: tests pass; Installed "On Request" matches `brew list --installed-on-request` in Terminal; a known dep (e.g. `ca-certificates`) shows its dependents and carries the "dependency" tag under All; kind filter + hide-deprecated visibly shrink Discover.*
9. **v3** — in sub-steps, each buildable:
   a. *Catalog v3*: `Package` fields + `Conflict`, five-file download/merge, cache `version`, command index. *Verify: tests pass; vim's detail data would show 3 conflicts with reasons; searching `convert` surfaces imagemagick with "Provides `convert`"; count matches `grep -c` of executables.txt for a known formula.*
   b. *Detail sections*: installs stat, caveats (prefix substituted — check php's), commands, conflicts. *Verify: vim shows caveats + conflicts; a font cask shows neither favicon fetch nor commands.*
   c. *Shell*: per-tab queries, `.navigationSubtitle` counts, windowed grid, Fonts filter. *Verify: search Discover, switch to Installed (empty), return (restored); clearing a 16k-item search no longer hitches; subtitle count equals visible count.*
   d. *IconStore*: store + tests, `PackageIconView` rewire. *Verify: cold launch, scroll fast — icons fill in without the "loads only after clicking" bug; relaunch offline — icons persist; `Icons/` dir stays under 50 MB.*

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| pkg-cask sudo hangs/fails with piped stdio | `SUDO_ASKPASS` osascript helper + `HOMEBREW_NO_ASK=1`; cancelled dialog fails fast with a readable log line; manually verified with a real pkg cask in step 7 |
| `HOMEBREW_NO_AUTO_UPDATE=1` → stale brew metadata (bottle 404s, older installs) | one automatic `brew update` per session before the first mutation; ⌘R for manual refresh |
| ~48 MB raw JSON decode (peak a few × that) | `@concurrent`, transient, ≤1×/day; slim ~8 MB cache makes normal launches instant; swappable inside `CatalogStore` if ever needed |
| Concurrent brew invocations (user runs brew in Terminal mid-operation) | brew's flock fails our op immediately with a readable error in the log — surfaced, not retried |
| *(v3)* `api/internal/executables.txt` is an undocumented endpoint and could move | its failure degrades to empty `commands` — catalog, search-by-name, everything else unaffected; brew's local cache copy is a known fallback if it ever dies for good |
| *(v3)* analytics counts join by name across 44,938 tap-inclusive entries | exact-name join; tap formulae simply don't match catalog names and drop out — no mis-attribution possible |
