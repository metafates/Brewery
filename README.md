# Brewery

A native macOS app for Homebrew. SwiftUI, no third-party dependencies.

Search roughly 16,000 formulae and casks, install and update them, run
services, manage taps, and let Homebrew diagnose itself, all without opening
a terminal.

## Features

- Fuzzy search over names, descriptions and provided commands: `convert`
  finds `imagemagick`
- Package pages with caveats, on-disk sizes, licenses, dependencies,
  conflicts and cask contents
- Install, update and uninstall with live logs and a cancellable queue
- Services in the style of Login Items, with start/stop switches
- Taps with brew 6's trust model built into the UI
- Reports: Orphans, Attention, Storage, and Checkup (`brew doctor`, made
  actionable)
- Every action has a menu bar command and a keyboard shortcut

## Safety

Every brew invocation comes from a closed enum of commands — a test fails the
build if a destructive token ever appears in an argv. Removals are confirmed
before anything runs, and brew's implicit cleanup and autoremove are switched
off on every invocation.

## Requirements

macOS 26 or later, and [Homebrew](https://brew.sh). The app is not sandboxed:
it runs the `brew` binary, which a sandbox would forbid.

## Building

```sh
make run        # Debug build, then launch
make install    # Release build into /Applications
make test       # unit tests, headless
make test-ui    # UI tests; needs automation permission
```

`ARCHITECTURE.md` is the spec; `CLAUDE.md` has the day-to-day commands.

## License

MIT, see [LICENSE](LICENSE).
