// Converterator — File → Library Report…
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - Library report

/// A look over a whole folder of games: what's converted, what isn't, leftovers, missing discs and playlists.
struct LibraryReport: Sendable {
    struct MissingDiscs: Identifiable, Sendable {
        let id = UUID()
        let dir: URL
        let name: String
        let have: [Int]
        let expected: Int
        let fromRedump: Bool
        var missing: [Int] { (1...max(expected, have.max() ?? 1)).filter { !have.contains($0) } }
    }
    struct NeedsPlaylist: Identifiable, Sendable {
        let id = UUID()
        let dir: URL
        let name: String
        let discs: [URL]
    }

    /// A game here with a patch waiting in your patches folder.
    struct PatchOffer: Identifiable, Sendable {
        let id = UUID()
        let game: URL                  // the original, or the CHD if that's all there is
        let patch: PatchLibrary.Entry
        let name: String               // what the patched CHD will be called
    }
    var patchOffers: [PatchOffer] = []
    var patchesFolderOn = false

    var chds: [URL] = []
    var chdBytes = 0.0
    var redumpNamed = 0               // CHDs whose name is exactly a Redump game name
    var redumpMatched = 0             // CHDs remembered as matching Redump
    var redumpNotMatching: [URL] = [] // remembered as partial or no match
    var redumpUnchecked: [URL] = []   // never checked, or changed since
    var unconverted: [URL] = []
    var unconvertedBytes = 0.0
    var leftovers: [Cleanup.Item] = []  // originals whose CHDs exist
    var leftoverBytes = 0.0
    var missingDiscs: [MissingDiscs] = []
    var needsPlaylist: [NeedsPlaylist] = []

