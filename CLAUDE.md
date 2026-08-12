# Brewery

macOS app: SwiftUI, Xcode 26 project, single scheme `Brewery`. No third-party dependencies. See `ARCHITECTURE.md` — it is the spec, not an afterthought: features are designed there first (versioned inline as v1…v7), each grounded in facts verified against the Homebrew source, then implemented. A local brew checkout for verifying such facts lives at `/Users/vzbarashchenko/Code/github/brew` — cite `file:line` from it rather than trusting memory; brew 6.x changed a lot (tap trust gate, services in core).

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

- **Safety whitelist**: every brew argv comes from the `BrewCommand` enum — no raw-argument path exists. Adding a case trips an exhaustive-switch tripwire in `BrewCommandTests` until the case is tagged, listed, and its first token whitelisted; destructive tokens (`uninstall`, `cleanup`, `kill`, `--force`, `--file`, …) fail the build.
- **The join rule**: overlay keys are `kind:shortname`; brew output is normalized through `BrewClient.shortName`. Package names stay short — taps are a separate `Package.tap` field, and commands get tap-qualified only in `AppModel.install/upgrade/…Service` via the effective-tap rule.
- **Cache version** (`CatalogStore.cacheVersion`): bump whenever `Package`'s stored shape changes, and update the pinned value in `CatalogV3Tests`. Optional additions that decode correctly as nil for old caches (like `tap`) don't need a bump.
- **Performance**: never pass a large `[Package]`/`[SearchHit]` across a view boundary (the attribute graph copies and diffs stored properties — this once cost 6 s per keystroke). The UI tests pin search focus < 1 s, keystroke < 0.5 s, scroll < 1 s.
- **View invalidation**: browse/search re-run off `catalogGeneration` (not counts) — a tap rescan can change the catalog at equal size.

## Design

Top-class UI/UX is a hard requirement, not a nice-to-have. Follow Apple HIG and native macOS patterns (System Settings grammar for controls — a switch always terminates a labeled row; App Store composition for catalog metadata — pills for identity, `·`-joined text for state; Login Items for service rows); prefer stock components with Liquid Glass chrome over custom drawing. A source is not a kind: keep filter dimensions orthogonal. Verify every visible change with the screenshot loop before committing. Three rules the HIG pass (v7) made non-negotiable:

- **Nothing modal for reading.** Detail is a non-modal `.inspector` pane; the listing stays live beside it. A surface that grows its own footer, back button and navigation is an app inside the app.
- **Every toolbar action has a menu bar command and a key equivalent.** Destinations are ⌘1…⌘5; show/hide items name the state they will produce.
- **Every animation has a Reduce Motion branch.** x-axis slides become crossfades, blurs are dropped, repeating symbol effects hold still.

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
- `app.scrollViews.firstMatch` is the *sidebar*; find grid cards with `app.buttons.matching(NSPredicate(format: "label CONTAINS '…'"))`.
- ⌘F focus lands asynchronously — `sleep(1)` before ⌘A/typing, and assert the field's value (or retry) before trusting timings.
- After a `cacheVersion` bump the catalog re-downloads: wait for cards (`label CONTAINS 'Formula'`, generous timeout), not a fixed sleep.
- macOS switches are `app.checkBoxes[...]` by accessibility label; popovers are separate windows — capture `XCUIScreen.main` to see them.
- Prefer assertions over eyeballs where possible (frame equality for "no layout shift", `isHittable` for "restored scroll").

## Commits

Feel free to commit sparingly when needed — one commit per coherent feature or fix; relaunch the app afterward so the user sees the result.
