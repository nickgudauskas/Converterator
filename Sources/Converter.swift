// Converterator — The conversion queue: adding files, running PSXPackager and chdman, archives, ISO type, track files.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

@MainActor
final class Converter: ObservableObject {
    static let shared = Converter()

    @Published var jobs: [Job] = [] {
        didSet { saveQueueIfChanged() }
    }
    @Published var log: String = ""
    @Published var isRunning = false
    /// A batch stopped with Pause: not running, but its remaining files are still waiting.
    @Published private(set) var isPaused = false
    /// Files put back in the list from last time (shown once, until dismissed).
    @Published var restoredCount = 0
    @Published var outputDir: URL? {
        didSet { UserDefaults.standard.set(outputDir?.path, forKey: "outputDir") }
    }
    @Published var overwrite: Bool {
        didSet { UserDefaults.standard.set(overwrite, forKey: "overwrite") }
    }
    @Published var makeM3U: Bool {
        didSet { UserDefaults.standard.set(makeM3U, forKey: "makeM3U") }
    }

    @Published var verify: Bool {
        didSet { UserDefaults.standard.set(verify, forKey: "verify") }
    }
    /// Start converting straight away when files arrive from Finder's "Convert with Converterator".
    @Published var startFromFinder: Bool {
        didSet { UserDefaults.standard.set(startFromFinder, forKey: "startFromFinder") }
    }
    @Published var isoMode: ISOMode {
        didSet { UserDefaults.standard.set(isoMode.rawValue, forKey: "isoMode") }
    }

    @Published private(set) var psxpackager: URL? = Converter.findTool("psxpackager")
    @Published private(set) var chdman: URL? = Converter.findTool("chdman")

    /// Looks for the tools again, e.g. after chdman was installed while the app was open.
    func recheckTools() {
        let p = Converter.findTool("psxpackager"), c = Converter.findTool("chdman")
        if p != psxpackager { psxpackager = p }
        if c != chdman { chdman = c }
    }

    static var homebrewInstalled: Bool {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var currentProcess: Process?
    /// Keeps the Mac from idle-sleeping while a batch runs.
    private var activity: NSObjectProtocol?
    /// Move source files to the Trash after a successful conversion.
    /// Deliberately not remembered between launches, so it's never on by surprise.
    @Published var trashSources = false

    private var cancelRequested = false
    private var pauseRequested = false
    private var pauseNow = false
    private var pausedAt: Date?

    init() {
        let d = UserDefaults.standard
        if let p = d.string(forKey: "outputDir"), FileManager.default.fileExists(atPath: p) {
            outputDir = URL(fileURLWithPath: p, isDirectory: true)
        }
        overwrite = d.bool(forKey: "overwrite")
        makeM3U = d.object(forKey: "makeM3U") as? Bool ?? true
        verify = d.bool(forKey: "verify")
        isoMode = ISOMode(rawValue: d.string(forKey: "isoMode") ?? "") ?? .automatic
        startFromFinder = d.object(forKey: "startFromFinder") as? Bool ?? true
        restoreQueue()
    }

    /// chdman is needed for everything; PSXPackager only for .pbp files (checked per job).
    var toolsReady: Bool { chdman != nil }
    var hasQueued: Bool { jobs.contains { $0.state == .queued } }

    // MARK: Tools

    /// CPU architecture of the running app slice, matching the bundled tool suffixes.
    static let arch: String = {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }()

    static func findTool(_ name: String) -> URL? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL {
            // Universal builds bundle one copy per architecture, e.g. psxpackager/psxpackager-x86_64.
            candidates.append(res.appendingPathComponent("psxpackager/\(name)-\(arch)").path)
            candidates.append(res.appendingPathComponent("psxpackager/\(name)").path)
            candidates.append(res.appendingPathComponent(name).path)
        }
        candidates += ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                       NSHomeDirectory() + "/bin/\(name)", NSHomeDirectory() + "/.local/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    nonisolated static let toolEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        // PSXPackager is a self-contained .NET app (the runtime is inside it); nothing to point it at.
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        return env
    }()

    // MARK: Queue

    /// Inputs found when scanning folders. .pbp goes through PSXPackager first; the rest go straight to chdman.
    nonisolated static let inputExtensions: Set<String> = ["pbp", "cue", "gdi", "iso"]
    /// .chd files are extracted back to BIN/CUE, GDI or ISO. Only when added one by one: a folder scan
    /// never picks them up, so re-adding a converted folder doesn't unpack every CHD in it.
    nonisolated static let extractExtensions: Set<String> = ["chd"]