    nonisolated static func build(folder: URL, outputDir: URL?, sevenZip: URL?, log: [String: [String]],
                                  redump: RedumpIndex, checked: [String: RedumpCache.Entry] = [:],
                                  patchesFolder: URL? = nil, preferLanguage: String? = nil,
                                  status: @escaping @Sendable (String) -> Void) -> LibraryReport {
        var r = LibraryReport()
        let fm = FileManager.default
        status("Listing files…")
        let all = (fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .allObjects as? [URL] ?? [])
        r.chds = all.filter { $0.pathExtension.lowercased() == "chd" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        r.chdBytes = totalSize(r.chds)

        // Redump game names, and for multi-disc games how many discs Redump lists.
        let redumpNames = Set(redump.trackCount.keys)
        var redumpDiscs: [String: Int] = [:]
        for name in redumpNames {
            if let d = DiscName.parse(name) { redumpDiscs[d.key] = max(redumpDiscs[d.key] ?? 0, d.of ?? d.disc) }
        }
        r.redumpNamed = r.chds.filter { redumpNames.contains($0.deletingPathExtension().lastPathComponent) }.count
        for chd in r.chds {
            switch RedumpCache.result(for: chd, in: checked, datStamp: redump.stamp) {
            case .some(let res) where res.isMatch: r.redumpMatched += 1
            case .some: r.redumpNotMatching.append(chd)
            case .none: r.redumpUnchecked.append(chd)
            }
        }

        status("Matching originals with CHDs…")
        let (converted, unconverted) = Cleanup.scanSources(in: folder, outputDir: outputDir, sevenZip: sevenZip, log: log)
        r.leftovers = Cleanup.unambiguous(converted).0
        r.leftoverBytes = r.leftovers.reduce(0) { $0 + $1.bytes }
        r.unconverted = unconverted
        r.unconvertedBytes = unconverted.reduce(0) { $0 + totalSize(Converter.sourceFiles(for: $1)) }

        status("Looking for missing discs and playlists…")
        // Disc sets per folder, counting both CHDs and not-yet-converted disc images.
        let discFiles = r.chds + unconverted.filter { Converter.inputExtensions.contains($0.pathExtension.lowercased()) }
        var sets: [String: (dir: URL, name: String, discs: Set<Int>, of: Int?)] = [:]
        for f in discFiles {
            guard let d = DiscName.parse(f.deletingPathExtension().lastPathComponent) else { continue }
            let dir = f.deletingLastPathComponent()
            let k = dir.path + "\u{0}" + d.key
            var e = sets[k] ?? (dir, d.key, [], nil)
            e.discs.insert(d.disc)
            if let of = d.of { e.of = max(e.of ?? 0, of) }
            sets[k] = e
        }
        for e in sets.values {
            let redumpCount = redumpDiscs[e.name]
            let expected = e.of ?? redumpCount ?? (e.discs.max() ?? 1)
            let set = MissingDiscs(dir: e.dir, name: e.name, have: e.discs.sorted(), expected: expected,
                                   fromRedump: e.of == nil && redumpCount != nil)
            if !set.missing.isEmpty { r.missingDiscs.append(set) }
        }
        r.missingDiscs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for dir in Set(r.chds.map { $0.deletingLastPathComponent() }) {
            r.needsPlaylist += Playlist.missing(in: dir).map { NeedsPlaylist(dir: dir, name: $0.name, discs: $0.discs) }
        }
        r.needsPlaylist.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if let patchesFolder {
            status("Looking for patches for your games…")
            r.patchesFolderOn = true
            r.patchOffers = patchOffers(patchesFolder: patchesFolder, prefer: preferLanguage, outputDir: outputDir,
                                        unconverted: unconverted, leftovers: r.leftovers, chds: r.chds)
        }
        return r
    }

    /// Games (originals not converted yet, originals with CHDs, and CHDs on their own) with a patch in
    /// the patches folder, leaving out ones whose patched CHD is already there and CHDs that are patched
    /// themselves.
    nonisolated static func patchOffers(patchesFolder: URL, prefer: String?, outputDir: URL?,
                                        unconverted: [URL], leftovers: [Cleanup.Item], chds: [URL]) -> [PatchOffer] {
        let entries = PatchLibrary.index(patchesFolder)
        guard !entries.isEmpty else { return [] }
        let covered = Set(leftovers.flatMap(\.chds).map(\.standardizedFileURL))
        let patchedTag = "(" + (Patcher.tags.map(\.name) + ["Patched"]).joined(separator: "|") + ")"
        let loneCHDs = chds.filter { chd in
            !covered.contains(chd.standardizedFileURL)
                && chd.deletingPathExtension().lastPathComponent.range(of: #"\(\#(patchedTag)\)"#, options: .regularExpression) == nil
        }
        var offers: [PatchOffer] = []
        for game in unconverted + leftovers.map(\.source) + loneCHDs {
            guard let e = PatchLibrary.match(game: game, entries: entries, prefer: prefer) else { continue }
            let inner = e.member.map { URL(fileURLWithPath: $0) } ?? e.url
            let name = Patcher.patchedName(game: game, patch: inner, alsoLookIn: e.member == nil ? nil : e.url.deletingPathExtension().lastPathComponent)
            let dirs = [game.deletingLastPathComponent()] + (outputDir.map { [$0] } ?? [])
            if dirs.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name + ".chd").path) }) { continue }
            offers.append(PatchOffer(game: game, patch: e, name: name))
        }
        return offers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published var folder: URL?
    @Published private(set) var report: LibraryReport?
    @Published private(set) var isScanning = false
    @Published private(set) var status = ""
    @Published var message = ""

    func scan(_ folder: URL) {
        self.folder = folder
        isScanning = true
        message = ""
        let outDir = Converter.shared.outputDir, sevenZip = Converter.shared.sevenZip
        let redump = RedumpDB.shared.index
        let checked = RedumpCache.all()
        let patches = PatchLibrary.shared.active ? PatchLibrary.shared.folder : nil
        let prefer = PatchLibrary.preferredLanguage
        Task.detached {
            let r = LibraryReport.build(folder: folder, outputDir: outDir, sevenZip: sevenZip, log: ConversionLog.load(),
                                        redump: redump, checked: checked, patchesFolder: patches, preferLanguage: prefer) { s in
                Task { @MainActor in self.status = s }
            }
            await MainActor.run { self.report = r; self.isScanning = false }
        }
    }

    func rescan() { if let folder { scan(folder) } }

    func makePlaylists() {
        guard let report else { return }
        var written = 0
        for dir in Set(report.needsPlaylist.map(\.dir)) { written += Playlist.make(in: dir).count }
        message = "Wrote \(written) playlist\(written == 1 ? "" : "s")."
        rescan()
    }
}

