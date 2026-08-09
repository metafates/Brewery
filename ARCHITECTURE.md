# Brewery — Architecture

A native macOS GUI for Homebrew. SwiftUI, macOS 26, zero third-party dependencies.

## Goals

1. Fast fuzzy search over the full Homebrew catalog (formulae + casks) to discover new packages.
2. Package icons: favicon of each package's homepage, with SF Symbol fallbacks.
3. Management of installed items — **v1 is non-destructive only**: install and upgrade (per item + upgrade all).
4. App Store-like cards; native macOS look per Apple HIG.
5. Simple, maintainable code. KISS and YAGNI throughout.

## Non-goals (v1)

- **No destructive brew commands.** No `uninstall`, `zap`, `cleanup`, `pin`/`unpin`, `--force`. Hard safety requirement — structurally enforced, see [Safety](#safety).
- No taps management, no services, no doctor, no dependency graphs.
- No analytics-based popularity ranking (the scorer already front-loads exact/prefix matches; revisit only if search feels bad in practice).
- No Settings pane, no multiple windows, no log persistence across launches.
- No App Store distribution (the app cannot be sandboxed — it execs `brew`).

## How Homebrew actually works (verified against brew 6.x source)

Facts below were verified by reading the Homebrew source (brew 6.x, `Library/Homebrew/...` paths cited). The design depends on them.

### Catalog data

- formulae.brew.sh serves full catalogs: `GET /api/formula.json` (~8.5k formulae, ~30 MB uncompressed) and `GET /api/cask.json` (~7.7k casks, ~17 MB uncompressed; both gzipped over the wire). Entries carry `name`/`token`, `desc`, `homepage`, `versions.stable`/`version`, `deprecated`, `disabled`, cask display `name` array, etc.
- brew 6.x's own local API cache (`~/Library/Caches/Homebrew/api/`) moved to an *internal* per-arch format (`internal/packages.<tag>.jws.json`, built in `api/internal.rb` — undocumented, machine-specific keys, not a public contract); the legacy `formula.jws.json`/`cask.jws.json` may exist on disk but are no longer refreshed. **Therefore the GUI downloads `formula.json`/`cask.json` from formulae.brew.sh itself** rather than parsing brew's cache.

### Installed state

- Formulae live in `$(brew --prefix)/Cellar/<name>/<version>/`, casks in `Caskroom/<token>/` (installed version derivable only via the `.metadata` glob — fiddly). Instead of walking directories, use brew's own fast paths:
  - `brew list --versions` and `brew list --cask --versions` — plain text `name v1 [v2...]` per line, implemented in pure Bash (`list.sh`), no Ruby startup, sub-second. (The `--json` variant requires `jq` — avoided.)
  - `brew outdated --json=v2` → `{"formulae":[{name, installed_versions[], current_version, pinned, pinned_version}], "casks":[...]}`. **Exits 0 even when items are outdated** (only exits 1 when given explicit names). <1 s with a warm cache. Cask `name` is the token; formula `name` is the full name.
- Prefix: probe `/opt/homebrew/bin/brew` (Apple silicon), then `/usr/local/bin/brew` (Intel). `brew --prefix` is canonical but we only need the binary path.

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

~14 Swift files, flat in `Brewery/`. Targets use filesystem-synchronized groups — **never edit `project.pbxproj` to add files**.

| File | Responsibility |
|---|---|
| `BreweryApp.swift` | `@main`, WindowGroup (min 900×600), menu `Commands` (Refresh ⌘R, Upgrade All ⇧⌘U), sets `URLCache.shared`, confirm-on-quit while a mutation runs |
| `AppModel.swift` | The single `@Observable` root: catalog, installed/outdated dictionaries, operation queue + pump, refresh orchestration, `status(for:)` merge |
| `Package.swift` | Pure data: `Package`, `PackageKind`, `InstalledInfo`, `OutdatedInfo`, `PackageStatus` |
| `BrewCommand.swift` | The safety whitelist enum — the only source of brew argv in the app |
| `BrewClient.swift` | brew binary discovery, `Process` exec with async line streaming, cancellation; static pure parsers for brew output |
| `BrewOperation.swift` | `@Observable` per-operation: command, state, capped live log buffer |
| `CatalogStore.swift` | download → slim-decode → cache file → `[Package]`; staleness check |
| `FuzzySearch.swift` | Pure scorer + `@concurrent` ranking |
| `ContentView.swift` | `NavigationSplitView` shell: sidebar, `.searchable`, operations popover, brew-missing state |
| `PackageGridView.swift` | `ScrollView` + `LazyVGrid` of cards, empty states |
| `PackageCardView.swift` | One card: icon, name, status line, description, action button |
| `PackageDetailView.swift` | Sheet: header, homepage link, warnings, action button, operation log |
| `PackageIconView.swift` | `AsyncImage` favicon with SF Symbol fallback |
| `OperationLogView.swift` | Monospaced auto-scrolling log for one operation |

Deleted from the template: `Item.swift`, the SwiftData `ModelContainer` boilerplate in `BreweryApp.swift`.

Tests in `BreweryTests/`: `FuzzySearchTests.swift`, `ParsingTests.swift`, `BrewCommandTests.swift` (Swift Testing — `@Test`/`#expect`).

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
    var id: String { "\(kind.rawValue):\(name)" }
}
```

Install-state overlays live in `AppModel`, keyed by `Package.ID`, never persisted (they're <1 s to re-query):

```swift
struct InstalledInfo { var versions: [String] }
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

