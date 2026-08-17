//
//  UninstallFunnelTests.swift
//  BreweryTests
//

import Foundation
import Testing
@testable import Brewery

/// v15 — the uninstall funnel's contract: confirmed before enqueue, pinned blocked up front,
/// zap only where the receipt earned it, and hostile names dead on arrival.
@MainActor
struct UninstallFunnelTests {

    private let wget = Package(kind: .formula, name: "wget", displayName: nil, desc: nil,
                               homepage: nil, version: "1.25.0",
                               deprecated: false, disabled: false)
    private let iterm = Package(kind: .cask, name: "iterm2", displayName: "iTerm2", desc: nil,
                                homepage: nil, version: "3.5.11",
                                deprecated: false, disabled: false)

    @Test("uninstall(_:) sets the pending package and enqueues nothing")
    func confirmedBeforeEnqueue() {
        let model = AppModel()
        model.installed[wget.id] = InstalledInfo(versions: ["1.25.0"])

        model.uninstall(wget)

        #expect(model.pendingUninstall == wget)
        // The trust-write rule, pinned as a test: the dialog decides, not the trigger.
        #expect(model.operations.isEmpty)
    }

    @Test("a package that is not installed cannot become pending")
    func notInstalledNoOps() {
        let model = AppModel()
        model.uninstall(wget)
        #expect(model.pendingUninstall == nil)
    }

    @Test("a pinned package never reaches the dialog")
    func pinnedBlocked() {
        let model = AppModel()
        model.installed[wget.id] = InstalledInfo(versions: ["1.24.0"])
        model.outdated[wget.id] = OutdatedInfo(installed: ["1.24.0"], current: "1.25.0",
                                               pinned: true)

        model.uninstall(wget)

        // brew's pinned refusal exits 0 having removed nothing — blocking beats a lying success.
        #expect(model.pendingUninstall == nil)
        #expect(model.uninstallableSelection == nil)
        #expect(model.isPinned(wget))
    }

    @Test("confirmedUninstall picks .zap only for a cask whose receipt has a zap stanza")
    func zapNeedsTheStanza() {
        let model = AppModel()
        model.installed[iterm.id] = InstalledInfo(versions: ["3.5.11"], hasZap: true)
        model.confirmedUninstall(iterm, zap: true)
        #expect(model.operations.contains { $0.command == .zap(name: "iterm2") })

        let plain = AppModel()
        plain.installed[iterm.id] = InstalledInfo(versions: ["3.5.11"])  // hasZap: false
        plain.confirmedUninstall(iterm, zap: true)
        #expect(plain.operations.contains { $0.command == .uninstall(name: "iterm2", cask: true) })
        #expect(!plain.operations.contains { $0.command == .zap(name: "iterm2") })

        // A formula ignores the zap flag outright.
        let formula = AppModel()
        formula.installed[wget.id] = InstalledInfo(versions: ["1.25.0"], hasZap: true)
        formula.confirmedUninstall(wget, zap: true)
        #expect(formula.operations.contains { $0.command == .uninstall(name: "wget", cask: false) })
    }

    @Test("the enqueue name guard covers the new cases")
    func nameHardening() {
        let model = AppModel()
        model.enqueue(.uninstall(name: "-rf", cask: false), title: "x", targetID: nil)
        model.enqueue(.zap(name: "--zap"), title: "x", targetID: nil)
        model.enqueue(.uninstall(name: "", cask: true), title: "x", targetID: nil)

        // The guard runs before the staleness front-load, so a rejection appends nothing at all.
        #expect(model.operations.isEmpty)
    }

    @Test("blocking dependents union receipt formulae with installed casks' claims")
    func blockingDependents() {
        let neovim = Package(kind: .formula, name: "neovim", displayName: nil, desc: nil,
                             homepage: nil, version: "0.11.0",
                             deprecated: false, disabled: false)

        // A formula dependent (from the receipts' inverted map)…
        let fromReceipts = AppModel.blockingDependentIDs(
            of: neovim,
            dependents: [neovim.id: ["formula:neovim-remote"]],
            caskDependencies: [:])
        #expect(fromReceipts == ["formula:neovim-remote"])

        // …unioned with a cask claiming the formula through catalog depends_on — brew counts
        // cask dependents too (installed_dependents.rb:45).
        let withCask = AppModel.blockingDependentIDs(
            of: neovim,
            dependents: [neovim.id: ["formula:neovim-remote"]],
            caskDependencies: ["cask:neovide": ["neovim"], "cask:iterm2": ["python@3.13"]])
        #expect(withCask == ["formula:neovim-remote", "cask:neovide"])

        // Casks themselves have no computable dependents — brew stays the final arbiter.
        let cask = Package(kind: .cask, name: "neovide", displayName: nil, desc: nil,
                           homepage: nil, version: "1.0", deprecated: false, disabled: false)
        #expect(AppModel.blockingDependentIDs(of: cask,
                                              dependents: [:],
                                              caskDependencies: ["cask:x": ["neovide"]]).isEmpty)
    }
}