struct LibraryView: View {
    @ObservedObject private var m = Library.shared
    @ObservedObject private var c = Converter.shared
    @ObservedObject private var redump = RedumpDB.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(m.folder?.path(percentEncoded: false) ?? "Choose a folder of games, such as your whole ROMs folder.")
                    .lineLimit(1).truncationMode(.head)
                    .foregroundStyle(m.folder == nil ? .secondary : .primary)
                Spacer()
                if m.folder != nil { Button("Rescan") { m.rescan() }.disabled(m.isScanning) }
                Button("Choose Folder…", action: chooseFolder).disabled(m.isScanning)
            }
            Divider()
            if m.isScanning {
                HStack { ProgressView().controlSize(.small); Text(m.status) }
                Spacer()
            } else if let r = m.report {
                report(r)
            } else {
                Text("The report shows which games are converted, which aren't, originals you can clean up, multi-disc games with a disc missing, and ones without a playlist. Nothing is changed until you click an action.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if !m.message.isEmpty { Text(m.message).font(.callout) }
            HStack {
                Spacer()
                Button("Back to Converterator") { openWindow(id: "main"); dismissWindow(id: "library") }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
    }

    private func report(_ r: LibraryReport) -> some View {
        List {
            Section {
                row("CHDs", "\(r.chds.count) · \(formatBytes(r.chdBytes))")
                if !redump.index.isEmpty {
                    row("Named as in Redump", "\(r.redumpNamed) of \(r.chds.count)")
                }
            } header: { Text("Summary") }

            Section {
                if r.unconverted.isEmpty { Text("Everything here is converted.").foregroundStyle(.secondary) }
                ForEach(r.unconverted.prefix(200), id: \.self) { fileRow($0, detail: formatBytes(totalSize(Converter.sourceFiles(for: $0)))) }
                more(r.unconverted.count)
            } header: {
                header("Not converted yet: \(r.unconverted.count)", r.unconverted.isEmpty ? nil : formatBytes(r.unconvertedBytes),
                       action: r.unconverted.isEmpty || c.isRunning ? nil : ("Add All to Converter", {
                    c.add(r.unconverted); openWindow(id: "main")
                }))
            }

            Section {
                if r.leftovers.isEmpty { Text("No leftover originals.").foregroundStyle(.secondary) }
                ForEach(r.leftovers.prefix(200)) { item in
                    fileRow(item.source, detail: "\(formatBytes(item.bytes)) · has \(item.chds.count == 1 ? item.chds[0].lastPathComponent : "\(item.chds.count) CHDs")")
                }
                more(r.leftovers.count)
            } header: {
                header("Originals that already have CHDs: \(r.leftovers.count)", r.leftovers.isEmpty ? nil : formatBytes(r.leftoverBytes),
                       action: r.leftovers.isEmpty ? nil : ("Clean Up…", {
                    if let f = m.folder { Cleanup.shared.scan(f) }
                    openWindow(id: "cleanup")
                }))
            }

            Section {
                if r.missingDiscs.isEmpty { Text("No multi-disc games with a disc missing.").foregroundStyle(.secondary) }
                ForEach(r.missingDiscs) { set in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set.name).lineLimit(1).truncationMode(.middle)
                        Text("Has disc \(set.have.map(String.init).joined(separator: ", ")); missing \(set.missing.map(String.init).joined(separator: ", "))\(set.fromRedump ? " (Redump lists \(set.expected))" : "") · \(set.dir.lastPathComponent)")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    .contextMenu { Button("Show in Finder") { NSWorkspace.shared.open(set.dir) } }
                }
            } header: { header("Multi-disc games with a disc missing: \(r.missingDiscs.count)", nil, action: nil) }

            Section {
                if !r.patchesFolderOn {
                    Text("Choose a patches folder in Settings to see which of your games have a patch waiting.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if r.patchOffers.isEmpty {
                    Text("No patches in your patches folder for games here (or their patched CHDs already exist).").foregroundStyle(.secondary)
                }
                ForEach(r.patchOffers) { offer in
                    fileRow(offer.game, title: offer.name + ".chd",
                            detail: "from \(offer.game.lastPathComponent) with \(offer.patch.member.map { "\(offer.patch.url.lastPathComponent) → \(($0 as NSString).lastPathComponent)" } ?? offer.patch.name)")
                }
            } header: {
                header("Patches available: \(r.patchOffers.count)", nil, action: r.patchOffers.isEmpty || c.isRunning ? nil : ("Convert Patched Versions", {
                    for offer in r.patchOffers {
                        c.add([offer.game])
                        if let job = c.jobs.last(where: { $0.url.standardizedFileURL == offer.game.standardizedFileURL }) {
                            c.setPatch(offer.patch.url, member: offer.patch.member, for: job.id)
                        }
                    }
                    openWindow(id: "main")
                }))
            }

            Section {
                if r.needsPlaylist.isEmpty { Text("Every multi-disc game has a playlist.").foregroundStyle(.secondary) }
                ForEach(r.needsPlaylist) { set in
                    fileRow(set.discs[0], title: set.name + ".m3u",
                            detail: "\(set.discs.count) discs · \(set.dir.lastPathComponent)")
                }
            } header: {
                header("Multi-disc games without a playlist: \(r.needsPlaylist.count)", nil,
                       action: r.needsPlaylist.isEmpty ? nil : ("Make Playlists", { m.makePlaylists() }))
            }

            Section {
                if redump.index.isEmpty {
                    Text("Load Redump DATs in Settings to check your CHDs.").font(.caption).foregroundStyle(.secondary)
                } else {
                    row("Match Redump", "\(r.redumpMatched)")
                    row("Don't match", "\(r.redumpNotMatching.count)")
                    row("Not checked yet (or changed since)", "\(r.redumpUnchecked.count)")
                    ForEach(r.redumpNotMatching.prefix(200), id: \.self) { fileRow($0, detail: "partial or no match") }
                    more(r.redumpNotMatching.count)
                }
            } header: {
                header("Redump", nil, action: r.redumpUnchecked.isEmpty || redump.index.isEmpty ? nil : ("Check \(r.redumpUnchecked.count) Unchecked…", {
                    CHDCheck.shared.add(r.redumpUnchecked); openWindow(id: "chdcheck")
                }))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }

    private func header(_ title: String, _ size: String?, action: (String, () -> Void)?) -> some View {
        HStack {
            Text(title)
            if let size { Text(size).foregroundStyle(.secondary) }
            Spacer()
            if let action { Button(action.0, action: action.1).textCase(nil) }
        }
    }

    private func fileRow(_ url: URL, title: String? = nil, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title ?? url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Text(detail + " · " + url.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    }

    @ViewBuilder private func more(_ count: Int) -> some View {
        if count > 200 { Text("…and \(count - 200) more").font(.caption).foregroundStyle(.secondary) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder of games to report on (subfolders are included)"
        let done: (NSApplication.ModalResponse) -> Void = { if $0 == .OK, let url = panel.url { m.scan(url) } }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}
