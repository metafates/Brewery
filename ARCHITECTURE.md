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
8. **(v4)** Taps overhaul: packages from installed third-party taps join the catalog (local scan, zero subprocesses) and are searchable in Discover; every item answers "which tap is this from"; install/upgrade pass tap-qualified names, which is also what brew 6.x's tap-trust gate requires; all with **zero performance regression** — taps ride in as metadata, the join rule, safety whitelist and every hot path stay untouched.
9. **(v5)** Services: a Services section (System Settings › Login Items composition — icon, name, info line, trailing toggle) listing every installed formula's background service with live status; start/stop through the operation queue; the catalog's `service` block rendered as human-readable description (command, schedule, ports, logs) in the detail sheet. The whitelist grows by exactly three cases; brew's destructive service verbs stay unrepresentable.

## Non-goals (v1)

- **No destructive brew commands.** No `uninstall`, `zap`, `cleanup`, `pin`/`unpin`, `--force`. Hard safety requirement — structurally enforced, see [Safety](#safety).
- **(v6)** Taps are managed — but only `tap` and `untap`: no `--force` (it uninstalls the tap's packages), no `--custom-remote` (silently repoints an existing tap at an arbitrary URL), no `--repair`/`--eval-all`. Trust gains exactly one guarded write — `trust --tap <name>`, offered only inside the untrusted-tap banner behind a confirmation that states what trusting means; `untrust --tap` rides the context menu of explicitly-trusted rows (privilege-reducing, hence no dialog — the tap page banner offers the way back); brew's install-time auto-trust remains disclosed per item. **(v5)** Services are managed — but only `start`/`stop`: no `kill`, no `cleanup` (deletes plists), no `restart`/`run`, no root services, no `--file`. No doctor. No dependency *graph visualization* — v2 shows flat dependency/dependent lists from install receipts, nothing more.
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
- **(v3) Analytics**: `GET /api/analytics/install/90d.json` (2.4 MB, ~32k items incl. tap formulae) → `{"items":[{"formula": "openssl@3", "count": "1,444,028", …}]}` — **counts are comma-formatted strings**. Casks: `GET /api/analytics/cask-install/homebrew-cask/90d.json` (440 KB) → keyed `{"formulae": {"<token>": [{"cask": "<token>", "count": "868"}]}}` — the top-level key really is `formulae` (historical misnaming) and it's a dict, not an array. Both verified live.

### Taps (v4)

Verified against brew 6.x source and live probes on a machine with five third-party taps:

- **Location**: `<brew repository>/Library/Taps/<user>/homebrew-<repo>` — the *repository*, not the prefix (they differ on Intel: prefix `/usr/local`, repository `/usr/local/Homebrew`; `bin/brew:83-108`). The repository is `realpath(brew binary)/../..` — the same derivation `bin/brew` uses. **The directory listing is the tap list**: `brew tap` with no args is a pure-bash iteration of exactly this directory (`tap.sh`, 0.02 s) — so the GUI never needs a subprocess to enumerate taps. Tap name = lowercased `<user>/<repo minus the homebrew- prefix>` (`tap.rb:293-303`).
- **Formula discovery** (`tap.rb:954-1031`): the formula dir is the **first existing** of `Formula/`, `HomebrewFormula/`, tap root — never a union; globbed recursively in the first two (third-party sharding is allowed; letter-sharding is a core-tap convention), **top level only** at root, so commands/casks aren't misread. Casks: always `Casks/**`. Duplicate basenames: longer path wins. Confirmed locally: charmbracelet/tap keeps `.rb` at the repo root; most taps use `Formula/`.
- **Naming across brew commands**: `brew list --formula --versions` prints **short** keg names for tap items (the rack basename, `cmd/list.rb:307-312`; `--full-name` conflicts with `--versions`). `brew outdated --json=v2` reports formulae by tap-qualified `full_name` but casks by short token (`cmd/outdated.rb:196-216`). Both already pass through `shortName` normalization — **the v1 join rule survives taps unchanged**.
- **Resolution order** (`formulary.rb:1230-1248`): the API loader precedes tap loaders, so a bare short name *always* resolves to homebrew/core when core has it — verified live: `glow` → core even though charmbracelet/tap ships one and it was installed from there. **Qualified names are therefore mandatory** for anything tap-scoped. Hazard: a qualified name whose tap is *not installed* makes brew clone the tap on demand (`cmd/install.rb:195-203`) — an implicit mutation the GUI must guard against (see the stale-receipt rule below).
- **Trust gate (brew 6.x)**: `HOMEBREW_REQUIRE_TAP_TRUST` defaults **on** (`env_config.rb:654`). Loading an untrusted tap's formula raises unless the fully-qualified name appears verbatim in argv (`trust.rb:560-570`), and `install`/`upgrade` with qualified names **auto-trust the item persistently** (`cmd/install.rb:204`, `trust.rb:116-145` — a durable write to `~/.config/homebrew/trust.json`). Flip side: `Formula.installed` swallows load errors (`formula.rb:2649-2655`), so an installed formula from an *untrusted* tap **silently vanishes from `brew outdated`** — it looks up to date and Upgrade All skips it.
- **Receipts name the tap**: `INSTALL_RECEIPT.json` → `source.tap` for formulae *and* casks (verified: `"homebrew/core"`, `"charmbracelet/tap"`). The v2 receipt sweep already reads these files, so the true origin of every installed item is one already-paid-for field away.
- **Tap formula metadata without Ruby**: the DSL stanzas `desc "…"`, `homepage "…"`, `version "…"`, `license "…"` and `deprecate!`/`disable!` are line-anchored string literals a regex can extract. `version` is frequently *implicit* (derived from `url` by `Version.detect`'s dozens of heuristics — not reimplementable); licenses can be non-string expressions (`avr-gcc@14`). Extraction is therefore best-effort by design: absent version shows as absent. Cask stanzas are the same shapes.
- **Remotes**: each tap's upstream is `remote.origin.url` in its `.git/config` — default scheme `https://github.com/<user>/homebrew-<repo>` (`tap.rb:406-410`) but custom remotes are supported, so *read* it (handling `.git` suffixes and `git@github.com:` SSH form), never assume.
- **Analytics cover taps**: `install/90d.json` keys tap formulae by qualified name (`oven-sh/bun/bun`) among its ~32k entries — real install counts are available for tap packages via a dictionary lookup.
- A core tap kept as a **git clone** (`homebrew/homebrew-cask` here, 7.7k files with sharded `Casks/<letter>/`) must be excluded from scanning — the API catalog already covers it, and scanning it would double every cask.
- Rejected: `brew tap-info --json` on any hot path (per-tap GitHub API calls + git shell-outs, 1.2 s for 7 taps); the descriptions cache (`~/Library/Caches/Homebrew/descriptions.json` — trusted-taps-only, desc-only, best-effort); batch `brew info --json=v2` enrichment (~0.3 s per invocation — revisit only if regex fallback quality feels bad in practice).

### Services (v5)

Verified against brew 6.x source and live probes (six service formulae installed here):

- `brew services` is merged into brew core (`Library/Homebrew/services/`, dispatcher `cmd/services.rb`). Eight subcommands **with aliases accepted verbatim** (`stop` = `unload`/`terminate`/`term`/`t`/`u`, `cleanup` = `clean`/`cl`/`rm`, …) — the whitelist emits canonical tokens only and never grows the dangerous verbs.
- **`start` vs `run`** (`services/cli.rb:95-162`): `start` copies the plist into `~/Library/LaunchAgents` + `launchctl enable` + bootstrap — a login item; `run` bootstraps the keg's plist only — dies at logout. v5 exposes `start`/`stop` only; a toggle is a persistence statement, and that is `start`.
- **`stop` deletes the registered plist** (`cli.rb:242`) — that is brew's own inverse of `start`, fully reversible; `--keep` exists but is not needed.
- **Sharp edges, all unrepresentable here**: `cleanup` (kills orphans + deletes plists), `kill`, `--file=` (loads an arbitrary plist), `--sudo-service-user` (root-only), and running services commands as root at all (`take_root_ownership?`, `cli.rb:288-352`, chowns the keg to root).
- **`brew services` never invokes sudo** (verified: no `sudo: true` caller in the tree) — it cannot hang on a password prompt with piped stdio. A `require_root: true` formula started as a user *warns on stderr and proceeds* (`cli.rb:378-383`), then typically fails at runtime → `status: "error"`. So the GUI disables the toggle for `require_root` services instead of offering a start that lies.
- **`brew services list --json`** → array of exactly `{name, status, user, file, exit_code}` (`subcommand/list.rb:42`); `status` ∈ `started · stopped · none · scheduled · error · unknown · other` (`formula_wrapper.rb:322-340`). ~0.5 s measured (Ruby boot + `Formula.installed`) — the `brew outdated` cost class, run concurrently in `refreshState`, never on a render path. `file` can point at the keg's template plist, not the registered one — status is the source of truth.
- **Exit codes lie**: "Service `x` is not started." warns and exits 0 (`cli.rb:190`). Statuses are re-read after every mutation — the post-operation `refreshState` already does exactly that.
- The formula API's **`service` block** (`service.rb:715-767`, `.compact_blank` — absent key = default): `run` (string *or* array), `run_type` ∈ `immediate`/`interval`/`cron`, `interval`, `cron`, `keep_alive` (object of booleans), `require_root`, `working_dir`, `log_path`, `error_log_path`, `sockets` (`tcp://host:port` strings), `environment_variables`, more. Paths embed `$HOMEBREW_PREFIX` — the caveats substitution already handles that.
- Services never trigger brew auto-update (`utils/auto-update.sh:144-155` — `services` absent from the trigger list). `HOMEBREW_SERVICES_NO_DOMAIN_WARNING=1` silences a stderr domain warning that fires when uid≠euid — set on every invocation.
- **Trust gate**: `services list` uses `Formula.installed`, whose bare `rescue` silently drops untrusted-tap formulae (`formula.rb:2648-2655`) — their services vanish from the list with exit 0. Accepted: Brewery-installed tap items are auto-trusted; the residual gap is documented in Risks.

### Taps management (v6)

Verified against brew 6.x source and live probes:

- **`brew tap user/repo` cannot hang and cannot surprise.** One-arg form always clones `https://github.com/user/homebrew-repo` over HTTPS (`tap.rb:408-410`); brew itself sets `GIT_TERMINAL_PROMPT=0`; and brew 6 has **no interactive prompt anywhere** — `Ask.confirm?` short-circuits to false on non-TTY stdio (`ask.rb:13`), so piped invocations can never block. Progress (`==> Tapping…`, `Tapped N formulae`) goes to **stderr**. Already tapped → silent exit 0 (indistinguishable from success by code — the post-op rescan is the truth). Invalid name / unreachable repo / network failure → exit 1 with a readable error; brew removes partial clones itself. `brew tap` with args is on the auto-update trigger list (`auto-update.sh:151-152`) — the standing `HOMEBREW_NO_AUTO_UPDATE=1` covers it. Tapping **never writes trust**: the tap arrives untrusted, and untrusted formulae are never evaluated (the description-cache pass rescues `UntrustedTapError` before eval, `description_cache_store.rb:89`).
- **`brew untap user/repo` is self-guarding on piped stdio.** With installed packages from the tap it prints "Refusing to untap…" and exits 1 having deleted nothing (`cmd/untap.rb:60-66` + `ask.rb:13`). Plain untap deletes the clone, manpage/completion symlinks and description-cache entries (`tap.rb:869-909`). **Trust entries survive untap** and silently reapply on re-tap — disclosed in the removal dialog. `untap --force` uninstalls the tap's kegs and casks first — destructive, unrepresentable here.
- **Trust store**: `~/.config/homebrew/trust.json` (XDG), atomic writes → safe to read directly; keys `trustedtaps`/`trustedformulae`/`trustedcasks`/`trustedcommands`, values lowercased. Entries are `user/repo` **only for default-GitHub-remote taps**; custom-remote taps store normalized URLs, so the reader tolerates URL-shaped entries and treats anything unmatched as untrusted. Official taps are implicitly trusted and never stored (`tap.rb:1489-1491`). Partial trust = any item entry prefixed `tap/` (`trust.rb:290-295`).
- **Cheap per-tap signals**: `.git/FETCH_HEAD` mtime = "last checked" (`brew update` touches it per tap, `cmd/update.sh:905`); contents counts come from the v4 scan; the remote from the already-parsed `.git/config`. `brew tap-info` is a trap — a GitHub API call per non-core tap plus formula eval — and is never used.

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
- The cask receipt's `uninstall_artifacts` also names the `.app` bundles the cask put on disk (`[{"app": ["Firefox.app"]}, {"binary": […]}, {"zap": […]}]` — heterogeneous, so only the `app` entries are read). That is the source for the detail sheet's **Open**: local, already being read, correct for third-party taps, and describing what was actually installed rather than what the catalog claims. Verified live: 22 of 44 installed casks name an app; fonts and CLI-only casks name none.
- Cross-check for free: `brew list --installed-on-request` exists (`cmd/list.rb:43`, Ruby path) — used only as a build-step verify, not at runtime.

### Driving brew from a GUI

- **Environment** (set on every invocation):
  - `HOMEBREW_NO_ENV_HINTS=1` — silences hint noise on stderr.
  - `HOMEBREW_NO_ASK=1` — belt-and-braces; brew's ask-mode already auto-skips prompts when stdio is not a TTY (`ask.rb`: `return false if !$stdin.tty?`).
  - `HOMEBREW_NO_AUTO_UPDATE=1` — skips both the git auto-update *and* the API refresh. Critical for two reasons: read commands stay fast, and the auto-update path `exec`s a fresh brew process mid-run (`utils/auto-update.sh`), which would restart our output stream.
  - `HOMEBREW_NO_INSTALL_CLEANUP=1` — **part of the non-destructive guarantee.** By default `brew install`/`upgrade` auto-clean old kegs of the touched formula and, every `HOMEBREW_CLEANUP_PERIODIC_FULL_DAYS` (30) days, run a *full* cleanup of all formulae and caches (`env_config.rb:586`). The command whitelist alone doesn't prevent that; this env var does.
  - `SUDO_ASKPASS=<helper>` on mutating commands (see below).
- **User config can override us**: `bin/brew` loads `brew.env` files (`/etc/homebrew/brew.env`, `$PREFIX/etc/homebrew/brew.env`, `~/.homebrew/brew.env` or XDG) and exports any `HOMEBREW_*`/`SUDO_ASKPASS` line, protecting only variables `bin/brew` itself sets — so a user's `brew.env` beats the env we pass. Treat our env vars as defaults, not invariants; behavioral claims below carry that asterisk.
- **Freshness (v8 — the one rule)**: with auto-update disabled, brew's metadata drifts — and `brew outdated` **computes against that frozen cache**, so the Outdated section could claim "everything is up to date" for days while a terminal `brew outdated` (whose auto-update runs) disagreed. v1–v7's mitigation (one `brew update` per session, before the first mutation) never fired in browse-only sessions and ⌘R only re-read state *through* the stale cache. The v8 rule: **before the app reads `outdated` (launch, ⌘R) or mutates packages, brew's API metadata must be no older than brew's own refresh window — 450 s (`HOMEBREW_API_AUTO_UPDATE_SECS` default, `env_config.rb:57`) — else an explicit `brew update` runs first.** See *Metadata freshness (v8)* below for the verified mechanics. (An *explicit* `brew update` is not gated by `HOMEBREW_NO_AUTO_UPDATE` — only the auto-update path checks it: `utils/auto-update.sh` gates on it, and `cmd/update.sh`/`utils/api.sh` never read it — so it refreshes brew's git taps and API cache even with our env set.) `⌘R` also re-runs the catalog staleness check (downloading if older than 24 h).
- **Sudo (pkg casks)**: cask `pkg` artifacts (and a few others) invoke `sudo`. With piped stdio sudo has no TTY and fails/hangs — unless `SUDO_ASKPASS` points to an executable, in which case brew adds `-A` itself (`system_command.rb`). We ship a tiny osascript helper (written to Application Support at launch, chmod 0700). If the user cancels the dialog, sudo fails fast and the operation logs a readable `Error:` line. A wrong password makes sudo re-invoke the helper up to its retry limit — the same dialog just reappears, with no error context; accepted.
- **Concurrency**: mutating commands take non-blocking flocks in `var/homebrew/locks/` — a second concurrent mutation errors immediately (`OperationInProgressError`) rather than queueing. **The GUI serializes all mutating operations in a FIFO queue, one at a time.** Read commands are safe to run concurrently.
- **Exit codes**: 0 ok, 1 failure (no finer taxonomy — stderr carries `Error:`/`Warning:` lines), 130 on SIGINT.
- **Output**: pipes are not TTYs, so brew emits no color by default (and passes `--silent` to curl, so no progress spam). The log view still strips ANSI escapes — one regex — because a user `brew.env` can force `HOMEBREW_COLOR=1`.
- **`brew install X`** on an installed-but-outdated `X` acts as an upgrade — unless the user's `brew.env` sets `HOMEBREW_NO_INSTALL_UPGRADE` (`cmd/install.rb:32`), in which case it's a no-op with a notice. Acceptable either way: both actions are on the safe list.

### Metadata freshness (v8)

The bug this fixes: Outdated said "everything is up to date"; `brew outdated` in a terminal then listed 23 formulae and 4 casks — and only *after* that terminal run did the app's next refresh agree, because the terminal's auto-update had rewritten the cache the app reads through.

**Verified facts (brew 6.x source):**

- `brew outdated` is on the auto-update trigger list (`utils/auto-update.sh:150-156`: `install outdated upgrade bundle release`), and for those commands the Ruby side refreshes the API payload when it is older than **450 s** (`api.rb fetch_api_files!` → `Homebrew::EnvConfig.api_auto_update_secs`, default `env_config.rb:57`). That is the freshness a terminal `brew outdated` guarantees — and the parity target.
- Under `HOMEBREW_NO_AUTO_UPDATE` the Ruby gate passes `stale_seconds: nil` and `skip_download?` then returns true whenever the cached payload exists (`api.rb:209-221`, `:51-57`) — the cache is **never** refreshed, at any age.
- brew 6 answers everything from one internal payload per arch: `$HOMEBREW_CACHE/api/internal/packages.<tag>.jws.json` (`api/internal.rb:30-31,65-66`). `HOMEBREW_CACHE` defaults to `~/Library/Caches/Homebrew` on macOS (`utils/os.sh:55`); the GUI resolves it the same way brew will for the processes *it* spawns — inherited env override first, else the default.
- brew touches the payload's mtime **only after a successful download or revalidation** (`api.rb:141-146` — "touching after a failed download would mark a stale cache as fresh"). So the file's mtime *is* "when metadata was last known good", terminal and GUI runs alike, and a failed update stays honestly stale.
- `brew update` holds a non-blocking exclusive flock (`cmd/update.sh:679` → `lock update`, `utils/lock.sh` `LOCK_EX | LOCK_NB`): two concurrent updates means the second **errors immediately** rather than waiting.

**The rule, mechanically** (all in `AppModel`, thresholds in `BrewClient`):

- *Staleness*: newest mtime among `api/internal/packages.*.jws.json` older than 450 s, or no payload at all. Re-stat'd on every `refreshState()` — a terminal-side `brew update` therefore counts, and the app skips a redundant one (the cheapest fix for the reported scenario is noticing someone else already did the work).
- *Launch* (`bootstrap`): probes run **first** — cached-metadata answers on screen in ~1 s (HIG *Loading*: "show something as soon as possible") — then, if stale, one inline `.update` runs and the probes re-run. The page corrects itself a few seconds in, non-modally.
- *⌘R* (`refresh`): if stale, the inline `.update` runs **before** the probes — one landing, no flicker — under the existing `isRefreshing` veil, whose capsule already says "Checking for updates…" and now means it. A ⌘R inside the window stays the ~1 s it is today.
- *Mutations* (`enqueue`): the once-per-session update becomes staleness-gated — a package mutation injects "Updating Homebrew" ahead of itself only when metadata is actually stale and no update is already pending or in flight. Long-running sessions stop drifting (the old flag updated once and never again); installs right after a fresh check stop paying ~5 s for a no-op.
- *Serialization*: the inline check is the one mutating argv that runs **outside** the operation queue — and while it runs, `pump()` holds, so a mutation enqueued mid-check starts right after it with fresh metadata, and the flock above can never bite. The whitelist is untouched: `.update` already existed, takes no arguments.
- *Failure is silent*: offline, the probes fall back to the cached answer — exactly the pre-v8 behavior — with no failure popover; an in-app attempt timestamp backs off retries to one per window, so an offline ⌘R is slow once, not every time. (The inline check may briefly outlive a quit as an orphaned `brew update`; harmless, it's what any terminal update is.)

**UI** (HIG *Feedback*: "consider integrating status feedback into your interface"; *Progress indicators*, macOS: a spinner for a background operation, with a description where helpful — Software Update's own grammar):

- The Outdated page gets a footnote caption in the grid's header slot — the v6 scrolls-with-content pattern — showing "Checking for updates…" beside a small spinner while a check runs, else "Last checked *n* ago" (the answer to "is this stale?" without opening a terminal). **(v8.1)** The caption ticks every *second* but reads at *minute* granularity — "just now" under a minute, then the formatter's "1 minute ago" (HIG *Progress indicators*: keep indicators moving so people know something is continuing to happen). The first cut used `.everyMinute`, which proved wrong twice: its ticks are wall-clock minute boundaries, not anchored to the mtime, so the unit flip landed up to a minute late (and a minute-floor tick can *predate* a fresh mtime, phrasing the past as "in 30 seconds" — the bucketing clamps this and `FreshnessCaptionTests` pins it); and on macOS the schedule empirically failed to fire at all, the caption sitting frozen ("does not update in real time"). Per-second `.periodic` costs one string compare a second; the Text redraws only when the unit flips.
- While the section is **empty** and a check is running, the empty state shows a centered spinner + "Checking for updates…" instead of claiming "Everything is up to date" — the claim was the lie the bug report caught. One status element per state: the veil covers ⌘R, the centered spinner covers empty-and-checking, the caption covers the rest. **(v8.1)** "A check is running" includes the *re-probe*: at launch, `isCheckingForUpdates` stays up from the inline update through the follow-up `refreshState()`, because the moment the update finished the empty state briefly reclaimed "Everything is up to date" while the fresh outdated read was still in flight — a one-second recurrence of the exact lie. The held pump costs a queued mutation only that probe's second.
- **(v8.1)** The refresh veil *disables* the content it recedes (`.disabled`, so cards leave the Tab order, not just the pointer's reach): blurred-past-legibility content that still took clicks selected cards through the veil. What it looks like and what it does have to agree. The lock is per-pane, never app-wide — sidebar, toolbar, search and menu commands stay live (HIG *Loading*: "let people do other things … while they wait").

## File layout

~18 Swift files, flat in `Brewery/`. Targets use filesystem-synchronized groups — **never edit `project.pbxproj` to add files**.

| File | Responsibility |
|---|---|
| `BreweryApp.swift` | `@main`, WindowGroup (min 900×600), menu `Commands` (Refresh ⌘R, Upgrade All ⇧⌘U), confirm-on-quit while a mutation runs |
| `AppModel.swift` | The single `@Observable` root: catalog, installed/outdated dictionaries, operation queue + pump, refresh orchestration, `status(for:)` merge |
| `Package.swift` | Pure data: `Package`, `Conflict`, `PackageKind`, `InstalledInfo`, `OutdatedInfo`, `PackageStatus` |
| `BrewCommand.swift` | The safety whitelist enum — the only source of brew argv in the app |
| `BrewClient.swift` | brew binary discovery, `Process` exec with async line streaming, cancellation; static pure parsers for brew output |
| `BrewOperation.swift` | `@Observable` per-operation: command, state, capped live log buffer |
| `CatalogStore.swift` | download (catalog + executables + analytics) → slim-decode/merge → versioned cache file → `[Package]`; staleness check |
| `Receipts.swift` *(v2)* | `@concurrent` sweep of `INSTALL_RECEIPT.json` files → on-request flags + dependency lists **(v4: + `source.tap`)**; pure parser |
| `TapStore.swift` *(v4)* | `@concurrent` local scan of `Library/Taps` → `[Package]` for third-party taps; pure regex parsers; zero subprocesses |
| `IconStore.swift` *(v3)* | actor: favicon fetch with in-flight dedup and a concurrency cap → memory dictionary + disk LRU (byte-capped); negative-result markers |
| `FuzzySearch.swift` | Pure scorer + `@concurrent` ranking |
| `ServicesView.swift` *(v5)* | The Services section: a `List` of icon/name/command rows with status + toggle; shared `ServiceToggle` |
| `TapsView.swift` *(v6)* | The Taps section: tap rows with trust badges, the tap page, add-tap popover, remove confirmation |
| `ContentView.swift` | `NavigationSplitView` shell: sidebar, `.searchable`, operations popover, brew-missing state |
| `PackageGridView.swift` | `ScrollView` + `LazyVGrid` of cards, empty states |
| `PackageCardView.swift` | One card: icon, name, status line, description, action button |
| `PackageDetailView.swift` | Sheet: `DetailPage` per drill-down level (manual stack, footer back button, swipe-back monitor), header, links, caveats renderer (`CaveatFormat`/`RichText`/`CopyButton`), Contents/Service sections, operation log |
| `PackageIconView.swift` | icon view backed by `IconStore` (v3; was `AsyncImage`), SF Symbol fallbacks |
| `OperationLogView.swift` | Monospaced auto-scrolling log for one operation *(v9: top-aligned until it overflows, then tail-pinned — per-role scroll anchors)* |
| `OperationLogWindow.swift` *(v9)* | One operation's log in an auxiliary window: operation as title, state as subtitle, Cancel in the toolbar, `OperationLogView` filling it |

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
    let license: String?      // v3; SPDX identifier, formulae only — casks have no such field
    let rubySourcePath: String? // tap-relative .rb path from the API / the scan; nil when synthesized
    let tap: String?          // v4; "user/repo" for third-party taps, nil = core (implied by kind)
    var id: String { "\(kind.rawValue):\(name)" }
    var isFont: Bool { kind == .cask && name.hasPrefix("font-") }
    var kindLabel: String     // "Formula" / "Cask" / "Font" — the icon can't say it once a favicon loads
}

struct Conflict: Codable, Hashable { let name: String; let reason: String? }
```

(Synthesized packages for catalog-missing installed items get empty/nil v3 fields. The four v3 fields carry defaults in an **explicit** `init` — a `let` with an inline default drops out of the implicit memberwise init and would break every existing call site.)

**Decode defensively.** `conflicts_with_reasons` contains **null elements** — not short arrays: 5 formulae (`parrot`, `rakudo`, `rakudo-star`, `visionmedia-watch`, `watch`) express "conflict with no stated reason" as a `null` *inside* the array, so the field is `[String?]?`. Typed `[String]?` it throws, and one throw aborts the whole 8.5k decode, leaving the app with no catalog at all. Live data has **zero** length mismatches, so the padding below is belt-and-braces. `license` decodes through a small lenient wrapper that yields nil on an unexpected shape, for the same reason — the field is a string today but has a history of being an SPDX expression object.

Install-state overlays live in `AppModel`, keyed by `Package.ID`, never persisted (they're <1 s to re-query):

```swift
struct InstalledInfo {
    var versions: [String]
    var onRequest: Bool         // v2, from receipt; missing receipt → true (never hide the unknown)
    var dependencies: [String]  // v2, formulae only: installed runtime deps, short names
    var apps: [String]          // casks only: `.app` bundle names, from the receipt
    var tap: String?            // v4, from receipt source.tap — NORMALIZED: homebrew/core,
                                // homebrew/cask or absent → nil, else "user/repo"
}

struct OutdatedInfo  { var installed: [String]; var current: String; var pinned: Bool }

// v5 — the catalog service block, slimmed to what the UI says, decoded leniently:
struct ServiceDefinition: Codable, Hashable {
    var run: [String]        // string-or-array in the API; the humanized command line
    var runType: String?     // "immediate" | "interval" | "cron"
    var interval: Int?       // seconds, when runType == interval
    var cron: String?        // when runType == cron
    var keepAlive: Bool      // any true value inside the keep_alive object
    var requireRoot: Bool    // toggle disabled — a user-level start of these lies, then errors
    var logPath: String?
    var sockets: [String]    // "tcp://127.0.0.1:6379" strings → the Ports row
}

// v5 — the per-name status overlay from `brew services list --json`; unknown strings → .other:
enum ServiceHealth: String { case started, stopped, none, scheduled, error, unknown, other }
struct ServiceStatus { var health: ServiceHealth; var exitCode: Int? }

// v6 — one row of the Taps tab, collected during the v4 scan (zero subprocesses):
struct TapInfo { var name: String; var remote: String?; var formulaCount: Int; var caskCount: Int
                 var lastChecked: Date? }   // FETCH_HEAD mtime — brew update touches it per tap

// v6 — the trust store, read directly (atomic writes make that safe); absence = nothing trusted:
struct TrustState { var taps: Set<String>; var itemPrefixes: [String] }
// per-tap: official → built-in (implicitly trusted); name ∈ taps → trusted;
// items with "name/" prefix → partially trusted (count); else untrusted

enum PackageStatus {
    case notInstalled
    case installed(version: String)
    case outdated(installed: String, current: String)
    case busy                 // a queued/running operation targets this package
}
```

`AppModel.status(for:)` merges the three sources; `busy` wins. A running `upgradeAll` marks every currently-outdated *unpinned* package busy (bare `brew upgrade` skips pinned ones). **Join rule**: `brew outdated` reports formulae by tap-qualified `full_name` (`user/tap/foo`) while `brew list` prints short keg names — normalize both to the last `/`-separated component, so an overlay key is always `kind:shortname`, matching `Package.ID`. Cross-tap name collisions are theoretically possible and accepted for v1.

**(v4) The tap rules**, in one place because every consumer must agree:

- **`Package.name` stays short.** The tap is a separate field, so `Package.ID`, the overlay joins, `shortName` and its three call sites are untouched — that is the whole no-regression story in one sentence.
- **Effective tap** = `installed[id]?.tap ?? package.tap`. The receipt outranks the catalog because it records what was *actually* installed — the case that matters is a name collision where the catalog winner is core but the keg came from a tap. Display (card tag, detail row) and command construction read the same rule, so what the UI claims and what brew is told never diverge.
- **Receipt normalization**: `source.tap` says `homebrew/core`/`homebrew/cask` for core installs; folding those to nil keeps "nil = core" true everywhere and stops every core upgrade from being needlessly tap-qualified.
- **Command qualification** (`AppModel.install`/`upgrade`, the only place names reach brew): `effectiveTap` present *and in the current scan result* → `"\(tap)/\(name)"`, else the short name. The scan-membership guard is load-bearing: a stale receipt naming a since-untapped tap would otherwise make brew *clone the tap back* (its on-demand auto-tap path) — a mutation nobody ordered. `BrewCommand` is unchanged: the qualified name is still one argv element, argv is still exactly 3 elements, and the safety whitelist gains no cases.
- **Compose** (`AppModel.composeCatalog()`): `catalog = coreCatalog + tapPackages` deduped by ID — core wins core-vs-tap, alphabetically-first tap wins tap-vs-tap (deterministic; extends v1's accepted-collision rule — the loser is invisible in Discover but its installed state still joins the winner's card). Recompose is skipped when a fresh scan equals the previous result (`[Package]` equality over ~200 entries). It rebuilds `catalogIndex` (16k dictionary, a few ms at ⌘R cadence) and bumps `catalogGeneration: Int`; **`commandIndex` rebuilds only when the core catalog changes** — tap formulae have no executables.txt data, and re-deriving a ~60k-key index per refresh would be the one real perf regression this design could cause.
- **`catalogGeneration`** replaces `catalog.count` in the view-layer invalidation keys (`SearchKey`/`BrowseKey`): a count is a sound change-proxy only while the catalog can never change at equal size, which taps break (tap one repo, untap another, net zero). Deliberately **not** in `WindowToken` — a recompose must never reset the scroll window.
- **`CatalogCache` gains `tapInstalls90d: [String: Int]?`** — the qualified-name subset of the formula analytics (keys containing `/`), captured at fetch time so compose can join real install counts for tap packages. Optional, so a v5 cache decodes it as nil and degrades to no counts until the next daily fetch — like `tap` on `Package` (nil = core = correct for every cached entry), **no cache-version bump is needed**. The composed catalog is never written back to the cache file; `CatalogStore` persists only its own core packages.

**(v4) TapStore scan** — `@concurrent`, zero subprocesses, run at bootstrap, on ⌘R and inside `refreshState()` (post-mutation refreshes matter: the session `brew update` pulls tap clones, bumping versions mid-session), generation-guarded like the receipt sweep so a stale scan cannot overwrite a newer one:

1. Taps root = `realpath(brew binary)/../../Library/Taps`; skip `homebrew/homebrew-core` and `homebrew/homebrew-cask` clones.
2. Per tap: formula files from the **first existing** of `Formula/**`, `HomebrewFormula/**`, root `*.rb` (top level only); casks from `Casks/**`; duplicate basenames → longer path wins. All per brew's own `tap.rb` rules.
3. Per file, line-anchored first-match regex for `desc`/`homepage`/`version`/`license` (first quoted string only) and `deprecate!`/`disable!` presence. A package is emitted **only** when the file declares `class … < Formula` (or a `cask "…"` stanza) — root-level stray Ruby must not become a card. Missing version → `""`, which the UI already hides.
4. **Versioned-graveyard rule**: `<base>@*.rb` is skipped when `<base>.rb` exists in the same tap, *unless* that exact versioned name is installed (oven-sh/bun ships 165 dead `bun@x.y.z` files that would otherwise bury search); applies to scanned taps only — core's curated `python@3.12`-style entries are unaffected.
5. Per tap, `remote.origin.url` from `.git/config` (`.git` suffix stripped, `git@github.com:` → `https://github.com/`; unparseable → no source link), and `installs90d` joined from `tapInstalls90d` by `"\(tap)/\(name)"`.

~200 files on a typical tapped machine → tens of ms, off the main actor.

The views are dumb renderers of `[Package]` + `status(for:)`:

- **Discover** — the full catalog, fuzzy-filtered by search.
- **Installed** — catalog packages present in `installed`, **plus synthesized `Package`s** for installed items missing from the catalog: name + kind, `version` = installed version (the only version we know), nil desc/homepage, `deprecated`/`disabled` = false. **(v4)** Rare now — the tap scan puts tapped items in the catalog proper, and `merged`'s covered-set check makes it stop synthesizing them automatically; synthesis remains the fallback for what no scan covers (e.g. a formula since deleted from its tap).
- **Outdated** — packages present in `outdated`. Pinned items are shown with the Update button disabled and a "pinned" label (we never touch pins). The section mirrors bare `brew outdated`'s **non-greedy default**: `version :latest` casks never appear, and `auto_updates` casks (browsers, editors) appear only when the installed bundle's `Info.plist` version lags the cask version (`cask/cask.rb`); the `--greedy` variants are deliberately out of scope for v1 — those apps update themselves. **(v8)** The page carries the freshness caption ("Checking for updates…" / "Last checked *n* ago") and its empty state only claims "Everything is up to date" once a running check has finished — see *Metadata freshness (v8)*.

Overlay refresh happens on launch, on ⌘R, and after every mutating operation completes (success or failure). **(v2)** Each refresh also sweeps the receipts (`Receipts.swift`, `@concurrent` — ~350 small JSON reads, tens of ms): the keg read is the one whose version dir matches the *last* version `brew list` reported; `runtime_dependencies` `full_name`s are normalized to short names per the join rule. `AppModel` then inverts the dependency map once into `dependents: [Package.ID: [Package.ID]]` — "who depends on X" is a dictionary lookup, no graph machinery.

**(v2) Filters** are plain view-local state, persisted with `@AppStorage`:

- **Discover**: kind (`All | Formulae | Casks | Fonts` — Fonts (v3) are the `font-`-prefixed casks, in `homebrew/cask` since the fonts-tap merge (verified: `font-fira-code` → `tap: homebrew/cask`); `Casks` excludes them so it means "apps", otherwise the Fonts option would be pointless) + a "Hide deprecated" toggle (hides `deprecated || disabled` — a disabled package is further along the same lifecycle and can't be installed anyway). Applied as a pre-filter to the array handed to `FuzzySearch.rank`, so ranking cost only ever shrinks. (`.searchScopes` was considered for the kind filter and rejected: scopes only surface while search is active, and the filter must also govern empty-query browsing.)
- **Installed**: scope picker `On Request` (default) | `All`. On Request shows `onRequest == true` items; All adds dependency-only items, each marked "dependency" in the card's status run.

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
    case servicesList         // v5: ["services", "list", "--json"] — read
    case serviceStart(name: String)  // v5: ["services", "start", name] — mutating, reversible
    case serviceStop(name: String)   // v5: ["services", "stop", name] — mutating, reversible
    case tap(name: String)           // v6: ["tap", name] — a git clone of github.com/user/homebrew-repo
    case untap(name: String)         // v6: ["untap", name] — clone removal; brew refuses while in use

    var arguments: [String] { ... }
    var isMutating: Bool { ... }   // update / install / upgrade / upgradeAll / serviceStart / serviceStop
}
```

- No `uninstall`, `remove`, `rm`, `cleanup`, `pin`, `unpin`, `zap`, or `--force` case exists anywhere. **(v5)** Likewise no services `kill`/`cleanup`/`restart`/`run`, none of their aliases, no `--all`, no `--file=`, no `--sudo-service-user` — canonical `start`/`stop` on one named service is all that is representable, and both are launchd operations brew itself reverses. **(v6)** Likewise no `untap --force` (it uninstalls the tap's packages), no `--custom-remote`, no `--repair`, no `--eval-all`; tap names are validated to the default-GitHub `user/repo` shape before enqueue, and neither tap nor untap triggers the session `brew update`.
- `BrewClient.run` accepts only a `BrewCommand`. There is no `run(arguments: [String])`.
- Explicit `--formula`/`--cask` on install/upgrade: the app already knows the kind from the catalog, so brew never has to disambiguate a name that exists as both (which it would resolve with a warning).
- `Process` execs the brew binary directly — no `/bin/sh -c`, so package names are single argv elements with no *shell* injection surface. Names only ever come from decoded catalog/outdated entries, never from a free text field; `enqueue` additionally rejects names starting with `-` so a hostile catalog entry can't be parsed by brew as a flag.
- Brew's *implicit* destruction — the periodic auto-cleanup that install/upgrade trigger by default — is switched off via `HOMEBREW_NO_INSTALL_CLEANUP=1` (see the environment list above). The whitelist covers what we ask brew to do; the env var covers what brew does unasked.
- `BrewCommandTests` asserts every case's argv: first token ∈ `{list, outdated, update, install, upgrade}`, no argv element matches `uninstall|remove|rm|cleanup|pin|zap|--force|kill|--file|--sudo-service-user`, and install/upgrade carry the explicit kind token. A cheap tripwire against future regressions.

## BrewClient

**Discovery** (init, re-run on ⌘R): `FileManager.fileExists` at `/opt/homebrew/bin/brew`, then `/usr/local/bin/brew`. Neither → `AppModel.brewMissing = true`, whole window shows a `ContentUnavailableView` linking to brew.sh — so a user who installs Homebrew while the window is open recovers with a Refresh, no relaunch.

**Invocation** — one core method:

```swift
func run(_ command: BrewCommand,
         onLine: @MainActor @Sendable @escaping (String) -> Void) async throws -> Int32
```

- `Process` with `executableURL` = brew path, `arguments` = `command.arguments`.
- Environment: inherited + `HOMEBREW_NO_ENV_HINTS=1`, `HOMEBREW_NO_ASK=1`, `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_INSTALL_CLEANUP=1`, **(v5)** `HOMEBREW_SERVICES_NO_DOMAIN_WARNING=1`; `SUDO_ASKPASS` when `command.isMutating`.
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
3. **Cache** — `struct CatalogCache: Codable { let version: Int; let fetchedAt: Date; let packages: [Package] }` → atomic write to `Application Support/Brewery/catalog.json` (~4.5 MB with the v3 fields). **(v3)** `version` (now **`4`** — bumped when `license` joined `Package`) is the schema stamp: a mismatch — or a decode failure, which is what a pre-v3 cache without the field produces — is treated as "no cache" and triggers a fresh download, so schema migrations are free.
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

**(v4)** For packages with `tap != nil` **only** (~200 of 16k), the qualified `"user/repo/name"` string is scored as one extra candidate, max'd with the others — so "charmbracelet" surfaces that tap's packages. Invariant, pinned by test: a qualified-string hit never outranks an exact short-name match elsewhere. Zero added cost for core entries — the extra fold is gated on the nil check.

Command-exact sits between prefix and word-boundary deliberately: someone typing `convert` almost certainly wants the tool that provides it (imagemagick), but a formula literally *named* what you typed still wins. When the winning score came from the command index, the hit carries `matchedCommand` and the card shows a "Provides `convert`" caption — without it, command matches look like false positives. Two mechanics: the index maps commands to the *whole catalog*, so a command hit only counts when its package is in the `packages` argument (Installed/Outdated pass their subset and must not surface strangers); and the browse path (empty query) wraps its packages in `SearchHit(matchedCommand: nil)` so the grid renders one type.

Tie-break: shorter name, then alphabetical. Search results capped at 200. An **empty query bypasses ranking entirely** and shows the full section listing, uncapped as *data* — rendering is windowed (v3, see Grid below). Discover's browse listing is sorted by 90-day installs (analytics ride the catalog; ties and unranked packages alphabetical) — an alphabetical walk of 16k packages opens on "0 A.D." and never reaches anything anyone installs; Installed and Outdated are inventories and stay alphabetical.

Wiring — no Combine, no search actor:

```swift
.task(id: searchKey) {
    guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return }  // debounce: sleep throws on retype → bail
    results[section] = await FuzzySearch.rank(query: searchText, in: sourcePackages, commands: model.commandIndex)
}
```

(The `guard` matters: a bare `try? await Task.sleep` swallows the cancellation and the stale task would rank — and assign — anyway.) 50 ms, not 120: ranking is a few milliseconds and runs off the main actor, so the debounce only has to coalesce a fast typist's burst.

**Results are keyed by section**, like the queries. A single array meant visiting a tab whose query is empty cleared it, and the return trip flashed the unfiltered listing until the re-rank landed. The browse listing is likewise cached in `@State`, rebuilt only when the underlying array changes — its key deliberately excludes the query, since the grid still shows that listing while a search is being typed.

## Icons

**(v3: `IconStore` replaces the v1 `AsyncImage` approach.)** Why the change — two field-observed defects, both structural to `AsyncImage`:

1. Grid cells cancel their `AsyncImage` load when scrolled away or re-diffed; the phase sticks at failure, so icons randomly miss in the grid yet appear after opening the detail sheet (whose load survives long enough to complete and warm `URLCache`). That's exactly the reported "loads on click, then grid shows it".
2. `URLCache` obeys response headers, so DuckDuckGo's `cache-control`-less 404s were re-fetched on every card appearance.

Design — one actor, keyed by **host** (many packages share a homepage host; deduping by host is a large win):

- `func icon(for host: String) async -> NSImage?` — checks, in order: memory → disk → network. The network fetch runs in a **shared task per host** (in-flight dedup); a view's cancellation abandons the *await*, never the fetch, so the result always lands in the cache and the next appearance is a hit. This alone fixes defect 1.
- **Not cancelling removes the only cap on how much is in flight**, which `AsyncImage` gave for free by throwing scrolled-away loads away. So the cap is explicit: at most **6** downloads at once (a plain async semaphore), a dedicated `URLSession` with a 15 s request timeout, and a **5-minute in-memory cooldown** after a transport failure — without it, every reappearance of a card re-fires a request already known to be timing out. The budget must outlast one slow name resolution or no icon ever loads; what keeps the UI free is the cap, not a short timeout.
- **Memory is a plain dictionary, not `NSCache`** (capped, flushed wholesale at the cap): the system purges an `NSCache` under memory pressure without warning, and this app holds a 16k catalog, so icons were being evicted and re-read from disk on every card open.
- **Disk**: `Application Support/Brewery/Icons/<host>` files (bytes as received; `NSImage` decodes `.ico`/`.png`). Two timestamps do two jobs: *birthtime* = fetch date, *mtime* = last access (touched on read). **Eviction is the user's "sliding window of bytes"**: after each write, if the directory exceeds **50 MB**, delete oldest-mtime files until under the cap — plain LRU, no index file, no database. (~2,000 icons of ~4 KB is ~8 MB; the cap is generous headroom, not a target.)
- **Refresh**: icons rarely change. If a disk hit's birthtime is older than **7 days**, serve the stale image immediately and re-fetch in the background — the grid never waits on a refresh. mtime is re-stamped at most daily: LRU reads that clock in days, and touching it per read costs a write syscall per icon per appearance, serialized behind the actor.
- **Negative caching**: a 404 or undecodable body writes a zero-byte marker file with the same 7-day birthtime TTL — unknown domains cost one request a week instead of one per card appearance (closes v1's accepted network-chatter wart). The marker renders as the SF Symbol fallback, *not* DuckDuckGo's embedded globe: an empty file can't decode, so the globe-instead-of-fallback wart closes too, for free.
- **Fonts (v3)**: `isFont` packages never hit the store at all — foundry favicons are meaningless; they always render the `textformat` SF Symbol.
- `URLCache.shared` stays at its default size; icons no longer go through it.
- Fallback SF Symbols in a tinted rounded rect: formula → `terminal.fill`, cask → `macwindow`, font → `textformat`. The loading placeholder is the same symbol dimmed — no spinners in the grid.

Alternatives considered: keeping `URLCache` + retry-on-appear (doesn't fix cancellation, no negative caching, opaque eviction); SQLite/Core Data index (machinery for a problem file mtimes already solve).

## UI structure

- **Window**: a single `Window` scene (**v7** — not a `WindowGroup`: there is one catalog, one queue and one set of filters, so ⌘N offered a second window of the same app while `applicationShouldTerminateAfterLastWindowClosed` meant closing any window quit it), `NavigationSplitView`, `.defaultSize(1200 × 780)` and a 1000 pt minimum so the sidebar, two columns of cards and the info pane all fit at the floor. Sidebar: Discover (`sparkle.magnifyingglass`), Installed (`checkmark.circle`), Outdated (`arrow.triangle.2.circlepath`) with `.badge(outdatedCount)`; **(v5)** Services (`server.rack` — most brew services are servers) with `.badge(running count)`; **(v6)** Taps (`spigot`). Stock components get Liquid Glass chrome for free.
- **Search**: `.searchable` on the detail column; Discover = full-catalog fuzzy, Installed/Outdated = fuzzy over that section's array. **(v3)** Each section binds to its own query in `AppModel.queries` — queries do not leak across tabs, and each tab's query survives switching away and back.
- **(v3) Counts**: `.navigationSubtitle` — the native macOS spot for this (Mail's message counts live there): browsing shows "16,223 packages" (Discover) / "309 installed" / "12 outdated"; an active search or filter shows "142 results" instead. Counts reflect what the current query + filters actually yield, not raw totals.
- **(v2) Filter controls**: Discover's toolbar gets a filter `Menu` (`line.3.horizontal.decrease.circle`, filled variant when any filter is active) holding the kind `Picker` and the "Hide deprecated" `Toggle`; Installed's toolbar gets the `On Request | All` scope `Picker` inline (two options don't need a menu) and, since v5.x, its **own** kind filter `Menu` (same `KindFilter` enum as Discover — one enum, one `matches()` — but separate `@AppStorage`: switching tabs must not carry one tab's filter into the other) holding the kind `Picker` plus a **From Taps Only** toggle (receipt-aware: it filters on the *effective* tap, so a collided tap install still counts); Outdated's toolbar gets an **Update All** button whenever anything is outdated (disabled while an Upgrade All is already queued or running) — the menu bar's ⇧⌘U is invisible from the one tab whose whole job is updating.
- **Grid**: `LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))])`. Card: 44 pt icon, name (headline), status line — pills for identity (`Formula`/`Cask`/`Font` tag, **(v4)** tap-owner tag), then one `·`-joined run of plain text for version and state, the App Store metadata pattern (version — "1.2 → 1.3" in orange when outdated, cask comma-versions like `2.1.50,56f0a83` truncated at the comma — then "deprecated" in red / "pinned" / "dependency"; a bare value sandwiched between capsules read as clutter), 2-line description, **(v3)** a "Provides `<cmd>`" caption on command-matched search hits, trailing control — `Install` / `Update` (`.borderedProminent`) / an "Installed" label with a green `checkmark.circle.fill` (state wears no button chrome: a disabled button washes out and reads as broken; the card's hidden height-reserving twin is always the tallest variant so mixed rows stay flush) / a `ProgressView` plus a stop button (busy, and only when that package has its own operation — a card made busy by Upgrade All has nothing of its own to stop). `disabled` packages: button disabled with explanation in detail. The kind tag, the tap-owner tag and the detail pane's share one small `TagLabel`. **(v7)** `CardButtonStyle` gains a *selected* state — the accent border it already used for pressed (a press is a selection about to happen, so the card does not change costume between the two) plus an accent wash, added conditionally rather than as an always-present layer at `opacity(0)`, because 60 cards are rebuilt on every keystroke.
- **(v3) Windowed rendering**: **the slice is taken in `ContentView`, and the grid is handed only the cards it draws** plus a total count so it knows whether to ask for more. `window` starts at 60; a clear sentinel inside the `LazyVGrid` extends it by 60 via `onAppear`, and it resets when the query, filters or section change. **Windowing the rendering alone is not enough, and this is the load-bearing part**: a view's stored properties live in SwiftUI's attribute graph, which copies and compares them on every update, so passing the full `[SearchHit]` and rendering `prefix(window)` cost ~6 s per click or keystroke even though only 60 cards were ever drawn — the array must not cross the view boundary at all. Measured: handing the grid 60 instead of 16,223, with identical rendering, took a click from 6.34 s to 0.51 s. **Pagination was considered and rejected**: page controls are a web idiom with no macOS precedent — every native catalog UI (App Store, Music) scrolls continuously.
- **Detail** (**v7**: a pane, not a sheet): `.inspector(isPresented:)` on the detail column, `.inspectorColumnWidth(min: 300, ideal: 340, max: 480)`. Reading about a package is not a task to be completed or abandoned, so it is not modal: the grid stays live and clickable beside it, the pane resizes with the window, and clicking the next card moves the pane on instead of dismiss-then-open. As a sheet it had grown a footer, a back button, a swipe-back event monitor, a focus sink and three hardcoded heights (`380/520/580`) — an app inside the app, which is exactly what the modality guidance warns against, and a 520 pt modal over a blurred grid uses none of the display it is asked to leverage. Toggled by ⌘I and by a trailing `sidebar.right` toolbar item; with nothing selected it shows a **No Selection** `ContentUnavailableView`, which is reachable because ⌘I works regardless. `.id(package.id)` on the content, so a different card starts a fresh drill-down stack rather than leaving you inside the last package's dependencies. Content: icon + name + kind tag, then the action, then the attribute rows — **stacked, because at ~300 pt the sheet's one-wide-row header broke words in half** ("openssl@ 3", "Installe d") — then description, homepage `Link` beside a source `Link` (the package's `.rb` on GitHub, labelled with the monospaced file name — built from the API's tap-relative `ruby_source_path` + the kind's repo, never from a guessed sharding scheme; synthesized packages have no path and no link), and the package's latest operation log if any. **(v2)** Two more sections when installed: **Dependencies** — the receipt's installed runtime deps as tappable rows (icon, name, installed version; `declared_directly` ones sorted first); **Required by** — the inverted map's entries for this package (present for any depended-on item, which is also how a dependency-only item explains why it exists). Tapping a row **pushes** onto the pane's lightweight manual stack: pages stay mounted so back restores the parent's scroll offset, each opens at the top, and a named back control sits at the **leading top edge** ("‹ openssl@3") + ⌘[ with a directional slide. Still manual rather than `NavigationStack`: a stack inside a pane has no toolbar for the framework to hang a back button from, and mounted pages are what preserves scroll. The footer's constant-height argument for a bottom-left back button retires with the footer — a bar that comes and goes only skewed a layout whose height was derived from its content.
  - **The layout-loop lesson**: `RichText` (the AppKit-backed caveats paragraph) set `preferredMaxLayoutWidth` inside `sizeThatFits` — a mutation inside a sizing query, which dirties AppKit's constraints, which asks for another layout pass, which sizes again. A fixed-width sheet converged on the first pass and hid it; in a resizable pane the proposals never settle and the window throws *"more Update Constraints in Window passes than there are views in the window"*. `cellSize(forBounds:)` already takes the width to wrap at, so the assignment was never needed. Any `NSViewRepresentable` here must measure without touching its view.
- **(v3) Detail additions**, each section rendered only when its data exists, in this order after the header (v2's Dependencies / Required by follow them):
  - **Installs** — a stat line under the version: "63,157 installs (90 days)", `chart.bar` symbol, count formatted with grouping separators.
  - **Caveats** — a plain titled section like every other (a `GroupBox` was tried and dropped: it indents its label off the shared margin and double-boxes the code chips), rendered by brew's own conventions (`CaveatFormat`, pure + tested): backticks become inline code spans via `AttributedString(markdown:, .inlineOnlyPreservingWhitespace)` — inline-only because full Markdown would collapse the newlines the text depends on, with a plain-text fallback so a caveat is never lost to a parse error — and two-space/tab-indented runs become monospaced code blocks with a copy button (they are commands meant to be executed). Selectable throughout; literal `$HOMEBREW_PREFIX` substituted with the real prefix at display time.
  - **Commands** — the formula's executables as selectable monospaced text, `·`-separated ("a2ps · card · fixps …"). A chip-flow layout was considered and rejected: a custom `Layout` for what is fundamentally a copyable word list.
  - **(v4) Contents** — the cask counterpart of Commands: what the cask puts on the machine, from the API's `artifacts` array (each element a single-key object naming the kind, with an optional sibling `target`; a binary's meaningful name is the *target* basename — the source is a `$APPDIR/…` path — verified on visual-studio-code/wireshark-app/docker-desktop). Payload only — app, suite, binary, pkg/installer, font, and the system add-ons (Quick Look, pref pane, screen saver, dictionary, input method, Spotlight importer, audio/VST plugins, services); plumbing (zap, uninstall, flight steps, completions, manpages — wireshark alone ships 22 manpages) is deliberately dropped. Rendered as a two-column `Grid`: kind (SF Symbol + label, secondary) left, names right — apps shown without ".app", binaries as the same monospaced `·`-run the Commands section taught (they *are* commands, and the row says "Commands"), font casks collapsed to a count ("7 font files": one typeface, many weight files). Decode is per-entry `Lenient`: an odd shape (object-form `installer`, inline `{target}` elements) drops that entry, never the cask. Tap casks get app/binary rows from the scan's DSL stanzas. `Package.artifacts` aggregates by kind (`CaskArtifact`) → cache **v6**.
  - **Conflicts with** — one row per `Conflict`: tappable name (pushes like dependency rows) + the reason as secondary text, e.g. "vim and macvim both install vi* binaries".
  - **License** — "License: MIT", alongside the installs stat. All three header stats share one row helper that puts the glyph in a fixed-width column, because `chart.bar` and `doc.text` are not the same width and `Label` alone leaves the values ragged.
  - **Open** — **(v7)** beside the package it opens, in the pane's action row, and bordered rather than prominent so the one filled button on screen is always the state-changing one. (It used to sit left of Done in the sheet's footer; there is no footer and no Done.) Shown for an installed cask whose receipt names a `.app` that is still on disk (`/Applications`, then the user's own folder), resolved on each pass so a bundle dragged to the Trash stops being offered; a `Menu` when a cask ships several. Launched through `NSWorkspace.openApplication`, i.e. LaunchServices, so the app is its own process — verified: parent is launchd, not Brewery, and quitting Brewery leaves it running. No brew involvement, so the safety model is untouched.
  - **(v7)** The focus sink is gone with the sheet: `.focusable()` + `.focusEffectDisabled()` existed to absorb the initial focus a *sheet* hands to the first focusable thing it finds (the homepage link, which opened ringed and looking chosen). A pane is not presented, so it steals nothing, and there is no Escape-to-close because there is nothing modal to close — ⌘I and the toolbar item govern it.
- **Operations popover** (Safari-downloads pattern): toolbar item shows a spinner + count while the queue is active; popover lists session operations with state icons — a Cancel button on the running one, a remove (✕) button on queued ones — each with a Show Log button. Auto-presents once on failure. **(v7)** When the most recent finished operation failed the toolbar glyph becomes a red `exclamationmark.triangle.fill` and its accessibility label says so — a *different glyph*, not just a red one, so the failure survives both dismissing the popover and colour-blindness. Without it, dismissing the auto-presented popover left no trace that anything had gone wrong. **(v9)** Logs left the popover for one auxiliary window per operation (`OperationLogWindow`, a value-only `WindowGroup(for: BrewOperation.ID.self)`): the inline expansion clipped a monospace stream inside a fixed 380-point frame and buried the queue it shared the surface with (HIG *Popovers*: "use a popover to expose a small amount of information"; "avoid making a popover too big"), while reading a log is exactly the "specific task… dedicated to one experience" HIG *Windows* assigns to an auxiliary window (and "consider providing the option to view content in a new window"). The window is resizable, live-tailing, titled by the operation with its state as subtitle, carries Cancel in its toolbar (HIG *Progress indicators*: let people halt processing), and lists in the Window menu. No default value, so File ▸ New Window stays absent and the single-window rule holds; restoration is off — operations are session state. Two traps pinned by `OperationsSurfaceTests`: a bare `ProgressView` in the toolbar button's label hoists itself out as an AX ActivityIndicator and the *button* vanishes from the accessibility tree — unreachable by VoiceOver exactly while work runs — so the label is `.accessibilityElement(children: .ignore)`; and the test seeds a canned queue via the `-demo-operation` launch argument, because operations exist only mid-mutation and a UI test must not mutate the machine.
- **Menu bar** (**v7** — every toolbar action needs a menu bar command and a key equivalent; before this only three commands existed and no destination had a keyboard path). Order follows the standard anatomy: Brewery, Edit, View, Homebrew, Window, Help.
  - **View**: the five sidebar destinations first, ⌘1…⌘5, drawn as `Toggle`s so macOS renders the "you are here" checkmark (switching one *off* is meaningless for a destination, so only `true` acts); then **Show/Hide Info** ⌘I and **Show/Hide Operations** — titles that name the state they will produce, not checkmarks.
  - **Homebrew** (app-specific, because these act on Homebrew rather than on the view): Refresh ⌘R (brew re-probe + installed + outdated + catalog staleness check), **Update All** ⇧⌘U, Add Tap… The last one was toolbar-only; it reaches a popover anchored to the tap list via the same request-counter channel ⌘F uses (`addTapRequests`), because a drilled-in tap page has no `+` to hang it from.
  - **Edit ▸ Find ▸ Find…** ⌘F focuses the search field via `.searchFocused` — wired explicitly rather than trusting the automatic `.searchable` binding, which has historically been inconsistent on macOS. The submenu is the standard shape; a flat item was not.
  - **Help**: the system's Help menu is a search field over a help book this app does not ship, so it is replaced with links to the documentation the app is a front end for (docs.brew.sh and its FAQ).
  - Selection and the two pane/popover visibility flags live in `AppModel`, not view `@State`, for the same reason the per-section queries do: a `Commands` builder can only reach app-level state.
  - **Wording**: user-facing strings say **Update** everywhere (the menu said "Upgrade All" while the toolbar and cards said "Update"). `BrewCommand`'s argv keeps brew's own `upgrade`.
- **(v7) System integration**: the Dock tile carries the outdated count (`NSApp.dockTile.badgeLabel`, the App Store / Software Update precedent — the sidebar already said it, this says it while Brewery is behind another window); a failure while Brewery is inactive bounces the icon once (`requestUserAttention(.informationalRequest)`); and the Dock menu offers Refresh and Update All (n). An install runs for minutes and people go elsewhere while it does — before this, nothing said it had finished.
- **(v7) Search**: Return in the field opens the top hit (`onSubmit(of: .search)`). `.searchSuggestions` stays rejected — the result grid already updates live in under half a second and shows strictly more than a suggestion list would.
- **(v7) Selection is visible**: a listing that leads to a detail pane has to keep saying which item the pane is about, so the selected card wears the accent border it already used for pressed plus a `.tint.quaternary` wash, and the selected service row wears the same wash. Only a single `Package.ID?` crosses the view boundary — never a set, for the reason windowed rendering exists — and the nil check comes first so 60 cards do not each interpolate a fresh `id` string per keystroke while the pane is closed.
- **Refresh, visibly**: on a warm cache ⌘R finishes fast enough to look like nothing happened, so `AppModel.isRefreshing` (guarded — a second refresh cannot start on top of the first) drives a toolbar button whose glyph spins for the duration, and a *refresh veil* over the grid itself: the listing blurs and dims — never hidden, since the data on screen stays valid while it is re-checked — behind a glass "Checking for updates…" capsule that blur-replaces in and out (`refreshVeil` in `ContentView.swift`); on a warm cache it reads as a soft half-second pulse acknowledging the ⌘R. The detail pane wears the same veil on its content, and its rows update in place when the refresh lands. Outdated's empty state also offers a centered **Check Again**, since "Everything is up to date" invites exactly that question; Discover's does not, because an empty grid there means a filter is hiding things and re-checking will not bring them back.
- **Animation** is deliberately sparse, and only where it hides a rough edge: icons crossfade in when they arrive, the card's action control blur-replaces between Install / spinner / checkmark, and the operations count rolls with `.numericText`. The grid does **not** animate rearranging — a reshuffle on every keystroke is noise, not feedback. The `.navigationSubtitle` count cannot animate: it is AppKit-rendered in the titlebar, so a `contentTransition` does not survive the trip.
- **(v7) Motion is optional.** Every animating site reads `accessibilityReduceMotion`, because the app was doing all three of the things that setting exists to remove: sliding pages along the x axis (both drill-downs), animating into and out of blurs (`.blurReplace`, the veil's 6 pt blur), and sustaining rotations (`.symbolEffect(.rotate, .repeating)`). With it on, pushes crossfade, the veil dims without blurring, the card's control crossfades, and the two rotations hold still — the disabled toolbar glyph and the "Running…" caption already carry that state without moving. `refreshVeil` is a `ViewModifier` rather than a `View` extension for exactly this reason: an extension cannot read the environment.
- **(v7) Contrast**: the deprecation and untrusted-tap banners share one `warningWash(_:)` modifier whose fill strengthens and gains a border under Increase Contrast. They previously hardcoded a 10% wash each, whose alpha ignored the setting. Both already pair colour with a symbol and text, so nothing depends on colour alone.
- **(v7) Labels**: the `require_root` service switch had its explanation only in a `.help` tooltip, so VoiceOver read an unnamed, unlabelled, disabled switch. Tooltips are pointer-only; anything they say has to exist in the accessibility tree too.
- **Quit while a mutation runs**: `NSApplicationDelegateAdaptor` + `applicationShouldTerminate` shows a confirm dialog when an install/upgrade is running. On confirmed quit, the running brew gets `interrupt()` (the same SIGINT path as Cancel) and up to 5 s to exit; if it still hasn't (rare — brew traps INT), quit anyway and accept the orphan as the lesser evil versus a hung quit. Queued-but-unstarted operations are simply discarded.
- **(v5) Services section** — System Settings › Login Items, not the card grid (services are state rows): `PackageIconView` (32 pt) + title, subtitle = the humanized run command (monospaced, middle-truncated, `$HOMEBREW_PREFIX` substituted by the caveats helper), trailing status caption + `Toggle`. Toggle on = loaded (`started`/`scheduled`/`error`/`stopped`), off = `none`/`unknown`; on-flip enqueues `serviceStart`, off-flip `serviceStop` (qualified by effective tap; **no session `brew update`** — nothing package-related changes). Status caption speaks only when it has something to say: green "Running", orange "Scheduled", red "Failed (exit N)". Busy swaps the toggle for the small `ProgressView` via the existing `status(for:)`. `require_root` services: toggle disabled, "Requires root — manage in Terminal". Row click opens the detail sheet. The detail sheet gains a **Service** section for any formula with a `service` block — the Contents-style two-column grid (Command mono, Type humanized incl. keep-alive, Ports from sockets, Logs path) topped by the same shared `ServiceToggle` when installed; one component in both places, one source of truth.
- **(v6) Taps section** — a Sources-style `List`: third-party rows show name, "N formulae · M casks · K installed", last-checked relative date, and a trust badge (quiet `checkmark.shield` Trusted / orange "N items trusted" / orange `shield.slash` Untrusted); `homebrew/core` and `homebrew/cask` sit pinned on top as **Built in** (catalog counts, implicitly trusted, not removable). Row click pushes the tap page in-column (toolbar back in `.navigation` placement, the established slide): remote link, counts, a one-line trust explainer for untrusted taps, and the ordinary `PackageGridView` over that tap's packages (search-within-tap via subset ranking; core pages are the catalog filtered by kind, popularity-sorted). Tap pages carry their own transient kind-filter menu — @State reset per page, because a persisted filter that silently empties the next tap's page would read as data loss. Toolbar `+` opens the add-tap popover — `user/repo` field with live validation and an honesty caption ("Clones github.com/user/homebrew-repo. Formulae from it stay untrusted until you install one.") — and enqueues `tap` with a live log. Rows keep the trailing trust badge only (the freshness timestamp lives on the tap page — repeating one near-identical date per row was noise) with full-width separators. Context-menu **Untrust** appears on explicitly-trusted rows; **Remove Tap…** confirms with the exact consequences (clone removed; installed packages remain but lose updates; brew keeps trusting it if re-added) and is disabled with an explanation while packages from the tap are installed — brew would refuse anyway; the UI just declines to enqueue doomed work.
- **Newcomer explanations** (v6.x, revised v7.1) — the app assumes no Homebrew knowledge, in **two** Apple grammars, split by what the sentence *is*. **Vocabulary** — read once, then dead weight — is a one-time dismissible **TipKit** card: formulae vs casks atop Discover, "Taps are package catalogs" atop the Taps list (`Tips.configure()` at launch persists the dismissal; the row is gated on `tip.statusUpdates` so a dismissed tip leaves no ghost insets in the `List`). **Consequences of a control** stay on the control as a `.help` tooltip plus the matching `accessibilityHint` — the Services switch says "Starts now and at every login" / "Stops now and won't start at login" (accurate on both sides: `brew services stop` "unregister[s] it from launching at login", brew `services/subcommand/stop.rb`), and every jargon tag keeps its `TagLabel` tooltip ("A command-line tool that runs in Terminal" / "A Mac app" / "A font" / the tap-owner explanation). The **header-subtitle** grammar this replaces is retired: a `List` section header is a label's slot, so prose in it truncated mid-word on Services (HIG *Lists and tables* → Content: "Consider ways to preserve readability of text that might otherwise get clipped or truncated"), a header with no title read as a gray band welded under the toolbar, and permanent onboarding copy contradicts HIG *Onboarding* ("Consider providing a collection of context-specific tips instead of a single onboarding flow"). Section headers are now plain labels — **Built in**, **Your taps** — and Services has none: the window title and its "N services" subtitle already say it. HIG *Offering help* → macOS ("Explain the action or task the control initiates", "Be brief", "avoid repeating a control's name in its tooltip") is why the switch tooltip states the login consequence instead of the old "Start atuin", which repeated the name and told you only what the switch position already showed.
- **Empty states**: `ContentUnavailableView.search` for no results; "Everything is up to date" in Outdated; full-window "Homebrew not found" with a brew.sh link; "Couldn't load catalog" + Retry when no cache and download failed; **(v5)** "No services" when nothing installed defines one.
- **(v4) Taps in the UI** — identity everywhere, chrome nowhere:
  - **Card**: the status line gains `TagLabel(owner)` for third-party items — the **owner segment only** (`charmbracelet`, not `charmbracelet/tap`): it is the identity people recognize, and the full string does not fit a caption row that already holds kind + version in a 230 pt column (`.truncationMode(.middle)` + low layout priority as backstop). Core items show no tap tag — 16k cards saying "homebrew/core" is noise, and the kind tag already implies core.
  - **Detail sheet**: a `statRow` with the `spigot` SF Symbol (outline, matching the `chart.bar`/`doc.text` weight) shows the **full effective tap for every package** — core items show the derived `homebrew/core`/`homebrew/cask`, so "which tap is this from" is always answerable. For not-yet-installed tap items, the install button's `.help` and a one-line caption disclose the trust side effect: "Installing trusts charmbracelet/tap/gum in Homebrew".
  - **Source link**: `rubySourceURL` is tap-aware — core keeps the kind→repo rule (pinned by tests); tap items build from the tap's git remote when it is github.com, otherwise no link (honest degrade).
  - **Discover**: the filter menu gains a **From Taps Only** toggle (`tap != nil`) beside Hide Deprecated — a *combinable* switch, deliberately not a kind-picker case: a source is not a kind, and "casks from taps" must be sayable. Tap packages carry real analytics counts in the popularity sort where covered and sort by name among themselves otherwise.

## Project setting changes

1. `project.pbxproj`: `ENABLE_APP_SANDBOX = YES` → `NO` in **both** app-target configurations (Debug + Release). The app execs brew — impossible sandboxed. `ENABLE_HARDENED_RUNTIME = YES` stays. (Build settings are the only reason to touch the pbxproj; source files are picked up by the synced groups and must never be added by hand.)
2. Delete `Brewery/Item.swift`; strip SwiftData from `BreweryApp.swift`.
3. Update `CLAUDE.md`'s "SwiftUI + SwiftData" line.
4. Bundle metadata, in both app-target configurations, via `GENERATE_INFOPLIST_FILE`'s build settings rather than a checked-in plist: `INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.developer-tools` (a front end for a package manager is developer tooling) and `INFOPLIST_KEY_NSHumanReadableCopyright`. Everything else in the plist — identifier, versions, `LSMinimumSystemVersion`, `CFBundleIconName` — is derived from settings Xcode already sets.
5. `AppIcon.appiconset`: ten PNGs, 16/32/128/256/512 at 1x and 2x. No squircle mask — the source has transparent corners and macOS composites a transparent icon into the standard rounded rect itself. (The emplaced `.icns` carries only four representations; that is the legacy fallback. `CFBundleIconName` + `Assets.car` carry all ten, and that is what the system resolves against.)
6. Nothing else: no checked-in Info.plist, no entitlements file, no packages.

## Tests

Swift Testing for units; no BrewClient integration tests (they'd depend on machine state).

**UI tests exist after all** (`BreweryUITests`, XCTest — XCUITest has no Swift Testing equivalent). The v3 stall was invisible to unit tests and to reasoning about the code; only driving the app found it. They assert thresholds, so a regression fails rather than being noticed months later: search focus < 1 s, keystroke < 0.5 s, scroll < 1 s, plus the grid holding its vertical position when a search narrows to one result and a query surviving a tab switch. Two traps worth knowing: a synthetic `.click()` on the search field only *hovers* on macOS, so tests focus with the app's own ⌘F and **assert the field's value afterwards** — otherwise they measure an empty field and pass while testing nothing; and an element reference captured before the first keystroke goes stale, which XCUITest reports as "application is not running".

- **FuzzySearchTests**: ordering exact > prefix > word-boundary > substring > subsequence; case-insensitivity; no-match → nil; desc-only match ranks below any name match; `"git"` ranks `git` above `gitless`/`gitui`; cask found by display name ("visual studio" → `visual-studio-code`).
- **ParsingTests**: `parseListVersions` — normal lines, multi-version lines (`python@3.12 3.12.1 3.12.4`), empty output, trailing newline. `parseOutdated` — fixture with formulae + casks incl. a pinned entry, empty arrays. Catalog slim-decode — inline fixture snippets copied from real `formula.json`/`cask.json` entries; unknown keys ignored; null `desc`/`homepage` ok.
- **BrewCommandTests**: exact argv per case + the destructive-token tripwire described in [Safety](#safety).
- **(v2) ReceiptTests**: fixture receipt JSONs — `installed_on_request` true/false/absent (absent → `false`, matching brew's `tab.rb`); `runtime_dependencies` extraction with a tap-qualified `full_name` normalized to its short name; cask receipt with object-shaped `runtime_dependencies` decodes without error and yields no deps; missing-file default (→ `onRequest: true`); dependents-map inversion on a three-package fixture.
- **(v3) CatalogV3Tests**: executables.txt line parsing (multi-command line, single, empty input); analytics count parsing (`"1,444,028"` → `1444028`; cask token-keyed dict shape); `Conflict` zipping incl. mismatched array lengths **and null elements**; caveats `$HOMEBREW_PREFIX` substitution; cache-version mismatch → treated as stale; `isFont` classification (`font-fira-code` yes, `firefox` no); `license` decoding, including an object-shaped value yielding nil rather than throwing.
- **(v3) FuzzySearch additions**: exact command match ranks its provider above substring name matches but below a name-exact package; command hit carries `matchedCommand`; `≥ 2 chars` guard on command-prefix matching; font/cask/formula kind filtering composes with command hits (a command can only ever surface a formula).
- **(v3) IconStoreTests**: eviction as a pure function — given `[(name, size, mtime)]` and a cap, returns the files to delete (oldest-first, stops at cap); negative-marker freshness logic (fresh marker → no fetch, expired → fetch).
- **(v4) TapStoreTests**: first-existing-dir rule (a tap with `Formula/` *and* stray root `.rb` ignores the root files); the `class … < Formula` guard (root-level non-formula Ruby emits nothing); versioned-graveyard rule (skipped when the base exists, kept when that exact name is installed); regex fixtures — GoReleaser layout, explicit `version`, missing version (avr-gcc@14 shape), non-string license, escaped quotes in `desc`, interpolated `#{version}` in urls not matching; remote parsing (https with/without `.git`, `git@github.com:` SSH form, unreadable config → nil).
- **(v4) Receipt additions**: `source.tap` fixtures — third-party (`"charmbracelet/tap"` → kept), `homebrew/core`/`homebrew/cask` (→ nil), absent `source` (→ nil), cask receipt shape (same field, same rule).
- **(v4) Parsing additions**: outdated fixture pairing a tap-qualified formula `full_name` with a short cask token — pins that the join rule holds with taps in play.
- **(v4) FuzzySearch additions**: "charmbracelet" surfaces that tap's packages; a qualified-candidate hit never outranks an exact short-name match; qualified scoring never fires for `tap == nil` packages.
- **(v4) BrewCommand additions**: `install(name: "user/repo/foo")` argv is still exactly 3 elements and trips no destructive-token regex.
- **(v6) Taps**: BrewCommand argv for `tap`/`untap` + the widened tripwire (`--custom-remote|--repair|--eval-all` join the forbidden tokens); TrustStore fixtures — the four keys, lowercasing, URL-shaped entries tolerated, missing file → nothing trusted, partial-trust prefix matching; TapInfo collection (counts, FETCH_HEAD mtime) on a fixture tree; `user/repo` validation cases (URLs, dashes, empty rejected).
- **(v5) Services**: BrewCommand argv per case + the widened tripwire (`kill|--file|--sudo-service-user` join the forbidden tokens; "services" joins the first-token whitelist); `parseServicesList` fixtures — all seven statuses, an unknown status string (→ `.other`), null user/exit_code, empty array; `ServiceDefinition` decode — string-vs-array `run`, `keep_alive` object shapes, `require_root`, absent block → nil; run-type humanizer ("Runs continuously" / "Every 5 min" / cron), `$HOMEBREW_PREFIX` substitution in the command line.
- **(v8) MetadataFreshnessTests**: the cache-dir rule (inherited `HOMEBREW_CACHE` override wins, else `~/Library/Caches/Homebrew`); newest-payload stat on a fixture tree — picks the max mtime across `packages.*.jws.json`, ignores the `.payload`/`.payload.index` siblings and `executables.txt`, returns nil for a missing or payload-less directory (nil = maximally stale, the fresh-install case).

## Build order

Each step builds and is independently verifiable (`xcodebuild ... | xcbeautify` per `CLAUDE.md`):

1. **Skeleton** — sandbox off, SwiftData deleted, empty `AppModel`, sidebar with three placeholder sections. *Verify: builds, window looks native.*
2. **Catalog** — `Package`, `CatalogStore`, bootstrap; Discover grid with a plain `contains` filter. *Verify: ~16k packages render; second launch is instant from cache.*
3. **Search** — `FuzzySearch` + tests; debounced wiring. *Verify: tests pass; "wget" and "visual studio" find the right things.*
4. **Read state** — `BrewCommand` read cases, `BrewClient` + parsers + tests; Installed/Outdated sections; status on Discover cards. *Verify: matches `brew list` / `brew outdated` in Terminal.*
5. **Mutations** — mutating cases, `BrewOperation`, queue + pump, live logs, buttons, popover, post-op refresh, session `brew update`. *Verify: install a tiny formula (e.g. `cowsay`), watch the live log, card flips to installed.*
6. **Icons** — URLCache + `PackageIconView`. *Verify: favicons appear; offline relaunch still shows cached ones.*
7. **Polish** — detail sheet, askpass helper (verify with a pkg cask), menu commands, empty states, Upgrade All.
8. **v2: Filters & dependencies** — `Receipts.swift` + tests, `InstalledInfo` fields, dependents inversion, Discover filter menu, Installed scope picker, detail Dependencies/Required-by sections. *Verify: tests pass; Installed "On Request" matches `brew list --installed-on-request` in Terminal; a known dep (e.g. `ca-certificates`) shows its dependents and carries the "dependency" mark under All; kind filter + hide-deprecated visibly shrink Discover.*
9. **v3** — in sub-steps, each buildable:
   a. *Catalog v3*: `Package` fields + `Conflict`, five-file download/merge, cache `version`, command index. *Verify: tests pass; vim's detail data would show 3 conflicts with reasons; searching `convert` surfaces imagemagick with "Provides `convert`"; count matches `grep -c` of executables.txt for a known formula.*
   b. *Detail sections*: installs stat, caveats (prefix substituted — check php's), commands, conflicts. *Verify: vim shows caveats + conflicts; a font cask shows neither favicon fetch nor commands.*
   c. *Shell*: per-tab queries, `.navigationSubtitle` counts, windowed grid, Fonts filter. *Verify: search Discover, switch to Installed (empty), return (restored); clearing a 16k-item search no longer hitches; subtitle count equals visible count.*
   d. *IconStore*: store + tests, `PackageIconView` rewire. *Verify: cold launch, scroll fast — icons fill in without the "loads only after clicking" bug; relaunch offline — icons persist; `Icons/` dir stays under 50 MB.*
10. **v4: Taps** — in sub-steps, each buildable:
   a. *TapStore + tests*: scan, regex parsers, graveyard rule, remote parsing. *Verify: tests pass; scan output on this machine lists charmbracelet/osx-cross/oven-sh/supabase/unhappychoice packages, exactly one `bun`, nothing from the homebrew/homebrew-cask clone.*
   b. *Data + compose*: `Package.tap`, `InstalledInfo.tap` (+ receipt normalization), `tapInstalls90d`, `composeCatalog`, `catalogGeneration` into `SearchKey`/`BrowseKey`. *Verify: existing tests stay green untouched; `gum` appears in Discover; installed tap items stop being synthesized (desc/homepage present).*
   c. *Commands*: effective-tap qualification with the scan-membership guard. *Verify: BrewCommand tests; a tap item's Update enqueues `upgrade --formula charmbracelet/tap/<name>`.*
   d. *UI*: card owner tag, detail spigot row + trust caption, tap-aware source link, Taps filter. *Verify: screenshot loop — tap card, tap detail, Taps filter view, mixed-row card heights.*
   e. *Perf gate*: the existing UI-test thresholds on the tap-augmented catalog. *Verify: search focus < 1 s, keystroke < 0.5 s, scroll < 1 s still pass.*
11. **v5: Services** — in sub-steps, each buildable:
   a. *Data*: `ServiceDefinition` + lenient catalog decode, cache v7, decode tests. *Verify: redis decodes run/keep_alive/log_path; a formula without a service block stays nil.*
   b. *Commands*: the three `BrewCommand` cases, client env var, `parseServicesList` + tests. *Verify: argv exact; tripwire green.*
   c. *Model*: `serviceStatuses` overlay in `refreshState`, `startService`/`stopService` (no session update). *Verify: overlay matches `brew services list` in Terminal.*
   d. *UI*: sidebar section + badge, `ServicesView`, detail Service section, shared toggle. *Verify: screenshots — mixed states incl. atuin's error, toggle mid-flight spinner, redis detail.*
   e. *Live + perf*: toggle redis on/off through the queue; UI thresholds unchanged.
12. **v6: Taps tab** — in sub-steps, each buildable:
   a. *TapInfo + TrustStore + tests*. *Verify: six real taps with true counts/dates; charmbracelet derives "2 items trusted".*
   b. *Commands + model actions + tests*. *Verify: argv exact; validation rejects URLs and flags.*
   c. *TapsView + routing*. *Verify: screenshots — list with live trust spectrum, tap page, popover, dialog.*
   d. *Live round trip*: add a small tap through the queue, remove it again; Remove disabled for a tap with installed packages. *Verify: perf thresholds unchanged.*

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| pkg-cask sudo hangs/fails with piped stdio | `SUDO_ASKPASS` osascript helper + `HOMEBREW_NO_ASK=1`; cancelled dialog fails fast with a readable log line; manually verified with a real pkg cask in step 7 |
| `HOMEBREW_NO_AUTO_UPDATE=1` → stale brew metadata (bottle 404s, older installs, **a lying Outdated section**) | *(v8)* the freshness rule: launch, ⌘R and package mutations all run `brew update` first whenever the API payload mtime is older than brew's own 450 s window; terminal updates count via the same mtime; offline falls back to cache silently with a one-attempt-per-window backoff |
| ~48 MB raw JSON decode (peak a few × that) | `@concurrent`, transient, ≤1×/day; slim ~8 MB cache makes normal launches instant; swappable inside `CatalogStore` if ever needed |
| Concurrent brew invocations (user runs brew in Terminal mid-operation) | brew's flock fails our op immediately with a readable error in the log — surfaced, not retried |
| *(v3)* `api/internal/executables.txt` is an undocumented endpoint and could move | its failure degrades to empty `commands` — catalog, search-by-name, everything else unaffected; brew's local cache copy is a known fallback if it ever dies for good |
| *(v3)* analytics counts join by name across ~32k tap-inclusive entries | exact-name join; tap formulae match only through the v4 qualified-key join (`tapInstalls90d`) — no mis-attribution possible |
| *(v4)* installing a tap item auto-trusts it persistently (brew-side, `trust.rb:116-145`) | disclosed on the install button (`.help` + caption); no other trust writes exist — the whitelist has no trust commands |
| *(v4)* untrusted-tap installed formulae vanish silently from `brew outdated` (`formula.rb:2649-2655`) | accepted: such items look up to date and Upgrade All skips them; installing anything from the tap via Brewery trusts it and restores visibility |
| *(v4)* a stale receipt naming a since-untapped tap would make brew re-clone it on a qualified upgrade | qualification requires the tap to be present in the current scan; otherwise the short name is passed |
| *(v4)* same short name in two sources (core vs tap, tap vs tap) | deterministic winner (core, then alphabetically-first tap); loser invisible in Discover but its installed state joins the winner's card — the v1 accepted-collision rule, extended |
| *(v5)* services exit codes lie (warnings exit 0) | never trust the code: the post-operation `refreshState` re-reads `services list --json` after every toggle |
| *(v5)* untrusted-tap services vanish silently from `services list` (brew-side bare `rescue`) | accepted; Brewery-installed tap items are auto-trusted, and the section is defined as "what brew reports" |
| *(v5)* `require_root` services started as user warn-and-fail later | toggle disabled with a "requires root" caption instead of offering a start that lies |
| *(v6)* trust entries survive untap and reapply on re-tap (brew-side) | disclosed in the removal dialog; trust management itself stays in the terminal |
| *(v6)* "already tapped" exits 0 silently — success and no-op look identical | the post-op rescan is the truth; the row list, not the exit code, tells the user what happened |
| *(v6)* tap progress arrives on stderr | the operation log merges both streams already; nothing is discarded |
