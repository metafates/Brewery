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
- Install, update, and uninstall, per package or all at once, with live logs
  and a cancellable queue. Uninstalling always confirms first, and a cask that
  documents its own leftovers offers to remove its app data too.
- A Services tab in the style of Login Items: see every brew service, its
  status, and a switch to start or stop it.

## Destructive only on purpose

Brewery installs, upgrades, uninstalls, and toggles services. Every removal is
confirmed before anything runs, and what brew can be asked to do is enforced
by construction rather than by discipline: every invocation comes from a
closed enum of commands, nothing execs brew with arbitrary arguments, and a
test fails the build if a forbidden token — `--force`,
`--ignore-dependencies`, `cleanup`, `pin`, and friends — ever shows up in an
argv. Brew's implicit destruction is switched off on every invocation too:
the periodic cleanup that install and upgrade normally trigger, and the
autoremove cascade that follows an uninstall (orphaned dependencies surface
in the app's own Orphans report instead, where removing them is its own
confirmed decision).

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
