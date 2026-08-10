# Brewery

A native macOS app for Homebrew. SwiftUI, no third-party dependencies.

Search the full catalog of roughly 16,000 formulae and casks, see what you have
installed, update it, and manage background services, all without opening a
terminal. Packages from your third-party taps show up too, read straight off
disk.

## What it does

- Fuzzy search across everything, including the commands a formula provides:
  typing `convert` finds `imagemagick`, and the card tells you why it matched.
- Browsing sorted by popularity, with filters for kind (formulae, casks, fonts)
  and source (taps only), plus an on-request scope so dependencies stay out of
  your way.
- Package pages with install counts, caveats rendered the way brew means them
  (copyable command blocks included), provided commands, cask contents, service
  details, conflicts, licenses, and a navigable dependency graph.
- Install and update, per package or all at once, with live logs and a
  cancellable queue.
- A Services tab in the style of Login Items: see every brew service, its
  status, and a switch to start or stop it.

## Non-destructive by design

Brewery installs, upgrades, and toggles services. It cannot uninstall, clean
up, pin, or zap. This is enforced by construction rather than by discipline:
every brew invocation comes from a closed enum of ten commands, nothing execs
brew with arbitrary arguments, and a test fails the build if a destructive
token ever shows up. Brew's own periodic cleanup, which install and upgrade
normally trigger, is switched off on every invocation.

## Requirements

- macOS 26 or later
- [Homebrew](https://brew.sh) at `/opt/homebrew` (Apple silicon) or
  `/usr/local` (Intel). If it is missing, the app says so and links to the
  installer.

The app is not sandboxed. It runs the `brew` binary, which a sandbox would
forbid.

## Building

```sh
xcodebuild -project Brewery.xcodeproj -scheme Brewery -configuration Debug build
xcodebuild test -project Brewery.xcodeproj -scheme Brewery -destination 'platform=macOS' -only-testing:BreweryTests
```

`ARCHITECTURE.md` documents the design and the Homebrew behavior it depends
on. `CLAUDE.md` has the day-to-day commands.

## License

MIT, see [LICENSE](LICENSE).
