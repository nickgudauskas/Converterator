// Converterator — Which CHDs each original was converted to.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - Conversion log

/// Which CHDs each original was converted to, kept in Application Support. Clean Up Originals uses it
/// to find CHDs that don't share the original's name (named after Redump, for example).
enum ConversionLog {
    static var file: URL { AppPaths.dataDir.appendingPathComponent("converted.json") }

    static func load() -> [String: [String]] {
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return dict
    }

    @MainActor static func record(source: URL, chds: [URL]) {
        guard !chds.isEmpty else { return }
        var all = load()
        all[source.standardizedFileURL.path] = chds.map(\.standardizedFileURL.path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
    }

    /// Points entries at a CHD's new name after it's renamed.
    @MainActor static func renamed(_ old: URL, to new: URL) {
        var all = load()
        let o = old.standardizedFileURL.path, n = new.standardizedFileURL.path
        var changed = false
        for (k, v) in all where v.contains(o) { all[k] = v.map { $0 == o ? n : $0 }; changed = true }
        if changed { try? JSONEncoder().encode(all).write(to: file, options: .atomic) }
    }
}
