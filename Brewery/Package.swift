//
//  Package.swift
//  Brewery
//
//  Created by vzbarashchenko on 10.08.2026.
//

import Foundation

nonisolated enum PackageKind: String, Codable, Hashable, CaseIterable {
    case formula, cask
}

/// One catalog entry — a formula or a cask. Purely descriptive: install state lives in `AppModel`.
nonisolated struct Package: Codable, Identifiable, Hashable {
    let kind: PackageKind
    let name: String          // formula name or cask token, e.g. "visual-studio-code"
    let displayName: String?  // cask display name, e.g. "Visual Studio Code"; nil for formulae
    let desc: String?
    let homepage: String?
    let version: String
    let deprecated: Bool
    let disabled: Bool        // disabled packages cannot be installed

    var id: String { Package.packageID(kind: kind, name: name) }

    /// Overlay dictionaries are keyed by this, so the join rule has one home.
    static func packageID(kind: PackageKind, name: String) -> String {
        "\(kind.rawValue):\(name)"
    }

    var title: String { displayName ?? name }

    var homepageURL: URL? { homepage.flatMap(URL.init(string:)) }

    /// Favicon of the package homepage; nil when there is no homepage host to ask about.
    var iconURL: URL? {
        guard let host = homepageURL?.host(), !host.isEmpty else { return nil }
        return URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")
    }
}

nonisolated struct InstalledInfo: Equatable, Hashable {
    var versions: [String]
}

nonisolated struct OutdatedInfo: Equatable, Hashable {
    var installed: [String]
    var current: String
    var pinned: Bool
}

nonisolated enum PackageStatus: Equatable, Hashable {
    case notInstalled
    case installed(version: String)
    case outdated(installed: String, current: String)
    case busy
}

nonisolated extension String {
    /// Casks report versions like "2.1.50,56f0a83" — only the part before the comma is meaningful to a human.
    var shortVersion: String {
        guard let comma = firstIndex(of: ",") else { return self }
        return String(self[startIndex..<comma])
    }
}