    func add(_ urls: [URL]) {
        let fm = FileManager.default
        var found: [URL] = []
        func consider(_ f: URL) {
            let ext = f.pathExtension.lowercased()
            if Converter.inputExtensions.contains(ext) || Converter.extractExtensions.contains(ext)
                || Converter.archiveExtensions.contains(ext) {
                found.append(f)
            } else if ext == "bin" {
                // A dropped .bin means its .cue sheet (same name); folder scans pick up the .cue directly.
                let cue = f.deletingPathExtension().appendingPathExtension("cue")
                if fm.fileExists(atPath: cue.path) { found.append(cue) }
                else { append("Skipped \(f.lastPathComponent): no matching .cue file next to it.") }
            }
        }
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    let ext = f.pathExtension.lowercased()
                    if Converter.inputExtensions.contains(ext) {
                        found.append(f)
                    } else if Converter.archiveExtensions.contains(ext), archiveHasDiscImage(f) {
                        found.append(f)   // only archives with a disc image inside, not zipped cartridge games
                    }
                }
            } else {
                consider(url)
            }
        }
        let existing = Set(jobs.map { $0.url.standardizedFileURL })
        let new = found.map { $0.standardizedFileURL }
            .filter { !existing.contains($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let newJobs = new.map { url -> Job in
            var job = Job(url: url)
            job.weight = max(totalSize(Converter.sourceFiles(for: url)), 1)
            // Flag a .cue/.gdi with missing tracks now, rather than partway through a batch.
            let missing = Converter.missingTracks(for: url)
            if !missing.isEmpty { job.state = .failed; job.detail = Converter.describeMissing(missing); job.timed = false }
            return job
        }
        jobs += newJobs
        // Files added mid-run join the current batch.
        if isRunning || isPaused { batchIDs += newJobs.filter { $0.state == .queued }.map(\.id) }
        if found.isEmpty && !urls.isEmpty { append("No .pbp, .cue, .gdi, .iso, .chd, .zip or .7z files found in what was added.") }
    }

    func clearFinished() { jobs.removeAll { $0.state == .done || $0.state == .failed } }
    func clearAll() { if !isRunning { jobs.removeAll() } }
    func remove(_ id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .working { jobs.remove(at: i) }
    }
    func retryFailed() {
        for i in jobs.indices where jobs[i].state == .failed {
            jobs[i].state = .queued; jobs[i].detail = "Waiting"; jobs[i].progress = nil; jobs[i].fraction = 0
            jobs[i].bytesIn = 0; jobs[i].bytesOut = 0; jobs[i].outputs = []
        }
    }

    // MARK: Saved queue

    /// What's kept of a job between launches.
    struct SavedJob: Codable {
        let path: String
        let state: String
        let detail: String
        let weight: Double
        let bytesIn: Double
        let bytesOut: Double
        let outputs: [String]
    }

    nonisolated static var queueFile: URL { AppPaths.dataDir.appendingPathComponent("queue.json") }
    private var savedSignature = ""

    /// Saves the list whenever a file is added, removed, or changes state (not on every progress tick).
    private func saveQueueIfChanged() {
        let signature = jobs.map { "\($0.id)\($0.state)" }.joined(separator: ",")
        guard signature != savedSignature else { return }
        savedSignature = signature
        let saved = jobs.map { j in
            SavedJob(path: j.url.path, state: "\(j.state)", detail: j.detail, weight: j.weight,
                     bytesIn: j.bytesIn, bytesOut: j.bytesOut, outputs: j.outputs.map(\.path))
        }
        try? FileManager.default.createDirectory(at: AppPaths.dataDir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: Converter.queueFile, options: .atomic)
    }

    /// Jobs from a saved list. One that was converting when the app quit (or crashed) is waiting again.
    nonisolated static func loadQueue(from file: URL) -> [Job] {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([SavedJob].self, from: data) else { return [] }
        return saved.map { s in
            var j = Job(url: URL(fileURLWithPath: s.path))
            switch s.state {
            case "done": j.state = .done; j.detail = s.detail
            case "failed": j.state = .failed; j.detail = s.detail
            default: j.state = .queued; j.detail = s.state == "working" ? "Waiting (interrupted last time)" : "Waiting"
            }
            j.weight = s.weight; j.bytesIn = s.bytesIn; j.bytesOut = s.bytesOut
            j.outputs = s.outputs.map { URL(fileURLWithPath: $0) }
            j.timed = j.state == .queued
            return j
        }
    }

    private func restoreQueue() {
        let restored = Converter.loadQueue(from: Converter.queueFile)
        guard !restored.isEmpty else { return }
        jobs = restored
        restoredCount = restored.filter { $0.state == .queued }.count
    }

    // MARK: Batch progress

    /// The jobs in the current (or most recent) Convert run.
    @Published private(set) var batchIDs: [UUID] = []

    var batchJobs: [Job] {
        let ids = Set(batchIDs)
        return jobs.filter { ids.contains($0.id) }
    }
    /// How far through a job is, 0…1.
    private static func done(_ j: Job) -> Double {
        switch j.state {
        case .done, .failed: return 1
        case .working: return min(max(j.fraction, 0), 1)
        case .queued: return 0
        }
    }
    /// Batch progress weighted by file size, so a 700 MB disc counts more than a 50 MB one.
    var batchProgress: Double {
        let b = batchJobs
        let total = b.reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        return b.reduce(0.0) { $0 + $1.weight * Converter.done($1) } / total
    }

    @Published private(set) var batchStart: Date?
    @Published private(set) var batchEnd: Date?

    /// Seconds left in the batch, from the average speed so far. Nil until there's enough to go on.
    func batchTimeRemaining(now: Date = Date()) -> TimeInterval? {
        guard isRunning, let start = batchStart else { return nil }
        let b = batchJobs
        let worked = b.filter(\.timed).reduce(0.0) { $0 + $1.weight * Converter.done($1) }
        let left = b.reduce(0.0) { $0 + $1.weight * (1 - Converter.done($1)) }
        return Converter.estimateRemaining(elapsed: now.timeIntervalSince(start), worked: worked, left: left)
    }

    /// Remaining time = bytes left ÷ (bytes processed ÷ time so far). Waits for 10 s and some progress.
    nonisolated static func estimateRemaining(elapsed: TimeInterval, worked: Double, left: Double) -> TimeInterval? {
        guard elapsed >= 10, worked > 0 else { return nil }
        if left <= 0 { return 0 }
        return left / (worked / elapsed)
    }

    /// "About 12 minutes left", "About 1 hour, 5 minutes left", "Less than a minute left".
    nonisolated static func describeRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "Less than a minute left" }
        return "About \(describeDuration(seconds)) left"
    }

    nonisolated static func describeDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(Int(seconds.rounded()), 1)) second\(Int(seconds.rounded()) == 1 ? "" : "s")" }
        // Round to the nearest minute so the estimate doesn't flicker every second.
        let rounded = (seconds / 60).rounded() * 60
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = rounded >= 3600 ? [.hour, .minute] : [.minute]
        f.maximumUnitCount = 2
        return f.string(from: rounded) ?? ""
    }
    var batchDoneCount: Int { batchJobs.filter { $0.state == .done }.count }
    var batchFailedCount: Int { batchJobs.filter { $0.state == .failed }.count }
    var batchQueuedCount: Int { batchJobs.filter { $0.state == .queued }.count }

    /// "Saved 2.1 GB (48%)" across the CHDs this batch wrote, or nil if it saved nothing.
    var batchSavedText: String? {
        let b = batchJobs.filter { $0.bytesOut > 0 && !$0.isExtraction }
        let input = b.reduce(0.0) { $0 + $1.bytesIn }, output = b.reduce(0.0) { $0 + $1.bytesOut }
        guard input > output else { return nil }
        return "Saved \(formatBytes(input - output)) (\(Int(((input - output) / input * 100).rounded()))%)"
    }

    /// "4 converted, 1 failed, 2 not started".
    var batchCountsText: String {
        var parts = ["\(batchDoneCount) converted"]
        if batchFailedCount > 0 { parts.append("\(batchFailedCount) failed") }
        if batchQueuedCount > 0 { parts.append("\(batchQueuedCount) not started") }
        return parts.joined(separator: ", ")
    }

    func append(_ s: String) {
        log += s + "\n"
        if log.count > 200_000 { log = String(log.suffix(150_000)) }
    }

    func cancel() {
        if isPaused {
            // Ending a paused batch: nothing is running, so just close it off.
            isPaused = false; pausedAt = nil; batchEnd = Date()
            append("— Cancelled —")
            return
        }
        cancelRequested = true
        currentProcess?.terminate()
    }

    /// Pauses the batch after the current file, or right away (`now`), in which case the current file
    /// is stopped, its unfinished CHD deleted, and it goes back in the list to be done again on Resume.
    func pause(now: Bool = false) {
        guard isRunning else { return }
        pauseRequested = true
        if now { pauseNow = true; cancelRequested = true; currentProcess?.terminate() }
    }

    // MARK: Conversion

    /// Converts everything waiting in the list, or carries on with a paused batch.
    func start() {
        if isPaused { resume(); return }
        guard !isRunning, toolsReady else { return }
        batchIDs = jobs.filter { $0.state == .queued }.map(\.id)
        batchStart = Date()
        batchEnd = nil
        runQueue()
    }

    private func resume() {
        guard isPaused, toolsReady else { return }
        // Leave the paused time out of the time-remaining estimate.
        if let p = pausedAt, let s = batchStart { batchStart = s.addingTimeInterval(Date().timeIntervalSince(p)) }
        isPaused = false
        pausedAt = nil
        append("— Resumed —")
        runQueue()
    }

    private func runQueue() {
        isRunning = true
        cancelRequested = false
        pauseRequested = false
        pauseNow = false
        // Stop the Mac from idle-sleeping mid-batch. The display can still sleep; closing a laptop lid still sleeps.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Converting disc images")
        Notifier.requestPermission()
        Task {
            var last: UUID?
            while !cancelRequested && !pauseRequested, let i = jobs.firstIndex(where: { $0.state == .queued }) {
                last = jobs[i].id
                if jobs[i].isExtraction { await extract(index: i) } else { await convert(index: i) }
            }
            isRunning = false
            if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
            if pauseNow, let last {
                // Paused mid-file: put it back to be done again from the start.
                update(last) { $0.state = .queued; $0.detail = "Waiting"; $0.progress = nil; $0.fraction = 0; $0.timed = true }
                append("  put back in the list for when you resume")
            }
            if pauseRequested && hasQueued {
                isPaused = true
                pausedAt = Date()
                cancelRequested = false
                append("— Paused —")
                return
            }
            batchEnd = Date()
            writePlaylists()
            append(cancelRequested ? "— Cancelled —" : "— All done —")
            if !cancelRequested {
                Notifier.batchFinished(counts: batchCountsText, saved: batchSavedText, failed: batchFailedCount > 0)
            }
        }
    }

    /// After a batch: an .m3u for each multi-disc game that now has 2+ CHDs in a folder
    /// ("Game (Disc 1).chd", "Game (Disc 2).chd" → "Game.m3u"), when "Make .m3u playlist" is on.
    private func writePlaylists() {
        guard makeM3U else { return }
        let made = Set(batchJobs.flatMap(\.outputs).map(\.standardizedFileURL))
        let dirs = Set(made.map { $0.deletingLastPathComponent() })
        for dir in dirs {
            for m3u in Playlist.make(in: dir, only: made) { append("wrote \(m3u.lastPathComponent)") }
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]) }
    }

    /// What compressGame produced for one game (one .pbp/.cue/.gdi/.iso).
    private struct GameResult {
        var made: [URL] = []
        var skipped = 0                 // CHDs that already existed and weren't rewritten
        var bytesIn = 0.0, bytesOut = 0.0
        var redump: [RedumpResult] = []  // one per game checked against Redump
    }

    private func convert(index: Int) async {
        let job = jobs[index]
        let id = job.id
        let fm = FileManager.default
        let src = job.url
        let outDir = outputDir ?? src.deletingLastPathComponent()
        let isArchive = Converter.archiveExtensions.contains(src.pathExtension.lowercased())

        func fail(_ msg: String) {
            update(id) { $0.state = .failed; $0.detail = msg; $0.progress = nil; $0.timed = false }
            append("✗ \(src.lastPathComponent): \(msg)")
        }

        update(id) { $0.state = .working; $0.detail = "Starting…"; $0.progress = nil; $0.fraction = 0; $0.timed = true }
        append("▶ \(src.lastPathComponent)")
        guard fm.fileExists(atPath: src.path) else {
            return fail("Can't find the file. If it's on an external drive, connect it, then use Clear → Retry Failed.")
        }
        do { try fm.createDirectory(at: outDir, withIntermediateDirectories: true) }
        catch { return fail("Can't create folder: \(error.localizedDescription)") }
        // Room for the CHD, and for temporary files (unpacked PBPs and archives). Skipped when the CHD is
        // already there and won't be rewritten.
        let alreadyThere = !overwrite && Converter.inputExtensions.contains(src.pathExtension.lowercased())
            && src.pathExtension.lowercased() != "pbp"
            && fm.fileExists(atPath: outDir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + ".chd").path)
        if !alreadyThere {
            let need = Converter.spaceNeeded(for: src)
            if let p = DiskSpace.problem(needs: need.output, at: outDir) { return fail(p) }
            if let p = DiskSpace.problem(needs: need.temp, at: fm.temporaryDirectory) { return fail(p + " for temporary files") }
        }

        // The games to compress: the file itself, or every disc image inside a .zip/.7z.
        var games = [src]
        var span = (start: 0.0, end: 1.0)
        let unpacked = fm.temporaryDirectory.appendingPathComponent("converterator-\(UUID().uuidString)", isDirectory: true)
        defer { if isArchive { try? fm.removeItem(at: unpacked) } }
        if isArchive {
            update(id) { $0.detail = "Unpacking \(src.pathExtension.lowercased())…" }
            if let err = await unpackArchive(src, to: unpacked) { return fail(err) }
            if cancelRequested { return fail("Cancelled") }
            games = Converter.gamesInFolder(unpacked)
            guard !games.isEmpty else { return fail("No .pbp, .cue, .gdi or .iso inside the archive") }
            append("  found \(games.map(\.lastPathComponent).joined(separator: ", "))")
            span = (0.1, 1.0)   // unpacking counts as the first 10%
            update(id) { $0.fraction = 0.1 }
        }

        var total = GameResult()
        for (i, game) in games.enumerated() {
            let w = (span.end - span.start) / Double(games.count)
            let start = span.start + w * Double(i)
            guard let r = await compressGame(game, id: id, outDir: outDir, span: (start, start + w),
                                             fail: { fail(games.count > 1 ? "\(game.lastPathComponent): \($0)" : $0) })
            else { return }
            total.made += r.made; total.skipped += r.skipped
            total.bytesIn += r.bytesIn; total.bytesOut += r.bytesOut
            total.redump += r.redump
        }
        // For an archive, "saved" compares the CHDs with the archive itself, which is what you had on disk.
        if isArchive && total.bytesOut > 0 { total.bytesIn = totalSize([src]) }

        let made = total.made
        var summary = made.count == 1 ? made[0].lastPathComponent : "\(made.count) CHDs"
        if total.skipped == made.count {
            summary += " · already existed"
        } else {
            summary += " · " + Converter.describeSaving(input: total.bytesIn, output: total.bytesOut)
        }
        if verify { summary += " · verified" }
        let unmatched = total.redump.first { !$0.isMatch }
        if !total.redump.isEmpty { summary += " · " + (unmatched?.short ?? "✓ Redump") }

        // Optional: move the originals to the Trash, only when every CHD was freshly and fully written.
        if trashSources {
            let outputsOK = made.allSatisfy { totalSize([$0]) > 0 }
            if total.skipped > 0 {
                append("  Kept source files: a CHD already existed and wasn't rewritten.")
            } else if !outputsOK {
                append("  Kept source files: a CHD looks empty or missing.")
            } else if unmatched != nil && RedumpDB.shared.keepUnmatched {
                append("  Kept source files: the dump doesn't match Redump (change this in Settings).")
                summary += " · originals kept"
            } else {
                var trashed = 0
                // An archive goes to the Trash as a whole; its unpacked copy is temporary anyway.
                for f in isArchive ? [src] : Converter.sourceFiles(for: src) {
                    do { try fm.trashItem(at: f, resultingItemURL: nil); trashed += 1 }
                    catch { append("  couldn't move \(f.lastPathComponent) to Trash: \(error.localizedDescription)") }
                }
                append("  moved \(trashed) source file\(trashed == 1 ? "" : "s") to Trash")
                summary += " · originals moved to Trash"
            }
        }

        // Remember which CHDs came from this file, so Clean Up Originals finds them even when renamed.
        ConversionLog.record(source: src, chds: made)
        update(id) { $0.outputs = made }

        // If every CHD already existed (and wasn't verified), this job took no real time:
        // keep it out of the speed estimate.
        let didWork = made.count > 0 && (made.count != total.skipped || verify || isArchive)
        update(id) {
            $0.state = .done; $0.detail = summary; $0.progress = nil; $0.timed = didWork
            $0.bytesIn = total.bytesIn; $0.bytesOut = total.bytesOut
        }
        append("✓ \(summary)")
    }

    /// Compresses one game (.pbp, .cue, .gdi or .iso) to one CHD per disc, plus an .m3u for
    /// multi-disc games. Progress goes into `span` of the job's 0…1. Returns nil after calling `fail`.
    private func compressGame(_ src: URL, id: UUID, outDir: URL, span: (Double, Double),
                              fail: (String) -> Void) async -> GameResult? {
        let fm = FileManager.default
        let base = src.deletingPathExtension().lastPathComponent
        let isPBP = src.pathExtension.lowercased() == "pbp"
        let tmp = fm.temporaryDirectory.appendingPathComponent("pbp2chd-\(UUID().uuidString)", isDirectory: true)
        defer { if isPBP { try? fm.removeItem(at: tmp) } }

        // Catch a .cue/.gdi whose track files are missing before chdman gets halfway.
        let missing = Converter.missingTracks(for: src)
        if !missing.isEmpty { fail(Converter.describeMissing(missing)); return nil }

        // Optional: compare the track files with Redump's list of known good dumps. PBPs are a
        // repackaged format, so their contents never match Redump and aren't checked.
        var redump: RedumpResult?
        if !isPBP, RedumpDB.shared.active {
            let index = RedumpDB.shared.index
            let tracks = src.pathExtension.lowercased() == "iso" ? [src] : Array(Converter.sourceFiles(for: src).dropFirst())
            update(id) { $0.detail = "Checking against Redump…"; $0.progress = 0 }
            let r = await Task.detached {
                RedumpResult.check(tracks: tracks, index: index) { p in
                    Task { @MainActor in
                        self.update(id) { $0.progress = p; $0.detail = "Checking against Redump — \(Int(p * 100))%" }
                    }
                }
            }.value
            if cancelRequested { fail("Cancelled"); return nil }
            append("  \(r.long)")
            redump = r
        }
        // Optional: name the CHD after the Redump game it matches, e.g. "Armored Core (USA).chd".
        var chdBase = base
        if case .match(let game) = redump, RedumpDB.shared.renameToRedump {
            let named = Converter.safeFileName(game)
            if named != base { append("  naming it after Redump: \(named).chd"); chdBase = named }
        }

        // PBP extraction counts as the first 20% of the game, compression the rest.
        let compressStart = isPBP ? 0.2 : 0.0
        func overall(_ p: Double) -> Double { span.0 + (span.1 - span.0) * p }

        // Step 1 (PBP only): PBP → BIN/CUE in a temp folder. CUE/GDI/ISO inputs go straight to chdman.
        var cues = [src]
        if isPBP {
            guard let psxpackager else { fail("PSXPackager is missing from the app, so .pbp files can't be converted"); return nil }
            update(id) { $0.detail = "Extracting BIN/CUE…"; $0.progress = nil }
            do { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) }
            catch { fail("Can't create temporary folder: \(error.localizedDescription)"); return nil }
            let s1 = await run(psxpackager, ["-i", src.path, "-o", tmp.path, "-x", "-v", "2"]) { [weak self] line in
                self?.append("  [psxpackager] \(line)")
            }
            if cancelRequested { fail("Cancelled"); return nil }
            cues = (fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension.lowercased() == "cue" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard s1 == 0 || !cues.isEmpty else { fail("PSXPackager failed (exit \(s1)) — see log"); return nil }
            guard !cues.isEmpty else { fail("PSXPackager produced no .cue file — see log"); return nil }
            update(id) { $0.fraction = overall(compressStart) }
        }
        let discCount = Double(cues.count)
        func jobFraction(disc n: Int, discProgress p: Double) -> Double {
            overall(compressStart + (1 - compressStart) * (Double(n) + p) / discCount)
        }

        // Step 2: BIN/CUE → CHD, one per disc
        var result = GameResult()
        // With Verify on, each disc's share of the job is 75% compressing, 25% verifying.
        let verifyShare = verify ? 0.25 : 0.0
        for (n, cue) in cues.enumerated() {
            let name = cues.count == 1 ? chdBase : cue.deletingPathExtension().lastPathComponent
            let out = outDir.appendingPathComponent(name + ".chd")
            let disc = cues.count == 1 ? "" : " disc \(n + 1) of \(cues.count)"
            var wroteThisDisc = false

            if fm.fileExists(atPath: out.path) && !overwrite {
                append("  \(out.lastPathComponent) already exists — skipped (turn on Overwrite to replace)")
                result.made.append(out)
                result.skipped += 1
                update(id) { $0.fraction = jobFraction(disc: n, discProgress: 1 - verifyShare) }
            } else {
                // .iso: CD or DVD. Everything else (.cue, .gdi, and PBP extractions) is a CD.
                var args = ["createcd", "-i", cue.path, "-o", out.path]
                if cue.pathExtension.lowercased() == "iso" {
                    let dvd: Bool
                    switch isoMode {
                    case .cd: dvd = false
                    case .dvd: dvd = true
                    case .automatic:
                        let (isDVD, why) = Converter.isoLooksLikeDVD(cue)
                        dvd = isDVD
                        append("  \(isDVD ? "DVD" : "CD") image: \(why)")
                    }
                    // One 2048-byte sector per hunk. chdman 0.263+ defaults to 4096, which PPSSPP warns
                    // about; 2048 is what PPSSPP's and PCSX2's guides recommend.
                    if dvd { args = ["createdvd", "-hs", "2048", "-i", cue.path, "-o", out.path] }
                }
                if overwrite { args.append("-f") }
                let s2 = await runChdman(args, id: id, label: "Compressing\(disc) to CHD") {
                    jobFraction(disc: n, discProgress: $0 * (1 - verifyShare))
                }
                if s2 != 0 || cancelRequested {
                    try? fm.removeItem(at: out)
                    fail(cancelRequested ? "Cancelled" : Converter.chdmanFailure(s2)); return nil
                }
                result.made.append(out)
                // A PBP's size is shared between its discs; a CUE/GDI/ISO counts its own track files.
                result.bytesIn += isPBP ? totalSize([src]) / discCount : totalSize(Converter.sourceFiles(for: cue))
                result.bytesOut += totalSize([out])
                wroteThisDisc = true
                // The CHD holds exactly what was checked, so remember its Redump result for later.
                if let redump, cues.count == 1 { RedumpCache.store(out, redump) }
            }

            // Optional: check the CHD's checksums, including CHDs that already existed.
            if verify {
                let s3 = await runChdman(["verify", "-i", out.path], id: id, label: "Verifying\(disc)") {
                    jobFraction(disc: n, discProgress: 1 - verifyShare + $0 * verifyShare)
                }
                if cancelRequested { fail("Cancelled"); return nil }
                if s3 != 0 {
                    // Delete a CHD we just wrote; leave one that was already there for the user to look at.
                    if wroteThisDisc { try? fm.removeItem(at: out) }
                    let why = s3 == Converter.stalledStatus ? "chdman stopped responding" : "see log"
                    fail("\(out.lastPathComponent) failed verification\(wroteThisDisc ? " and was deleted" : "") — \(why)")
                    return nil
                }
                append("  verified \(out.lastPathComponent)")
            }
        }

        if let redump { result.redump = [redump] }

        // Multi-disc playlist
        if result.made.count > 1 && makeM3U {
            let m3u = outDir.appendingPathComponent(base + ".m3u")
            let body = result.made.map { $0.lastPathComponent }.joined(separator: "\n") + "\n"
            do { try body.write(to: m3u, atomically: true, encoding: .utf8); append("  wrote \(m3u.lastPathComponent)") }
            catch { append("  couldn't write \(m3u.lastPathComponent): \(error.localizedDescription)") }
        }
        return result
    }

    // MARK: Archives

    nonisolated static let archiveExtensions: Set<String> = ["zip", "7z"]

    /// 7-Zip's command-line tool, from Homebrew's sevenzip (7zz) or p7zip (7z).
    var sevenZip: URL? { Converter.findTool("7zz") ?? Converter.findTool("7z") }

    /// Unpacks a .zip (with macOS's own ditto) or .7z (with 7-Zip). Returns an error message, or nil.
    private func unpackArchive(_ src: URL, to dir: URL) async -> String? {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return "Can't create temporary folder: \(error.localizedDescription)" }
        let exe: URL, args: [String]
        if src.pathExtension.lowercased() == "zip" {
            exe = URL(fileURLWithPath: "/usr/bin/ditto"); args = ["-x", "-k", src.path, dir.path]
        } else {
            guard let sz = sevenZip else {
                return ".7z files need 7-Zip. Install it in Terminal with:  brew install sevenzip"
            }
            exe = sz; args = ["x", "-y", "-bd", "-o" + dir.path, src.path]
        }
        let status = await run(exe, args) { [weak self] line in self?.append("  [\(exe.lastPathComponent)] \(line)") }
        return status == 0 ? nil : "Couldn't unpack the archive (exit \(status)) — see log"
    }

    /// Disc images in an unpacked archive, the way a folder scan finds them. A .bin with its own
    /// .cue is reached through the .cue.
    nonisolated static func gamesInFolder(_ dir: URL) -> [URL] {
        (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .allObjects as? [URL] ?? [])
            .filter { inputExtensions.contains($0.pathExtension.lowercased()) && !$0.path.contains("/__MACOSX/") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// File names inside a .zip, read from its central directory without unpacking it.
    /// Nil if it can't be read (for example a ZIP64 archive), so the caller can decide what to do.
    nonisolated static func zipEntryNames(_ url: URL) -> [String]? { zipEntries(url)?.map(\.name) }

    /// File names and unpacked sizes inside a .zip, from its central directory. A size is nil when it's
    /// stored in ZIP64 form.
    nonisolated static func zipEntries(_ url: URL) -> [(name: String, size: Double?)]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size >= 22 else { return nil }
        let tailLen = min(size, 65_557)
        guard (try? h.seek(toOffset: size - tailLen)) != nil, let tailData = try? h.read(upToCount: Int(tailLen)) else { return nil }
        let tail = [UInt8](tailData)
        func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func le32(_ b: [UInt8], _ i: Int) -> Int { le16(b, i) | le16(b, i + 2) << 16 }
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1)
            .first(where: { le32(tail, $0) == 0x06054b50 }) else { return nil }
        let cdSize = le32(tail, eocd + 12), cdOffset = le32(tail, eocd + 16)
        guard cdOffset != 0xFFFFFFFF, cdSize > 0, cdSize < 64 << 20, UInt64(cdOffset + cdSize) <= size else { return nil }
        guard (try? h.seek(toOffset: UInt64(cdOffset))) != nil, let cdData = try? h.read(upToCount: cdSize) else { return nil }
        let cd = [UInt8](cdData)
        var entries: [(name: String, size: Double?)] = [], i = 0
        while i + 46 <= cd.count, le32(cd, i) == 0x02014b50 {
            let n = le16(cd, i + 28), x = le16(cd, i + 30), c = le16(cd, i + 32)
            guard i + 46 + n <= cd.count else { break }
            let unpacked = le32(cd, i + 24)
            entries.append((String(decoding: cd[(i + 46)..<(i + 46 + n)], as: UTF8.self),
                            unpacked == 0xFFFFFFFF ? nil : Double(unpacked)))
            i += 46 + n + x + c
        }
        return entries
    }

    // MARK: Free space

    /// Upper estimates of what converting `src` needs: on the output disk, and on the Mac's disk for
    /// temporary files. CHDs are nearly always smaller than their discs; a PBP is unpacked first and its
    /// CHD can be bigger than the PBP; an archive is unpacked first.
    nonisolated static func spaceNeeded(for src: URL) -> (output: Double, temp: Double) {
        let size = totalSize(sourceFiles(for: src))
        switch src.pathExtension.lowercased() {
        case "pbp": return (size * 1.5, size * 3)
        case "zip":
            let entries = zipEntries(src) ?? []
            let unpacked = entries.allSatisfy({ $0.size != nil }) && !entries.isEmpty
                ? entries.reduce(0) { $0 + ($1.size ?? 0) } : size * 4
            return (unpacked, unpacked)
        case "7z": return (size * 4, size * 4)
        case "chd": return (0, 0)   // known once chdman has read it
        default: return (size, 0)
        }
    }

    /// A warning if the waiting files may not fit, per disk, or nil. Converting can still go ahead:
    /// each file is checked again just before it starts, and only the ones that don't fit fail.
    func batchSpaceWarning() -> String? {
        var needs: [String: (url: URL, bytes: Double)] = [:]
        var biggestTemp = 0.0
        for j in jobs where j.state == .queued {
            let n = Converter.spaceNeeded(for: j.url)
            let out = outputDir ?? j.url.deletingLastPathComponent()
            let key = DiskSpace.volumeID(out)
            needs[key] = (out, (needs[key]?.bytes ?? 0) + n.output)
            biggestTemp = max(biggestTemp, n.temp)   // temporary files are deleted after each file
        }
        var lines: [String] = []
        for (_, n) in needs.sorted(by: { $0.key < $1.key }) {
            if let free = DiskSpace.free(at: n.url), free < n.bytes + DiskSpace.margin {
                lines.append("These files may need up to \(formatBytes(n.bytes)) on \(DiskSpace.volumeName(n.url)), which has \(formatBytes(free)) free.")
            }
        }
        if let p = DiskSpace.problem(needs: biggestTemp, at: FileManager.default.temporaryDirectory) {
            lines.append("The biggest file needs room for temporary files on your Mac's disk. \(p).")
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n\n")
            + "\n\nCHDs are usually much smaller than these upper estimates. If you go ahead, each file is checked again before it starts, and any that don't fit are marked failed."
    }

    /// Whether a folder scan should pick up this archive: only if it has a disc image inside, so a folder
    /// of zipped cartridge games doesn't fill the list. .7z needs 7-Zip to look inside.
    func archiveHasDiscImage(_ url: URL) -> Bool {
        let wanted = Converter.inputExtensions
        if url.pathExtension.lowercased() == "zip" {
            guard let names = Converter.zipEntryNames(url) else { return true }   // can't tell: let the job decide
            return names.contains { wanted.contains(($0 as NSString).pathExtension.lowercased()) }
        }
        guard let sz = sevenZip else { return false }
        let p = Process()
        p.executableURL = sz
        p.arguments = ["l", "-ba", "-slt", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").contains { line in
            line.hasPrefix("Path = ") && wanted.contains((String(line.dropFirst(7)) as NSString).pathExtension.lowercased())
        }
    }

    // MARK: Track files

    /// Track files a .cue or .gdi lists that aren't next to it. Empty for other files.
    nonisolated static func missingTracks(for src: URL) -> [String] {
        let dir = src.deletingLastPathComponent()
        return trackNames(in: src).filter { !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    nonisolated static func describeMissing(_ names: [String]) -> String {
        let shown = names.prefix(2).joined(separator: ", ")
        return "Missing track file\(names.count == 1 ? "" : "s"): \(shown)\(names.count > 2 ? " and \(names.count - 2) more" : "")"
    }

    /// A Redump game name made safe as a file name: no "/" or ":" (which Finder shows as "/"), not too long.
    nonisolated static func safeFileName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.utf8.count > 200 { s = String(s.prefix(180)) }
        return s.isEmpty ? "Untitled" : s
    }

    /// "412 MB, saved 260 MB (39%)", or just the size when the CHD isn't smaller (common for PBPs,
    /// which are already compressed).
    nonisolated static func describeSaving(input: Double, output: Double) -> String {
        guard input > output, input > 0 else { return formatBytes(output) }
        return "\(formatBytes(output)), saved \(formatBytes(input - output)) (\(Int(((input - output) / input * 100).rounded()))%)"
    }

    /// Runs chdman, showing its "45.3% complete" counter as `label — 45%` on the job.
    /// `fraction` maps the tool's 0…1 progress onto the whole job's 0…1 for the batch bar.
    /// Returned by runChdman when chdman stopped making progress and was stopped.
    nonisolated static let stalledStatus: Int32 = -2
    /// How long chdman may go without its percentage moving. Its counter steps every 0.1%, which
    /// even a 9 GB DVD on a slow drive passes in seconds; chdman can hang forever verifying a damaged CHD.
    static var stallTimeout: TimeInterval = 180

    /// The failure text for a chdman exit status.
    static func chdmanFailure(_ status: Int32) -> String {
        status == stalledStatus
            ? "chdman stopped responding (no progress for \(Int(stallTimeout / 60)) minutes) — the file may be damaged"
            : "chdman failed (exit \(status)) — see log"
    }

    private func runChdman(_ args: [String], id: UUID, label: String,
                           fraction: @escaping (Double) -> Double) async -> Int32 {
        update(id) { $0.detail = label + "…"; $0.progress = 0; $0.fraction = fraction(0) }
        var lastPct = -1.0
        var lastChange = Date()
        var stalled = false
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(5, Converter.stallTimeout / 2)))
                if Task.isCancelled { break }
                if Date().timeIntervalSince(lastChange) > Converter.stallTimeout {
                    stalled = true
                    self?.append("  chdman made no progress for \(Int(Converter.stallTimeout)) seconds; stopping it.")
                    self?.currentProcess?.terminate()
                    break
                }
            }
        }
        defer { watchdog.cancel() }
        let status = await run(chdman!, args) { [weak self] line in
            if let r = line.range(of: #"([0-9.]+)% complete"#, options: .regularExpression) {
                let pct = Double(line[r].split(separator: "%")[0]) ?? 0
                if pct != lastPct { lastPct = pct; lastChange = Date() }
                self?.update(id) {
                    $0.progress = pct / 100
                    $0.fraction = fraction(pct / 100)
                    $0.detail = "\(label) — \(Int(pct))%"
                }
            } else {
                self?.append("  [chdman] \(line)")
            }
        }
        return stalled ? Converter.stalledStatus : status
    }

    /// The unpacked size from a `chdman info` line: "Logical size: 1,411,200 bytes".
    nonisolated static func logicalSize(_ line: String) -> Double? {
        guard line.hasPrefix("Logical size") else { return nil }
        let digits = line.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "," }.filter(\.isNumber)
        return Double(digits)
    }

    // MARK: CHD → BIN/CUE

    /// Unpacks a CHD back to what it was made from: BIN/CUE for a CD, GDI and tracks for a
    /// Dreamcast GD-ROM, or ISO for a DVD.
    private func extract(index: Int) async {
        let job = jobs[index]
        let id = job.id
        let fm = FileManager.default
        let src = job.url
        let base = src.deletingPathExtension().lastPathComponent
        let outDir = outputDir ?? src.deletingLastPathComponent()

        func fail(_ msg: String) {
            update(id) { $0.state = .failed; $0.detail = msg; $0.progress = nil; $0.timed = false }
            append("✗ \(src.lastPathComponent): \(msg)")
        }

        update(id) { $0.state = .working; $0.detail = "Reading CHD…"; $0.progress = nil; $0.fraction = 0; $0.timed = true }
        append("▶ \(src.lastPathComponent)")
        guard fm.fileExists(atPath: src.path) else {
            return fail("Can't find the file. If it's on an external drive, connect it, then use Clear → Retry Failed.")
        }
        do { try fm.createDirectory(at: outDir, withIntermediateDirectories: true) }
        catch { return fail("Can't create folder: \(error.localizedDescription)") }

        // `chdman info` lists metadata tags: CHT2/CHCD/CHTR = CD, CHGD/CHGT = GD-ROM, "DVD " = DVD.
        var tags: [String] = []
        var logical = 0.0
        let s0 = await run(chdman!, ["info", "-i", src.path]) { [weak self] line in
            if let r = line.range(of: #"Tag='[^']{4}'"#, options: .regularExpression) {
                tags.append(String(line[r].dropFirst(5).prefix(4)))
            }
            if let size = Converter.logicalSize(line) { logical = size }
            if line.hasPrefix("Error") { self?.append("  [chdman] \(line)") }
        }
        if cancelRequested { return fail("Cancelled") }
        guard s0 == 0 else { return fail("chdman couldn't read this CHD (exit \(s0)) — see log") }

        let command: String, out: URL
        if tags.contains(where: { $0 == "CHGD" || $0 == "CHGT" }) {
            command = "extractcd"; out = outDir.appendingPathComponent(base + ".gdi")
        } else if tags.contains(where: { ["CHT2", "CHCD", "CHTR"].contains($0) }) {
            command = "extractcd"; out = outDir.appendingPathComponent(base + ".cue")
        } else if tags.contains("DVD ") {
            command = "extractdvd"; out = outDir.appendingPathComponent(base + ".iso")
        } else {
            return fail("Not a CD or DVD image, so it can't be extracted to BIN/CUE or ISO")
        }

        if fm.fileExists(atPath: out.path) && !overwrite {
            append("  \(out.lastPathComponent) already exists — skipped (turn on Overwrite to replace)")
            update(id) { $0.state = .done; $0.detail = "\(out.lastPathComponent) · already existed"; $0.progress = nil; $0.timed = false }
            return
        }

        if let p = DiskSpace.problem(needs: logical, at: outDir) { return fail(p) }
        var args = [command, "-i", src.path, "-o", out.path]
        if overwrite { args.append("-f") }
        let s1 = await runChdman(args, id: id, label: "Extracting") { $0 }
        // What was written: the .cue/.gdi plus the track files it lists, or the .iso.
        let written = fm.fileExists(atPath: out.path) ? Converter.sourceFiles(for: out) : []
        if s1 != 0 || cancelRequested {
            for f in written { try? fm.removeItem(at: f) }
            if command == "extractcd" && out.pathExtension == "cue" {
                try? fm.removeItem(at: out.deletingPathExtension().appendingPathExtension("bin"))
            }
            return fail(cancelRequested ? "Cancelled" : Converter.chdmanFailure(s1))
        }

        let size = totalSize(written)
        let extra = written.count - 1
        var summary = out.lastPathComponent + (extra > 0 ? " + \(extra) track file\(extra == 1 ? "" : "s")" : "")
        summary += " · \(formatBytes(size))"

        if trashSources {
            if size > 0 {
                do { try fm.trashItem(at: src, resultingItemURL: nil); append("  moved \(src.lastPathComponent) to Trash"); summary += " · CHD moved to Trash" }
                catch { append("  couldn't move \(src.lastPathComponent) to Trash: \(error.localizedDescription)") }
            } else {
                append("  Kept the CHD: the extracted files look empty.")
            }
        }
        update(id) {
            $0.state = .done; $0.detail = summary; $0.progress = nil
            $0.bytesIn = job.weight; $0.bytesOut = size
        }
        append("✓ \(summary)")
    }

    // MARK: ISO type

    /// Guesses whether an .iso is a DVD (→ createdvd) or a CD (→ createcd), with a reason for the log.
    /// PSP UMDs and PS2 DVDs are DVDs; so is anything too big to fit on a CD.
    nonisolated static func isoLooksLikeDVD(_ url: URL) -> (Bool, String) {
        let size = totalSize([url])
        let cdCapacity = 900_000_000.0   // a 99-minute CD holds about 870 MB of 2048-byte sectors
        let names = isoRootNames(url)
        if names.contains("PSP_GAME") || names.contains("UMD_DATA.BIN") { return (true, "PSP game") }
        if names.contains("SYSTEM.CNF"), let cnf = isoRootFile(url, named: "SYSTEM.CNF"),
           String(decoding: cnf, as: UTF8.self).uppercased().contains("BOOT2") {
            return (true, "PlayStation 2 game")
        }
        if size > cdCapacity { return (true, "\(formatBytes(size)) is too big for a CD") }
        return (false, "\(formatBytes(size)) fits on a CD")
    }

    /// Reads an ISO 9660 image's root directory: file and folder names (upper-cased, without ";1"),
    /// with each one's location and size.
    nonisolated static func isoRootEntries(_ url: URL) -> [String: (lba: UInt64, size: Int)] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? h.close() }
        func read(_ offset: UInt64, _ count: Int) -> [UInt8] {
            guard (try? h.seek(toOffset: offset)) != nil, let d = try? h.read(upToCount: count) else { return [] }
            return [UInt8](d)
        }
        func le32(_ b: [UInt8], _ i: Int) -> Int {
            Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
        }
        // Primary volume descriptor at sector 16: type 1, "CD001".
        let pvd = read(16 * 2048, 2048)
        guard pvd.count == 2048, pvd[0] == 1, Array(pvd[1...5]) == Array("CD001".utf8) else { return [:] }
        let rootLBA = le32(pvd, 156 + 2), rootSize = min(le32(pvd, 156 + 10), 64 * 1024)
        let dir = read(UInt64(rootLBA) * 2048, rootSize)
        var result: [String: (lba: UInt64, size: Int)] = [:]
        var i = 0
        while i < dir.count {
            let len = Int(dir[i])
            if len == 0 { i = (i / 2048 + 1) * 2048; continue }   // records don't cross sector boundaries
            guard i + len <= dir.count, len >= 34 else { break }
            let nameLen = Int(dir[i + 32])
            if nameLen > 0, i + 33 + nameLen <= dir.count {
                var name = String(decoding: dir[(i + 33)..<(i + 33 + nameLen)], as: UTF8.self).uppercased()
                if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
                if name.hasSuffix(".") { name.removeLast() }
                result[name] = (UInt64(le32(dir, i + 2)), le32(dir, i + 10))
            }
            i += len
        }
        return result
    }

    nonisolated static func isoRootNames(_ url: URL) -> Set<String> { Set(isoRootEntries(url).keys) }

    nonisolated static func isoRootFile(_ url: URL, named name: String) -> Data? {
        guard let e = isoRootEntries(url)[name], e.size > 0, e.size < 64 * 1024,
              let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: e.lba * 2048)) != nil else { return nil }
        return try? h.read(upToCount: e.size)
    }

    /// The input file plus any track files it references (for .cue and .gdi), limited to files that
    /// exist inside the input's own folder.
    nonisolated static func sourceFiles(for src: URL) -> [URL] {
        let dir = src.deletingLastPathComponent().standardizedFileURL
        var result = [src]
        var seen: Set<String> = [src.standardizedFileURL.path]
        for name in trackNames(in: src) {
            let f = dir.appendingPathComponent(name).standardizedFileURL
            guard f.path.hasPrefix(dir.path + "/"),
                  FileManager.default.fileExists(atPath: f.path),
                  seen.insert(f.path).inserted else { continue }
            result.append(f)
        }
        return result
    }

    /// The track file names a .cue (FILE lines) or .gdi (one line per track) lists, as written.
    nonisolated static func trackNames(in src: URL) -> [String] {
        let ext = src.pathExtension.lowercased()
        var names: [String] = []

        if ext == "cue" || ext == "gdi", let data = try? Data(contentsOf: src) {
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let lines = text.components(separatedBy: .newlines)
            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if let q1 = line.firstIndex(of: "\""), let q2 = line.lastIndex(of: "\""), q1 < q2 {
                    // Quoted file name: FILE "Game (Track 1).bin" BINARY  /  1 0 4 2352 "track 01.bin" 0
                    if ext == "gdi" || line.uppercased().hasPrefix("FILE ") {
                        names.append(String(line[line.index(after: q1)..<q2]))
                    }
                    continue
                }
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                if ext == "cue", parts.count >= 2, parts[0].uppercased() == "FILE" {
                    names.append(parts[1])
                } else if ext == "gdi", i > 0, parts.count >= 5 {
                    names.append(parts[4])   // track# lba type sectorsize FILENAME offset
                }
            }
        }

        return names
    }

    /// Runs a command-line tool, streaming its output line by line to `onLine` on the main thread.
    private func run(_ exe: URL, _ args: [String], onLine: @escaping (String) -> Void) async -> Int32 {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = Converter.toolEnvironment
        p.currentDirectoryURL = exe.deletingLastPathComponent()
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let buffer = LineBuffer { line in DispatchQueue.main.async { onLine(line) } }
        let reader = pipe.fileHandleForReading

        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            reader.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { buffer.feed(d) }
            }
            p.terminationHandler = { proc in
                reader.readabilityHandler = nil
                buffer.feed(reader.readDataToEndOfFile())
                buffer.flush()
                let status = proc.terminationStatus
                DispatchQueue.main.async { cont.resume(returning: status) }
            }
            do {
                try p.run()
                currentProcess = p
            } catch {
                reader.readabilityHandler = nil
                onLine("Couldn't launch \(exe.lastPathComponent): \(error.localizedDescription)")
                cont.resume(returning: -1)
            }
        }
    }
}
