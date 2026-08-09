//
//  PackageDetailView.swift
//  Brewery
//

import SwiftUI

/// The sheet behind a card: everything the grid had no room for — the full description, why an
/// action may be unavailable, where the package comes from, and the log of the last operation
/// that touched it.
struct PackageDetailView: View {
    let package: Package

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if package.disabled || package.deprecated {
                        banner
                    }

                    if let desc = package.desc, !desc.isEmpty {
                        Text(desc)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let url = package.homepageURL {
                        Link(destination: url) {
                            Label(url.host() ?? "Homepage", systemImage: "safari")
                        }
                        .accessibilityLabel("Open the \(package.title) homepage")
                    }

                    if let operation = model.latestOperation(for: package) {
                        Divider()
                        log(operation)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: model.latestOperation(for: package) == nil ? 380 : 580)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PackageIconView(package: package, size: 96)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(package.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    kindTag
                    // For casks the title is the display name, so the token is still worth showing.
                    if package.displayName != nil {
                        Text(package.name)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }

                versionLine
            }
            .font(.subheadline)

            Spacer(minLength: 8)

            action
                .padding(.top, 2)
        }
    }

    private var kindTag: some View {
        Text(package.kind == .cask ? "Cask" : "Formula")
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
    }

    @ViewBuilder
    private var versionLine: some View {
        switch model.status(for: package) {
        case let .outdated(installed, current):
            HStack(spacing: 6) {
                Text("\(installed.shortVersion) → \(current.shortVersion)")
                    .foregroundStyle(.orange)
                if isPinned {
                    Text("pinned")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case let .installed(version):
            Text("Version \(version.shortVersion) installed")
                .foregroundStyle(.secondary)
        case .notInstalled, .busy:
            if !package.version.isEmpty {
                Text("Version \(package.version.shortVersion)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Action

    @ViewBuilder
    private var action: some View {
        switch model.status(for: package) {
        case .busy:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("\(package.title) is being worked on")
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(package.title) is installed")
        case .outdated:
            Button("Update") { model.upgrade(package) }
                .buttonStyle(.borderedProminent)
                .disabled(isPinned)
                .help(isPinned
                      ? "This package is pinned in Homebrew. Brewery never changes pins."
                      : "Update \(package.title)")
                .accessibilityLabel("Update \(package.title)")
        case .notInstalled:
            Button("Install") { model.install(package) }
                .buttonStyle(.borderedProminent)
                .disabled(package.disabled)
                .help(package.disabled
                      ? "Homebrew has disabled this package, so it can no longer be installed."
                      : "Install \(package.title)")
                .accessibilityLabel("Install \(package.title)")
        }
    }

    private var isPinned: Bool {
        model.outdated[package.id]?.pinned == true
    }

    // MARK: - Banner

    /// A disabled package's button is greyed out; this is where that gets explained.
    private var banner: some View {
        let isDisabled = package.disabled
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(isDisabled ? "Disabled" : "Deprecated")
                    .fontWeight(.semibold)
                Text(isDisabled
                     ? "Homebrew has disabled this package, so it can no longer be installed."
                     : "Homebrew no longer maintains this package. It still installs today, but it may be disabled in a future release.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: isDisabled ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isDisabled ? .red : .orange)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDisabled ? Color.red.opacity(0.1) : Color.orange.opacity(0.1),
                    in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Log

    private func log(_ operation: BrewOperation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: operation.symbolName)
                Text(operation.title)
                    .fontWeight(.medium)
                Spacer()
                Text(Self.description(of: operation.state))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)

            OperationLogView(operation: operation)
                .frame(height: 180)
        }
    }

    private static func description(of state: BrewOperation.State) -> String {
        switch state {
        case .queued: "Queued"
        case .running: "Running"
        case .succeeded: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
