# Brewery

macOS app: SwiftUI, Xcode 26 project, single scheme `Brewery`. No third-party dependencies. See `ARCHITECTURE.md` — it is the spec, not an afterthought: features are designed there first, each grounded in facts verified against the Homebrew source, then implemented — and the document is a current-state spec, rewritten in place as the system changes (no inline version numbering; history lives in git). A local brew checkout for verifying such facts lives at `/Users/vzbarashchenko/Code/github/brew` — cite `file:line` from it rather than trusting memory; brew 6.x changed a lot (tap trust gate, services in core).

## Build & test (all headless, no Xcode GUI needed)

```bash
# Build (Debug)
xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Debug build | xcbeautify

# Unit tests (fast, headless) — Swift Testing (@Test / #expect), NOT XCTest
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests | xcbeautify

# UI tests (launches the app, needs automation permission — run sparingly; they pin perf thresholds)
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryUITests | xcbeautify

# Run the built app
open "$(xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/Brewery.app"
```

## Project notes

- Targets use filesystem-synchronized groups: a new `.swift` file dropped into `Brewery/`, `BreweryTests/`, or `BreweryUITests/` is picked up automatically — never edit `project.pbxproj` to add files.
- Unit tests use the Swift Testing framework (`import Testing`, `@Test`, `#expect`), not XCTest.
- `buildServer.json` (gitignored, machine-specific) bridges sourcekit-lsp to the Xcode project. Regenerate if the scheme changes:
  `xcode-build-server config -project Brewery.xcodeproj -scheme Brewery`
- SourceKit diagnostics often lag freshly created types/members — trust `xcodebuild`, not the editor squiggles.
- Bundle id is `one.metafates.Brewery`. If a UI test mutates `@AppStorage` (filters, scopes), reset with `defaults delete one.metafates.Brewery <key>` afterward so the user's app doesn't launch mysteriously filtered.

## Invariants that tests enforce (know before touching)

