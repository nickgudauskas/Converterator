// Watch folder: games (and patches) that arrive in a chosen folder, such as Downloads, are added to the list
// and converted while the app is open.
import Foundation

@MainActor
final class WatchFolder: ObservableObject {
    static let shared = WatchFolder()

    @Published var folder: URL? {
        didSet { UserDefaults.standard.set(folder?.path, forKey: "watchFolder"); restart() }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "watchFolderEnabled"); restart() }
    }
    /// Start converting as soon as something arrives (otherwise it just waits in the list).
    @Published var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: "watchFolderAutoStart") }
    }
    @Published private(set) var isWatching = false

    /// How often the folder is looked at, and how long a file must stay the same size before it counts as
    /// finished downloading (the tests make these short).
    var interval: TimeInterval = 5
    var settle: TimeInterval = 4

    private var timer: Timer?
    private var seen = Set<String>()                          // handled, or there before watching started
    private var pending: [String: (size: Double, since: Date)] = [:]

    init() {
        let d = UserDefaults.standard
        folder = d.string(forKey: "watchFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        enabled = d.bool(forKey: "watchFolderEnabled")
        autoStart = d.object(forKey: "watchFolderAutoStart") as? Bool ?? true
    }

    func restart() {
        timer?.invalidate(); timer = nil
        seen = []; pending = [:]
        guard enabled, let folder, FileManager.default.fileExists(atPath: folder.path) else { isWatching = false; return }
        // What's already there is left alone; only files that arrive from now on are converted.
        for f in WatchFolder.candidates(in: folder) { seen.insert(f.path) }
        isWatching = true
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
    }

    /// Disc images, archives, lone ECM files and patches in the folder and one level of subfolders.
    nonisolated static func candidates(in folder: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        func scan(_ dir: URL, depth: Int) {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] {
                if (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if depth < 1, !["app", "download"].contains(f.pathExtension.lowercased()) { scan(f, depth: depth + 1) }
                    continue
                }
                let ext = f.pathExtension.lowercased()
                if Converter.inputExtensions.contains(ext)
                    || (Converter.archiveExtensions.contains(ext) && !Converter.isLaterPart(f))
                    || (ext == "ecm" && ECM.sheet(for: f) == nil)
                    || PatchFormat.of(f) != nil {
                    out.append(f.standardizedFileURL)
                }
            }
        }
        scan(folder, depth: 0)
        return out
    }

    /// Looks for new arrivals; one counts once it (and every track a .cue lists) has stopped growing.
    func look() {
        guard let folder, enabled else { return }
        let c = Converter.shared
        var games: [URL] = [], patches: [URL] = []
        let now = Date()
        for f in WatchFolder.candidates(in: folder) where !seen.contains(f.path) {
            let files = Converter.sourceFiles(for: f)
            let size = totalSize(files)
            guard Converter.missingTracks(for: f).isEmpty, size > 0 else { pending[f.path] = nil; continue }
            if let p = pending[f.path], p.size == size {
                guard now.timeIntervalSince(p.since) >= settle else { continue }
            } else {
                pending[f.path] = (size, now); continue
            }
            pending[f.path] = nil
            seen.insert(f.path)
            if PatchFormat.of(f) != nil { patches.append(f); continue }
            // Archives count only with a disc image inside (not zipped cartridge games or patch zips).
            if Converter.archiveExtensions.contains(f.pathExtension.lowercased()) {
                if Patcher.isPatchZip(f) { patches.append(f); continue }
                guard c.archiveHasDiscImage(f) else { continue }
            }
            games.append(f)
        }
        if !patches.isEmpty { c.addPatches(patches) }
        guard !games.isEmpty else { return }
        c.append("Watch folder: \(games.map(\.lastPathComponent).joined(separator: ", ")) arrived")
        c.add(games)
        if autoStart, !c.isRunning, !c.isPaused, c.toolsReady, c.hasQueued { c.start() }
    }
}
