//
//  AppModel.swift
//  Brewery
//

import Foundation
import Observation

/// The single root of app state: the catalog, the install-state overlays, and the FIFO queue that
/// serializes every mutating brew invocation. Main-actor isolated like everything else, so the
/// queue needs no locks.
@Observable
final class AppModel {
    var catalog: [Package] = []
    var catalogLoading = false
    var catalogFailed = false

    /// Overlays are keyed by `Package.ID` (`kind:shortname`) and never persisted — they are
    /// under a second to re-query.
    var installed: [Package.ID: InstalledInfo] = [:]
    var outdated: [Package.ID: OutdatedInfo] = [:]

    var operations: [BrewOperation] = []
    var brewMissing = false

    /// Set once when an operation fails so the operations popover can auto-present; the view
    /// clears it after showing.
    var failureToPresent: BrewOperation?

    /// Bumped by the ⌘F menu command. `ContentView` observes it and moves focus to the search
    /// field — the automatic ⌘F binding has historically been unreliable on macOS.
    private(set) var findRequests = 0

    let client = BrewClient()

    private var catalogFetchedAt: Date?
    private var didBootstrap = false
    private var didEnqueueSessionUpdate = false
    private var runningTask: Task<Void, Never>?

    init() {
        brewMissing = !client.isAvailable
    }

    // MARK: - Loading

    /// Cache first so the grid is populated immediately, then the installed/outdated probes and
    /// (only if the catalog is stale or absent) the download run concurrently.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        let cache = CatalogStore.loadCache()
        if let cache {
            catalog = cache.packages
            catalogFetchedAt = cache.fetchedAt
        }

