//
//  StorageSummaryBar.swift
//  Brewery
//

import Foundation
import SwiftUI

// The report bars' chrome is the shared `.contentBox()` (SharedControls.swift): one
// page-level box for bars and finding boxes alike. No margins of its own — the bars ride in
// ordinary list-row slots, so the list's insets are the gutter.

/// The Storage report's header, System Settings › Storage's grammar: an inventory of
/// what Homebrew is spending on disk and the one recommendation that reclaims it. The three
/// components are measured locally (the API carries no sizes; `DiskUsage` is the app's one
/// honest source): old kegs per multi-version formula, the cache directory brew's cleanup
/// sweeps, and its logs. **Clean Up…** enqueues `brew cleanup` — admitted to the whitelist
/// under autoremove's bar — and removes files only: the standing HOMEBREW_NO_AUTOREMOVE=1
/// gates the package removal a bare cleanup would otherwise run, and brew itself keeps
/// pinned and linked versions. Unlike the orphan bar this one renders even at zero: the
/// inventory and the last-cleaned date are answers either way.
struct StorageSummaryBar: View {
    @Environment(AppModel.self) private var model
    @State private var oldKegBytes: Int64?
    @State private var cacheBytes: Int64?
    @State private var logsBytes: Int64?

    /// The gauge's fixed component order: name, color, bytes. Distinct categorical hues —
    /// the platform storage gauge's grammar (System Settings › General › Storage).
    private var components: [(name: String, color: Color, bytes: Int64?)] {
        [("Old versions", .blue, oldKegBytes),
         ("Cache", .teal, cacheBytes),
         ("Logs", .orange, logsBytes)]
    }

    private var totalBytes: Int64? {
        let measured = components.compactMap(\.bytes)
        return measured.isEmpty ? nil : measured.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // A short total, never a data dump: metrics wrapped the old headline, and a
                // wrapping header is a defect. The breakdown belongs to the gauge below.
                if let totalBytes {
                    Text("\(totalBytes.formatted(.byteCount(style: .file))) of Homebrew files")
                        .font(.title3)
                        .fontWeight(.semibold)
                } else {
                    // Reserved from first layout (the pane's Size row rule).
                    Text("00,0 GB of Homebrew files")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .redacted(reason: .placeholder)
                        // Scaffolding, not content — the pane's Size row rule: a redaction
                        // is invisible to VoiceOver, which otherwise read the reserved
                        // digits out as the measurement.
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 12)

                CleanupButton()
            }

            gauge
            legend

            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .contentBox()
        .task(id: measureKey) { await measure() }
    }

    /// The proportional color bar. Nonzero slivers keep a minimum width (iPhone Storage shows
    /// slivers); unmeasured, the whole track is a quiet placeholder.
    private var gauge: some View {
        GeometryReader { proxy in
            let measured = components.compactMap { part in
                part.bytes.map { (color: part.color, bytes: $0) }
            }
            let total = max(measured.reduce(Int64(0)) { $0 + $1.bytes }, 1)
            // Proportions against the width actually available for fill: the 2 pt gaps come
            // off first, or the 3 pt minimum slivers push the last segment past the trailing
            // edge and clip it.
            let track = proxy.size.width - 2 * CGFloat(max(measured.count - 1, 0))
            HStack(spacing: 2) {
                if measured.isEmpty {
                    Rectangle().fill(.quaternary)
                } else {
                    ForEach(measured.enumerated(), id: \.offset) { _, part in
                        Rectangle()
                            .fill(part.color.gradient)
                            .frame(width: max(3, track * CGFloat(part.bytes) / CGFloat(total)))
                    }
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityHidden(true)   // the legend speaks for it
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(components, id: \.name) { part in
                if let bytes = part.bytes {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(part.color)
                            .frame(width: 8, height: 8)
                        Text("\(part.name) \(bytes.formatted(.byteCount(style: .file)))"
                            .replacing(" ", with: "\u{00A0}"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        var text = "Cleaning up removes what Homebrew no longer needs."
        if let cleaned = model.client.cleanedDate() {
            let ago = cleaned.formatted(.relative(presentation: .named))
            text += " Last cleaned \(ago)."
        }
        return text
    }

    /// Re-measure when the keg population changes or a cleanup finishes — the package count
    /// the rest of the app keys on cannot see either event.
    private var measureKey: String {
        let signature = model.installed
            .filter { $0.key.hasPrefix("formula:") && $0.value.versions.count > 1 }
            .map { "\($0.key)=\($0.value.versions.joined(separator: ","))" }
            .sorted()
            .joined(separator: ";")
        return "\(signature)|\(model.finishedCleanupCount)"
    }

    /// Publishes **once**, at the end: `totalBytes` sums whatever component has landed, so
    /// assigning the three across three awaits un-redacted the headline as soon as the first
    /// one arrived and stated a figure that was never true of anything. It also made a
    /// re-measure after cleanup half-update the previous total instead of replacing it.
    /// (The orphan bar already does it this way.)
    private func measure() async {
        // Old kegs ride the session cache under `oldkeg:`-namespaced keys — a keg's bytes
        // never change, and a removed keg's root measures nil, which is never cached.
        var kegs: Int64?
        if let prefix = model.client.prefix {
            var total: Int64 = 0
            var found = false
            for (id, info) in model.installed
            where id.hasPrefix("formula:") && info.versions.count > 1 {
                guard let (_, name) = Package.components(of: id) else { continue }
                for (key, root) in AppModel.oldKegRoots(
                    prefix: prefix, name: name, versions: info.versions) {
                    if let bytes = await DiskUsage.measuredBytes(key: key, roots: [root]) {
                        total += bytes
                        found = true
                    }
                }
            }
            kegs = found ? total : nil
        }
        // Cache and logs are mutable directories under stable names — the session cache would
        // serve stale bytes, so these bypass it.
        let environment = model.client.effectiveEnvironment
        let home = URL.homeDirectory
        let cache = await DiskUsage.bytes(
            at: [BrewClient.cacheDirectory(environment: environment, home: home)])
        let logs = await DiskUsage.bytes(
            at: [BrewClient.logsDirectory(environment: environment, home: home)])

        (oldKegBytes, cacheBytes, logsBytes) = (kegs, cache, logs)
    }
}
