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

    /// A .chd input is extracted back to BIN/CUE (or GDI/ISO) instead of being compressed.
    var isExtraction: Bool { url.pathExtension.lowercased() == "chd" }
}

/// "1.2 GB", "712 MB".
func formatBytes(_ b: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}

/// Total size of the files at these URLs (missing files count as 0).
func totalSize(_ urls: [URL]) -> Double {
    urls.reduce(0.0) { sum, f in
        sum + Double(((try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? NSNumber)?.int64Value ?? 0)
    }
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