Overlay refresh happens on launch, on ⌘R, and after every mutating operation completes (success or failure).

## Safety

Destructive operations are **unrepresentable**, not merely un-called:

```swift
enum BrewCommand: Equatable {
    case listFormulae         // ["list", "--versions"]
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

1. **Download** — `async let` both `https://formulae.brew.sh/api/formula.json` and `.../cask.json` via `URLSession.shared`. ~48 MB of raw JSON held transiently (decode peaks at a few × that), inside the `@concurrent` entry point, at most once a day — no streaming parser (YAGNI; isolated inside `CatalogStore` if it ever needs one).
2. **Decode** — throwaway `Decodable` structs declaring only the needed keys; `JSONDecoder` ignores the rest. Cask `displayName` = first element of the cask's `name` array.
3. **Cache** — `struct CatalogCache: Codable { let fetchedAt: Date; let packages: [Package] }` → atomic write to `Application Support/Brewery/catalog.json` (~5 MB).
4. **Startup** (`AppModel.bootstrap()`): read cache → publish `catalog` immediately → fire `listInstalled`/`outdated` concurrently → if `fetchedAt` > 24 h old (or no cache), download/decode in background and swap `catalog` + rewrite the file. First-ever launch shows `ProgressView("Loading catalog…")` in Discover; Installed works meanwhile via synthesized packages.

## Fuzzy search

`FuzzySearch.swift` — pure functions:

```swift
static func score(query: String, candidate: String) -> Int?   // nil = no match
@concurrent static func rank(query: String, in packages: [Package]) async -> [Package]
```