        let state = Task { await self.refreshState() }
        if cache.map({ CatalogStore.isStale($0.fetchedAt) }) ?? true {
            await loadCatalog()
        }
        await state.value
    }

    /// ⌘R: re-probe brew, re-read installed/outdated, and re-run the 24 h catalog staleness check.
    func refresh() async {
        client.discover()

        let state = Task { await self.refreshState() }
        if catalogFetchedAt.map(CatalogStore.isStale) ?? true {
            await loadCatalog()
        }
        await state.value
    }

    func retryCatalog() async {
        await loadCatalog()
    }

    private func loadCatalog() async {
        guard !catalogLoading else { return }
        catalogLoading = true
        catalogFailed = false
        defer { catalogLoading = false }

        do {
            let cache = try await CatalogStore.fetch()
            catalog = cache.packages
            catalogFetchedAt = cache.fetchedAt
        } catch {
            // A stale catalog still beats an error screen; only a cold start with no cache fails.
            catalogFailed = catalog.isEmpty
        }
    }

    /// Both reads at once — brew serializes only mutations, so concurrent reads are safe.
    private func refreshState() async {
        brewMissing = !client.isAvailable
        guard client.isAvailable else {
            installed = [:]
            outdated = [:]
            return
        }

        let installedTask = Task { try await self.client.listInstalled() }
        let outdatedTask = Task { try await self.client.outdated() }

        if let result = try? await installedTask.value { installed = result }
        if let result = try? await outdatedTask.value { outdated = result }
    }

    // MARK: - Derived state

    func status(for package: Package) -> PackageStatus {
        if isBusy(package) { return .busy }
        if let info = outdated[package.id] {
            return .outdated(installed: info.installed.last ?? "", current: info.current)
        }
        if let info = installed[package.id] {
            return .installed(version: info.versions.last ?? package.version)
        }
        return .notInstalled
    }

    /// A bare `brew upgrade` touches every outdated formula and cask except the pinned ones, so a
    /// running `upgradeAll` makes all of them busy at once.
    private func isBusy(_ package: Package) -> Bool {
        for operation in operations where !operation.isFinished {
            if operation.targetID == package.id { return true }
            if operation.command == .upgradeAll, operation.state == .running,
               let info = outdated[package.id], !info.pinned {
                return true
            }
        }
        return false
    }

    /// Catalog entries that are installed, plus synthesized ones for anything installed from a tap
    /// the catalog does not cover.
    var installedPackages: [Package] {
        merged(catalog.filter { installed[$0.id] != nil },
               with: installed.mapValues { $0.versions })
    }

    var outdatedPackages: [Package] {
        merged(catalog.filter { outdated[$0.id] != nil },
               with: outdated.mapValues(\.installed))
    }

    var outdatedCount: Int { outdated.count }

    /// Third-party taps are absent from formulae.brew.sh, so all we can honestly show for them is
    /// the name, the kind and the version that is on disk.
    private func merged(_ known: [Package], with versions: [Package.ID: [String]]) -> [Package] {
        var result = known
        let covered = Set(known.map(\.id))
        for (id, installedVersions) in versions where !covered.contains(id) {
            guard let package = Self.synthesize(id: id, versions: installedVersions) else { continue }
            result.append(package)
        }
        return result.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.kind.rawValue < rhs.kind.rawValue : lhs.name < rhs.name
        }
    }

    private static func synthesize(id: Package.ID, versions: [String]) -> Package? {
        guard let separator = id.firstIndex(of: ":"),
              let kind = PackageKind(rawValue: String(id[id.startIndex..<separator])) else { return nil }
        return Package(kind: kind,
                       name: String(id[id.index(after: separator)...]),
                       displayName: nil,
                       desc: nil,
                       homepage: nil,
                       version: versions.last ?? "",
                       deprecated: false,
                       disabled: false)
    }

    // MARK: - Operation queue

    /// Mutating commands only: reads never queue. Runs one at a time, FIFO, and a failure never
    /// halts or drains what is behind it.
    func enqueue(_ command: BrewCommand, title: String, targetID: Package.ID?) {
        guard command.isMutating else { return }
        // A catalog entry can never start with a dash, but brew would read one as a flag if it did.
        switch command {
        case let .install(name, _), let .upgrade(name, _):
            guard !name.isEmpty, !name.hasPrefix("-") else { return }
        default:
            break
        }

        // Auto-update is disabled on every invocation, so brew's metadata can drift; one explicit
        // `brew update` per session, ahead of the first mutation, brings it back in line.
        if !didEnqueueSessionUpdate {
            didEnqueueSessionUpdate = true
            operations.append(BrewOperation(command: .update, title: "Updating Homebrew", targetID: nil))
        }

        operations.append(BrewOperation(command: command, title: title, targetID: targetID))
        pump()
    }

    func install(_ package: Package) {
        enqueue(.install(name: package.name, cask: package.kind == .cask),
                title: "Installing \(package.title)",
                targetID: package.id)
    }

    func upgrade(_ package: Package) {
        enqueue(.upgrade(name: package.name, cask: package.kind == .cask),
                title: "Updating \(package.title)",
                targetID: package.id)
    }

    func upgradeAll() {
        enqueue(.upgradeAll, title: "Upgrading all packages", targetID: nil)
    }

    private func pump() {
        guard runningTask == nil,
              let next = operations.first(where: { $0.state == .queued }) else { return }

        next.state = .running
        runningTask = Task { await self.execute(next) }
    }

    private func execute(_ operation: BrewOperation) async {
        let state: BrewOperation.State
        do {
            let code = try await client.run(operation.command) { line in
                operation.append(line)
            }
            state = code == 0 ? .succeeded : .failed
        } catch BrewError.cancelled {
            state = .cancelled
        } catch BrewError.notFound {
            operation.append("Error: Homebrew was not found.")
            state = .failed
        } catch {
            operation.append("Error: \(error.localizedDescription)")
            state = .failed
        }

        operation.state = state
        if state == .failed, failureToPresent == nil {
            failureToPresent = operation
        }

        runningTask = nil
        // Success or failure, a mutation can have changed what is installed.
        Task { await self.refreshState() }
        pump()
    }

    /// Cancel sends SIGINT — the path brew traps and cleans up after.
    func cancel(_ operation: BrewOperation) {
        switch operation.state {
        case .running:
            runningTask?.cancel()
        case .queued:
            operation.state = .cancelled
        default:
            break
        }
    }

    func remove(_ operation: BrewOperation) {
        guard operation.state == .queued else { return }
        operations.removeAll { $0.id == operation.id }
    }

    func latestOperation(for package: Package) -> BrewOperation? {
        operations.last { $0.targetID == package.id }
    }

    var isQueueActive: Bool { operations.contains { !$0.isFinished } }

    var activeCount: Int { operations.filter { !$0.isFinished }.count }

    var isMutating: Bool {
        operations.contains { $0.state == .running && $0.command.isMutating }
    }

    /// Quit path: drop what has not started, then interrupt what has.
    func interruptRunning() {
        operations.removeAll { $0.state == .queued }
        runningTask?.cancel()
    }

    // MARK: - Menu commands

    func requestFind() {
        findRequests += 1
    }
}