- **Safety whitelist**: every brew argv comes from the `BrewCommand` enum — no raw-argument path exists. Adding a case trips an exhaustive-switch tripwire in `BrewCommandTests` until the case is tagged, listed, and its first token whitelisted; destructive tokens (`rm`, `zap`, `--force`, `--ignore-dependencies`, `--prune`, …) fail the build. (`uninstall`, `cleanup` and `pin`/`unpin` are whitelisted with exactly pinned argvs — the ban list is not the place to check what's allowed.)
- **Confirmed-before-enqueue (the trust-write rule)**: setting a pending state enqueues nothing — the dialog runs before the model does, and an ellipsis in a button/menu title promises that dialog. Menu items must open the *same* dialog their content button does (the dialogs live on ContentView's root so they can present from any section).
- **The join rule**: overlay keys are `kind:shortname`; brew output is normalized through `BrewClient.shortName`. Package names stay short — taps are a separate `Package.tap` field, and commands get tap-qualified only in `AppModel.install/upgrade/…Service` via the effective-tap rule.
- **Cache version** (`CatalogStore.cacheVersion`): bump whenever `Package`'s stored shape changes, and update the pinned value in `CatalogV3Tests`. Optional additions that decode correctly as nil for old caches (like `tap`) don't need a bump.
- **Performance**: never pass a large `[Package]`/`[SearchHit]` across a view boundary (the attribute graph copies and diffs stored properties — this once cost 6 s per keystroke). The UI tests pin search focus < 1 s, keystroke < 0.5 s, scroll < 1 s. The pins sit near the dev machine's noise floor (the same commit has produced 0.39–0.69 s keystrokes across runs under load): before concluding a change regressed a timing, A/B it interleaved (`git stash push -- Brewery/` → run → `git stash pop` → run, ≥3×) — two sequential batches once "showed" an 18% regression that interleaving dissolved. Never relax a threshold to green a suite; they pass on a rested machine.
- **View invalidation**: browse/search re-run off `catalogGeneration` (not counts) — a tap rescan can change the catalog at equal size.

## Design

Top-class UI/UX is a hard requirement, not a nice-to-have. Follow Apple HIG and native macOS patterns (System Settings grammar for controls — a switch always terminates a labeled row; App Store composition for catalog metadata — pills for identity, `·`-joined text for state; Login Items for service rows); prefer stock components with Liquid Glass chrome over custom drawing. A source is not a kind: keep filter dimensions orthogonal. Verify every visible change with the screenshot loop before committing. Three rules the HIG pass made non-negotiable:

- **Nothing modal for reading.** Detail is a non-modal `.inspector` pane; the listing stays live beside it. A surface that grows its own footer, back button and navigation is an app inside the app.
- **Every toolbar action has a menu bar command and a key equivalent.** Destinations are ⌘1…⌘5; show/hide items name the state they will produce.
- **Every animation has a Reduce Motion branch.** x-axis slides become crossfades, blurs are dropped, repeating symbol effects hold still.

Two review lessons that keep recurring:

- **Argue back.** The maintainer explicitly wants pushback: when a request contradicts HIG or a more idiomatic pattern exists (even a complete rethink), say so with the citation instead of implementing literally — reasoned, named-pattern-backed rejections get accepted (a "label the source link 'formula'" request became kind-correct Formula/Cask; "trim the font preview" became killing the expander with Font Book as the specimen browser).
- **When chrome fails in every container, question the control, not the styling.** The old Installed scope picker went toolbar → hand-rolled band → `accessoryBar`, each flagged in review, because it fused a filter with two reports; the fix was information architecture (a Filter-menu toggle plus a sidebar Reports group), not another container. Before drawing any bar/band/chip by hand, ask which platform component already draws the pattern — and if a control keeps failing across containers, it's usually two ideas in one widget.

### Load the HIG skills — always, before touching UI

"Follow Apple HIG" is a checkable claim, not a vibe. Before writing or reviewing any UI in this repo, load the `apple-hig-skills` skills that cover the surface you are touching, and cite the rule you are applying. Do not design macOS UI from memory — this pass found four structural divergences that all read fine until the actual guidance was open next to the code.

Always load `apple-hig-skills:hig-platforms` (macOS: menu bar, window management, keyboard, personalization, "fewer nested levels and less need for modality"). Then, by surface:

| Touching | Load |
|---|---|
| sidebar, split view, the window, lists, the inspector pane | `hig-components-layout` |
| toolbar, menu bar commands, context menus, buttons | `hig-components-menus` |
| sheets, popovers, alerts, confirmation dialogs | `hig-components-dialogs` |
| pickers, toggles, sliders, text fields, labels | `hig-components-controls` |
| the search field, its scopes and suggestions | `hig-components-search` |
| progress and status | `hig-components-status` |
| modality, feedback, loading, settings, onboarding, help, undo | `hig-patterns` |
| color, typography, SF Symbols, motion, materials, accessibility, UI copy | `hig-foundations` |
| keyboard shortcuts, pointer, gestures | `hig-inputs` |
| VoiceOver and other Apple framework integrations | `hig-technologies` |

The skill landing page is only an index: **read the specific `references/*.md`** it points at (`references/modality.md`, `references/toolbars.md`, …). Those files list the rule headings verbatim, which is what makes a claim like "HIG *Toolbars* → macOS: make every toolbar item available as a command in the menu bar" quotable in a commit message or an `ARCHITECTURE.md` entry.

When guidance and this repo's committed grammar disagree, say so in `ARCHITECTURE.md` rather than silently picking one — the deliberate divergences (no Settings scene, no `.searchScopes`, no `.searchSuggestions`, manual page stack instead of `NavigationStack`) are recorded there with their reasons, and the reason is the useful part.

## The screenshot loop (visual verification)

The terminal has no Screen Recording permission, so `screencapture` fails. Instead: write a temporary `*ShotTests.swift` in `BreweryUITests/` that walks the UI and saves `XCTAttachment(screenshot: app.windows.firstMatch.screenshot())` with `.lifetime = .keepAlways`; run it with `-resultBundlePath`, export via `xcrun xcresulttool export attachments`, map names through the exported `manifest.json`, Read the PNGs, then **delete the test file**. Traps learned the hard way:

- Scope sidebar clicks: `app.outlines["Sidebar"].staticTexts[...]` — bare `staticTexts["Installed"]` also matches card state labels.
- `app.scrollViews.firstMatch` is the *sidebar*; find grid cards with `app.buttons.matching(NSPredicate(format: "label CONTAINS '…'"))`. A card's AX label includes its description text — anchor card queries on a desc fragment (`label CONTAINS 'Clone of cat(1)'`) when the name alone would also match pane buttons like "Uninstall bat".
- ⌘F focus lands asynchronously — `sleep(1)` before ⌘A/typing, and assert the field's value (or retry) before trusting timings.
- After a `cacheVersion` bump the catalog re-downloads: wait for cards (`label CONTAINS 'Formula'`, generous timeout), not a fixed sleep.
- macOS switches are `app.checkBoxes[...]` by accessibility label; popovers are separate windows — capture `XCUIScreen.main` to see them.
- Prefer assertions over eyeballs where possible (frame equality for "no layout shift", `isHittable` for "restored scroll").
- UI tests must not write the user's real defaults: launch with `UITestSeed.pinnedState` (BreweryUITests.swift) — it pins sidebar section and filters through the argument domain, which evaporates with the process. Two traps inside it: bare flags (`-demo-operation`) go AFTER the `-key value` pairs (a leading bare flag swallows the next key as its *value*), and the argument domain SHADOWS in-app `@AppStorage` writes — a test that must *change* a filter must not seed that key, and must `defaults delete one.metafates.Brewery <key>` for everything it touched afterwards. `@AppStorage` state is INVISIBLE to `defaults read` (both plists show only window frames, yet state persists) — never rule out a persisted filter by reading plists; open the actual menu in a shot test and read the checkmarks.
- Under the automation session, AppKit window restoration can wedge before any window exists (macOS 26.5.2: app goes "Restoring windows" → `restoration_storage` → silence; every UI test fails with "never showed a window" while a plain `open` works). `UITestSeed.pinnedState` carries `-ApplePersistenceIgnoreState YES` for this — any launch that skips the seed needs it too.
- Cards carry `.accessibilityIdentifier("PackageCard")` — query `app.buttons.matching(identifier: "PackageCard")`; frame-size filtering silently drops short cards. `waitForCatalog` in BreweryUITests is the canonical "cards are on screen" wait.
- Menu items are queryable WITHOUT opening their menu (~200 items across all menus enumerate closed), and the `menuItems["Close"]` subscript binds a label menu items don't carry — assert via one bound walk (`menuBarItem.menuItems.allElementsBoundByIndex.map(\.title)`). Clicking a menuBarItem and then re-querying its children can hang the runner mid-menu-tracking.
- Every UI-test invocation writes a ~500 MB xcresult (it archives system logs) under `DerivedData/Brewery-*/Logs/Test/` — delete them after reading results, or a full disk crashes the importer with `tracev3 … ioError`.
- A SwiftUI window's AX title fuses `.navigationTitle` and `.navigationSubtitle` with an en dash ("Title – Subtitle"), so `app.windows["Title"]` misses — match `identifier BEGINSWITH '<scene-id>'` (WindowGroup windows get `<id>-AppWindow-N`).
- Toolbar menu items collide with their View-menu twins in queries — scope to `app.toolbars.menuItems[...]`. A borderless SwiftUI `Menu` exposes as `app.menuButtons`, NOT `popUpButtons`/`buttons` — and `popUpButtons[...].waitForExistence` can return true while the click's re-resolution then fails; query `menuButtons` by label predicate and click fresh.
- Bare `app.buttons["Cancel"]` can match a *Touch Bar* element (click fails with "cannot be called with Touch Bar elements") — scope confirmationDialog buttons to `app.sheets.buttons[...]` (dialogs render as sheets), `typeKey(.escape)` as fallback.
- To learn what a control actually exposes, print `element.debugDescription` in a temp test and grep the output (this found the Operations button vanishing when a ProgressView sat in its label).
- State that only exists mid-mutation (the operations queue) is seeded via a launch argument (`-demo-operation`), not by mutating the machine — for *flows* (install/uninstall clicks, error paths, brew-missing), use the deterministic harness instead: build a `Scenario` (BreweryUITests/UITestScenario.swift) and the app runs against a fake brew + stubbed network with the real code in between (see ARCHITECTURE.md "The deterministic UI-test harness"; `HarnessTests.swift` has the shapes). Harness launches never touch real brew, the real support dir, or the network.
- The runner can *read* files the app wrote under the fixture root but gets EPERM *writing* them — to alter app-written state between launches, read it, transform in memory, and ship it back through the scenario payload (`seedFile`) so the app overwrites its own file.
- **Verifying animations** (screenshots are too slow — click→screenshot latency outruns a 0.3 s slide): end the temp test with a deliberate `XCTFail("keep the screen recording")` — only *failed* tests keep the ~120 fps screen recording. Export it like any attachment, find the moment with `ffmpeg -vf "select='gt(scene,0.03)',showinfo"` (a gradual animation produces *no* scene cut; a broken instant swap does), then extract frames (`-ss T -t 0.9 -vf fps=30`) and Read the mid-flight ones; per-frame PNG sizes are a quick proxy for smooth ramp vs cut. Related fact: macOS `NavigationStack` does NOT animate pushes in a split-view detail column (iOS does) — the tap drill-down is manual (ZStack + offset, list stays mounted) for this reason, and a pushed page's listing must be prefilled synchronously before `withAnimation`, or it slides in empty and reads as a cut.

## Commits

Feel free to commit sparingly when needed — one commit per coherent feature or fix; a multi-part request lands as separate commits (the maintainer asks for this by name); relaunch the app afterward so the user sees the result.