(`@concurrent` for the same reason as `CatalogStore` — plain `nonisolated` would stay on the caller's actor.)

Case-insensitive; query lowercased once. Per package, score = max over `name` and `displayName`:

| Match | Score |
|---|---|
| exact | 1000 |
| prefix | 900 − candidate length |
| word-boundary start (after `-` `_` `@` `.` space) | 700 − position |
| substring anywhere | 500 − position |
| subsequence | 100 + contiguity bonus (adjacent matched pairs) |
| name misses entirely, `desc` contains query as substring | 40 |

Tie-break: shorter name, then alphabetical. Search results capped at 200. An **empty query bypasses ranking entirely** and shows the full catalog, alphabetical, uncapped (the grid is lazy).

Wiring — no Combine, no search actor:

```swift
.task(id: searchText) {
    guard (try? await Task.sleep(for: .milliseconds(120))) != nil else { return }  // debounce: sleep throws on retype → bail
    results = await FuzzySearch.rank(query: searchText, in: model.catalog)
}
```

(The `guard` matters: a bare `try? await Task.sleep` swallows the cancellation and the stale task would rank — and assign — anyway.) Scoring 16k items should land in low single-digit milliseconds; step 3's verify includes measuring it, and `@concurrent` keeps even a slow case off the main actor.

## Icons

- URL: `URL(string: homepage)?.host` → `https://icons.duckduckgo.com/ip3/<host>.ico`. No homepage / no host → fallback symbol.
- **Plain `AsyncImage`** — no custom loader. `BreweryApp.init` sets `URLCache.shared = URLCache(memoryCapacity: 50 MB, diskCapacity: 256 MB)` so favicons cache across launches per HTTP headers. `NSImage` decodes `.ico`.
- Fallback SF Symbols in a tinted rounded rect: formula → `terminal.fill`, cask → `macwindow`. The loading placeholder is the same symbol dimmed — no spinners in the grid.
- Accepted imperfection: for unknown domains DuckDuckGo answers HTTP 404 *with* a placeholder-globe icon as the body (verified live), so some packages may show a generic globe instead of our fallback symbol — and since those 404s carry no `cache-control`, URLCache won't store them and each card appearance re-fetches. Not cheaply detectable, network chatter only, fine for v1.

## UI structure

- **Window**: single `WindowGroup`, `NavigationSplitView`. Sidebar: Discover (`sparkle.magnifyingglass`), Installed (`checkmark.circle`), Outdated (`arrow.triangle.2.circlepath`) with `.badge(outdatedCount)`. Stock components get Liquid Glass chrome for free.
- **Search**: `.searchable` on the detail column; Discover = full-catalog fuzzy, Installed/Outdated = fuzzy over that section's array.
- **Grid**: `LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))])`. Card: 44 pt icon, name (headline), status line (version; "1.2 → 1.3" in orange when outdated, cask comma-versions like `2.1.50,56f0a83` truncated at the comma for display; "deprecated" in red), 2-line description, trailing button — `Install` / `Update` (`.borderedProminent`) / checkmark (installed, disabled) / mini `ProgressView` (busy). `disabled` packages: button disabled with explanation in detail.
- **Detail**: `.sheet(item: $selectedPackage)` — App Store-like, keeps grid scroll position. Large icon, name + kind tag, version(s), deprecation/disabled banner, homepage `Link`, action button, and the package's latest operation log if any.
- **Operations popover** (Safari-downloads pattern): toolbar item shows a spinner + count while the queue is active; popover lists session operations with state icons — a Cancel button on the running one, a remove (✕) button on queued ones — each expandable into `OperationLogView` (monospaced, `defaultScrollAnchor(.bottom)`, `Error:`/`Warning:` tinted). Auto-presents once on failure.
- **Menu bar**: Refresh ⌘R (brew re-probe + installed + outdated + catalog staleness check), Upgrade All ⇧⌘U; Find (⌘F) focuses the search field via `.searchFocused` — wired explicitly rather than trusting the automatic ⌘F binding, which has historically been inconsistent on macOS.
- **Quit while a mutation runs**: `NSApplicationDelegateAdaptor` + `applicationShouldTerminate` shows a confirm dialog when an install/upgrade is running. On confirmed quit, the running brew gets `interrupt()` (the same SIGINT path as Cancel) and up to 5 s to exit; if it still hasn't (rare — brew traps INT), quit anyway and accept the orphan as the lesser evil versus a hung quit. Queued-but-unstarted operations are simply discarded.
- **Empty states**: `ContentUnavailableView.search` for no results; "Everything is up to date" in Outdated; full-window "Homebrew not found" with a brew.sh link; "Couldn't load catalog" + Retry when no cache and download failed.

## Project setting changes

1. `project.pbxproj`: `ENABLE_APP_SANDBOX = YES` → `NO` in **both** app-target configurations (Debug + Release). The app execs brew — impossible sandboxed. `ENABLE_HARDENED_RUNTIME = YES` stays. (This is the only pbxproj edit ever needed; source files are picked up by the synced groups.)
2. Delete `Brewery/Item.swift`; strip SwiftData from `BreweryApp.swift`.
3. Update `CLAUDE.md`'s "SwiftUI + SwiftData" line.
4. Nothing else: no Info.plist keys, no entitlements file, no packages.

## Tests

Swift Testing, unit only — no UI tests in v1, no BrewClient integration tests (they'd depend on machine state).

- **FuzzySearchTests**: ordering exact > prefix > word-boundary > substring > subsequence; case-insensitivity; no-match → nil; desc-only match ranks below any name match; `"git"` ranks `git` above `gitless`/`gitui`; cask found by display name ("visual studio" → `visual-studio-code`).
- **ParsingTests**: `parseListVersions` — normal lines, multi-version lines (`python@3.12 3.12.1 3.12.4`), empty output, trailing newline. `parseOutdated` — fixture with formulae + casks incl. a pinned entry, empty arrays. Catalog slim-decode — inline fixture snippets copied from real `formula.json`/`cask.json` entries; unknown keys ignored; null `desc`/`homepage` ok.
- **BrewCommandTests**: exact argv per case + the destructive-token tripwire described in [Safety](#safety).

## Build order

Each step builds and is independently verifiable (`xcodebuild ... | xcbeautify` per `CLAUDE.md`):

1. **Skeleton** — sandbox off, SwiftData deleted, empty `AppModel`, sidebar with three placeholder sections. *Verify: builds, window looks native.*
2. **Catalog** — `Package`, `CatalogStore`, bootstrap; Discover grid with a plain `contains` filter. *Verify: ~16k packages render; second launch is instant from cache.*
3. **Search** — `FuzzySearch` + tests; debounced wiring. *Verify: tests pass; "wget" and "visual studio" find the right things.*
4. **Read state** — `BrewCommand` read cases, `BrewClient` + parsers + tests; Installed/Outdated sections; status on Discover cards. *Verify: matches `brew list` / `brew outdated` in Terminal.*
5. **Mutations** — mutating cases, `BrewOperation`, queue + pump, live logs, buttons, popover, post-op refresh, session `brew update`. *Verify: install a tiny formula (e.g. `cowsay`), watch the live log, card flips to installed.*
6. **Icons** — URLCache + `PackageIconView`. *Verify: favicons appear; offline relaunch still shows cached ones.*
7. **Polish** — detail sheet, askpass helper (verify with a pkg cask), menu commands, empty states, Upgrade All.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| pkg-cask sudo hangs/fails with piped stdio | `SUDO_ASKPASS` osascript helper + `HOMEBREW_NO_ASK=1`; cancelled dialog fails fast with a readable log line; manually verified with a real pkg cask in step 7 |
| `HOMEBREW_NO_AUTO_UPDATE=1` → stale brew metadata (bottle 404s, older installs) | one automatic `brew update` per session before the first mutation; ⌘R for manual refresh |
| ~48 MB raw JSON decode (peak a few × that) | `@concurrent`, transient, ≤1×/day; slim 5 MB cache makes normal launches instant; swappable inside `CatalogStore` if ever needed |
| Concurrent brew invocations (user runs brew in Terminal mid-operation) | brew's flock fails our op immediately with a readable error in the log — surfaced, not retried |
