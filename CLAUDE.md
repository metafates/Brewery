# Brewery

macOS app: SwiftUI, Xcode 26 project, single scheme `Brewery`. No third-party dependencies. See `ARCHITECTURE.md`.

## Build & test (all headless, no Xcode GUI needed)

```bash
# Build (Debug)
xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Debug build | xcbeautify

# Unit tests (fast, headless) — Swift Testing (@Test / #expect), NOT XCTest
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests | xcbeautify

# UI tests (launches the app, needs automation permission — run sparingly)
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryUITests | xcbeautify

# Run the built app
open "$(xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/Brewery.app"
```

## Project notes

- Targets use filesystem-synchronized groups: a new `.swift` file dropped into `Brewery/`, `BreweryTests/`, or `BreweryUITests/` is picked up automatically — never edit `project.pbxproj` to add files.
- Unit tests use the Swift Testing framework (`import Testing`, `@Test`, `#expect`), not XCTest.
- `buildServer.json` (gitignored, machine-specific) bridges sourcekit-lsp to the Xcode project. Regenerate if the scheme changes:
  `xcode-build-server config -project Brewery.xcodeproj -scheme Brewery`

## Design

Top-class UI/UX is a hard requirement, not a nice-to-have. Follow Apple HIG and native macOS
patterns (System Settings grammar for controls, App Store composition for catalog surfaces);
prefer stock components with Liquid Glass chrome over custom drawing. Verify every visible change
with the screenshot loop (temporary XCTest attachment walk) before committing.

## Commits

Feel free to commit sparingly when needed.
