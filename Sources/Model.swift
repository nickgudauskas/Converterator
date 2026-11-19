// Converterator — Shared types and helpers: a queued job, byte formatting, ISO mode, line splitting.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

/// Where Converterator keeps its own files (downloaded DATs, conversion record, remembered Redump results).
/// The tests point it at a scratch folder with CONVERTERATOR_DATA_DIR, so they never touch the real one.
enum AppPaths {
    nonisolated static var dataDir: URL {
        if let p = ProcessInfo.processInfo.environment["CONVERTERATOR_DATA_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Converterator", isDirectory: true)
    }
}

/// Free space on the disk holding a folder, and the check made before converting or unpacking.
enum DiskSpace {
    /// Lets the tests pretend a disk is full.
    nonisolated(unsafe) static var override: (@Sendable (URL) -> Double?)?
    /// Room left over for everything else on the disk.
    nonisolated static let margin = 200.0 * 1_000_000

    /// The nearest folder that exists, so a not-yet-created output folder still finds its disk.
    nonisolated static func existing(_ url: URL) -> URL {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path) && u.path != "/" { u = u.deletingLastPathComponent() }
        return u
    }

    nonisolated static func free(at url: URL) -> Double? {
        if let override { return override(url) }
        let v = try? existing(url).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let i = v?.volumeAvailableCapacityForImportantUsage, i > 0 { return Double(i) }
        return v?.volumeAvailableCapacity.map(Double.init)
    }

    /// "EASYROMS", or "Macintosh HD".
    nonisolated static func volumeName(_ url: URL) -> String {
        (try? existing(url).resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "the disk"
    }

    /// Which disk a folder is on, for adding up a batch's needs per disk.
    nonisolated static func volumeID(_ url: URL) -> String {
        (try? existing(url).resourceValues(forKeys: [.volumeURLKey]))?.volume?.path ?? "/"
    }

    /// A message if `url`'s disk doesn't have room for `needs` bytes (plus a margin), else nil.
    nonisolated static func problem(needs: Double, at url: URL) -> String? {
        guard needs > 0, let free = free(at: url), free < needs + margin else { return nil }
        return "Not enough free space on \(volumeName(url)): needs up to \(formatBytes(needs)), \(formatBytes(free)) free"
    }
}

struct Job: Identifiable {
    enum State { case queued, working, done, failed }
    let id = UUID()
    let url: URL
    var state: State = .queued
    var detail: String = "Waiting"
    var progress: Double? = nil
    /// How much of this whole job is done (0…1), across extraction and every disc. Feeds the batch bar.
    var fraction: Double = 0
    /// Total size in bytes of this job's input files; bigger files count for more of the batch.
    var weight: Double = 1
    /// False when the job finished without real work (every CHD already existed, or it failed),
    /// so it doesn't skew the time-remaining estimate.
    var timed: Bool = true
    /// Bytes in and out for CHDs this job newly wrote, for "saved 1.2 GB". Zero when nothing was written.
    var bytesIn: Double = 0
    var bytesOut: Double = 0
    /// The CHDs this job produced or found already there.
    var outputs: [URL] = []
    /// A patch (translation, fix) applied before compressing; the CHD is named after it.
    var patch: URL?
    /// For a patch zip: which file inside it (when the patches folder matched one), else nil = try each.
    var patchMember: String?
    /// Found in the patches folder rather than chosen: if it doesn't fit, the game is converted without it.
    var patchFromFolder = false

    /// "Racing Lagoon (English)": what the CHD will be called if the patch is used (before Redump's name is known).
    var patchedName: String? {
        guard let patch else { return nil }
        let inner = patchMember.map { URL(fileURLWithPath: $0) } ?? patch
        return Patcher.patchedName(game: url, patch: inner, alsoLookIn: patch.deletingPathExtension().lastPathComponent)
    }

    /// A .chd input is extracted back to BIN/CUE (or GDI/ISO) instead of being compressed.
    /// A finished image (.chd, or .rvz for GameCube/Wii): extracted, or patched into a new one.
    var isCHD: Bool { ["chd", "rvz"].contains(url.pathExtension.lowercased()) }
    /// A .chd is extracted back to BIN/CUE, GDI or ISO, unless it has a patch: then it's unpacked,
    /// patched and compressed into a new, patched CHD.
    var isExtraction: Bool { isCHD && patch == nil }
    /// Patches applied after the first one, in order (a fix on top of a translation, say).
    var morePatches: [URL] = []
}

/// "1.2 GB", "712 MB".
func formatBytes(_ b: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}

/// Total size of the files at these URLs (missing files count as 0).
func totalSize(_ urls: [URL]) -> Double {
    // (Through links: a patched copy of a disc links its unchanged tracks to the originals.)
    urls.reduce(0.0) { sum, f in
        sum + Double(((try? FileManager.default.attributesOfItem(atPath: f.resolvingSymlinksInPath().path)[.size]) as? NSNumber)?.int64Value ?? 0)
    }
}

/// What a batch makes.
enum OutputFormat: String, CaseIterable, Identifiable {
    case chd, pbp
    var id: String { rawValue }
    var label: String { self == .chd ? "CHD" : "PBP for PSP / PS Vita" }
}

/// How chdman should treat .iso files.
enum ISOMode: String, CaseIterable, Identifiable {
    case automatic, cd, dvd
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .cd: return "Always CD"
        case .dvd: return "Always DVD"
        }
    }
}

/// Splits a byte stream into lines on \n or \r (chdman uses \r for its progress counter).
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void
    init(_ onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let i = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = pending[pending.startIndex..<i]
            pending.removeSubrange(pending.startIndex...i)
            emit(lineData)
        }
    }
    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { emit(pending); pending.removeAll() }
    }
    private func emit(_ d: Data) {
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { onLine(s) }
    }
}
