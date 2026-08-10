# Brewery

A native macOS app for browsing and managing Homebrew packages.

Search the full catalogue — around 16,000 formulae and casks — see what you have
installed, and keep it up to date, without leaving the keyboard or reaching for a
terminal. Written in SwiftUI with no third-party dependencies.

## What it does

- **Search everything.** Fuzzy matching across the whole catalogue, including by the
  commands a formula provides: typing `convert` finds `imagemagick`, and the card says
  why it matched.
- **Filter what you browse.** Formulae, casks, or fonts; optionally hiding deprecated
  packages. Installed narrows to what you asked for rather than everything that came
  along as a dependency.
- **See the whole package.** Install counts over the last 90 days, caveats with the real
  Homebrew prefix substituted in, provided commands, conflicts, license, dependencies,
  and — for anything pulled in as a dependency — what required it.
- **Install and update.** Per package or everything at once, with live output, a queue
  you can cancel from, and cards that flip as operations land.

## Non-destructive by design

Brewery can install and upgrade. It cannot uninstall, clean up, pin, or zap, and this is
enforced by construction rather than by discipline: every brew invocation comes from a
closed enum of seven commands, there is no path that execs brew with arbitrary arguments,
and a test fails the build if a destructive token ever appears in one. `brew`'s own
periodic cleanup — which `install` and `upgrade` trigger by default — is switched off on
every invocation.

## Requirements

- macOS 26 or later
- [Homebrew](https://brew.sh) at `/opt/homebrew` (Apple silicon) or `/usr/local` (Intel).
  If it is missing, the app says so and links you to the installer.

The app is not sandboxed, because it runs the `brew` binary.

## Building

```sh
xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Debug build
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests
```

`ARCHITECTURE.md` documents the design and the Homebrew behaviour it depends on;
`CLAUDE.md` has the day-to-day commands.

## License

MIT — see [LICENSE](LICENSE).
