// Converterator — a small macOS front end for PSXPackager (PBP → BIN/CUE) and chdman (BIN/CUE → CHD).
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Model

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

@MainActor
final class Converter: ObservableObject {
    static let shared = Converter()

    @Published var jobs: [Job] = []
    @Published var log: String = ""
    @Published var isRunning = false
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

    init() {
        let d = UserDefaults.standard
        if let p = d.string(forKey: "outputDir"), FileManager.default.fileExists(atPath: p) {
            outputDir = URL(fileURLWithPath: p, isDirectory: true)
        }
        overwrite = d.bool(forKey: "overwrite")
        makeM3U = d.object(forKey: "makeM3U") as? Bool ?? true
        verify = d.bool(forKey: "verify")
        isoMode = ISOMode(rawValue: d.string(forKey: "isoMode") ?? "") ?? .automatic
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

    static let toolEnvironment: [String: String] = {
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
        if isRunning { batchIDs += newJobs.filter { $0.state == .queued }.map(\.id) }
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
            jobs[i].bytesIn = 0; jobs[i].bytesOut = 0
        }
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
        cancelRequested = true
        currentProcess?.terminate()
    }

    // MARK: Conversion

    func start() {
        guard !isRunning, toolsReady else { return }
        isRunning = true
        cancelRequested = false
        batchIDs = jobs.filter { $0.state == .queued }.map(\.id)
        batchStart = Date()
        batchEnd = nil
        // Stop the Mac from idle-sleeping mid-batch. The display can still sleep; closing a laptop lid still sleeps.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Converting disc images")
        Notifier.requestPermission()
        Task {
            while !cancelRequested, let i = jobs.firstIndex(where: { $0.state == .queued }) {
                if jobs[i].isExtraction { await extract(index: i) } else { await convert(index: i) }
            }
            batchEnd = Date()
            isRunning = false
            if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
            append(cancelRequested ? "— Cancelled —" : "— All done —")
            if !cancelRequested {
                Notifier.batchFinished(counts: batchCountsText, saved: batchSavedText, failed: batchFailedCount > 0)
            }
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
        do { try fm.createDirectory(at: outDir, withIntermediateDirectories: true) }
        catch { return fail("Can't create folder: \(error.localizedDescription)") }

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

        // Optional: move the originals to the Trash, only when every CHD was freshly and fully written.
        if trashSources {
            let outputsOK = made.allSatisfy { totalSize([$0]) > 0 }
            if total.skipped > 0 {
                append("  Kept source files: a CHD already existed and wasn't rewritten.")
            } else if !outputsOK {
                append("  Kept source files: a CHD looks empty or missing.")
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
            let name = cues.count == 1 ? base : cue.deletingPathExtension().lastPathComponent
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
    nonisolated static func zipEntryNames(_ url: URL) -> [String]? {
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
        var names: [String] = [], i = 0
        while i + 46 <= cd.count, le32(cd, i) == 0x02014b50 {
            let n = le16(cd, i + 28), x = le16(cd, i + 30), c = le16(cd, i + 32)
            guard i + 46 + n <= cd.count else { break }
            names.append(String(decoding: cd[(i + 46)..<(i + 46 + n)], as: UTF8.self))
            i += 46 + n + x + c
        }
        return names
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

    /// "412 MB, saved 260 MB (39%)", or just the size when the CHD isn't smaller (common for PBPs,
    /// which are already compressed).
    nonisolated static func describeSaving(input: Double, output: Double) -> String {
        guard input > output, input > 0 else { return formatBytes(output) }
        return "\(formatBytes(output)), saved \(formatBytes(input - output)) (\(Int(((input - output) / input * 100).rounded()))%)"
    }

    /// Runs chdman, showing its "45.3% complete" counter as `label — 45%` on the job.
    /// `fraction` maps the tool's 0…1 progress onto the whole job's 0…1 for the batch bar.
    /// Returned by runChdman when chdman stopped making progress and was stopped.
    static let stalledStatus: Int32 = -2
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
        do { try fm.createDirectory(at: outDir, withIntermediateDirectories: true) }
        catch { return fail("Can't create folder: \(error.localizedDescription)") }

        // `chdman info` lists metadata tags: CHT2/CHCD/CHTR = CD, CHGD/CHGT = GD-ROM, "DVD " = DVD.
        var tags: [String] = []
        let s0 = await run(chdman!, ["info", "-i", src.path]) { [weak self] line in
            if let r = line.range(of: #"Tag='[^']{4}'"#, options: .regularExpression) {
                tags.append(String(line[r].dropFirst(5).prefix(4)))
            }
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

// MARK: - Updates

/// Checks the GitHub "latest release" for a newer version and offers to open its download page.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "nickgudauskas/Converterator"
    nonisolated static let bundleID = "local.converterator"

    @Published var isChecking = false
    /// "Downloading update…" etc. while an update installs, nil otherwise.
    @Published var installStatus: String?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when version `a` is newer than `b`, comparing numerically ("1.10" > "1.9"). A leading "v" is ignored.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespaces)
                .drop(while: { $0 == "v" || $0 == "V" })
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let html_url: String
        let assets: [Asset]?
    }

    func check() {
        guard !isChecking, installStatus == nil else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = String(release.tag_name.drop(while: { $0 == "v" || $0 == "V" }))

                guard Self.isNewer(latest, than: currentVersion) else {
                    show(title: "You're up to date",
                         message: "Converterator \(currentVersion) is the latest version.", buttons: ["OK"])
                    return
                }
                // Only ever open or download this repo's own release files.
                let prefix = "https://github.com/\(Self.repo)/"
                let page = URL(string: release.html_url).filter { $0.absoluteString.hasPrefix(prefix) }
                    ?? URL(string: "https://github.com/\(Self.repo)/releases/latest")!
                let zip = release.assets?.first { $0.name == "Converterator.zip" }
                    .flatMap { URL(string: $0.browser_download_url) }
                    .filter { $0.absoluteString.hasPrefix(prefix + "releases/download/") }

                let blocker = installBlocker(hasZip: zip != nil)
                var message = "You have version \(currentVersion)."
                if let blocker {
                    message += " Download the new version from GitHub, then replace the app in your Applications folder.\n\n(\(blocker))"
                    show(title: "Converterator \(latest) is available", message: message,
                         buttons: ["Download", "Later"]) { if $0 == 0 { NSWorkspace.shared.open(page) } }
                } else {
                    message += " Converterator can download and install it now, then reopen itself. Your settings are kept."
                    show(title: "Converterator \(latest) is available", message: message,
                         buttons: ["Install and Relaunch", "Later", "View Release Notes"]) { choice in
                        if choice == 0, let zip { self.install(from: zip, version: latest, releasePage: page) }
                        if choice == 2 { NSWorkspace.shared.open(page) }
                    }
                }
            } catch {
                show(title: "Couldn't check for updates",
                     message: "GitHub couldn't be reached. Check your internet connection and try again.\n\n(\(error.localizedDescription))",
                     buttons: ["OK"])
            }
        }
    }

    /// Why this copy can't update itself, or nil if it can.
    private func installBlocker(hasZip: Bool) -> String? {
        if Converter.shared.isRunning { return "A batch is converting. To install from inside the app, check again when it's finished." }
        if !hasZip { return "This release has no Converterator.zip to install automatically." }
        if Self.teamID(ofCodeAt: Bundle.main.bundleURL) == nil {
            return "This copy wasn't downloaded from GitHub (it isn't signed with a Developer ID), so it can't update itself."
        }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: parent.path) {
            return "Converterator can't write to \(parent.path(percentEncoded: false))."
        }
        if Bundle.main.bundleURL.path.contains("/AppTranslocation/") {
            return "Move Converterator to your Applications folder first."
        }
        return nil
    }

    private func install(from zip: URL, version: String, releasePage: URL) {
        installStatus = "Downloading update…"
        Task {
            do {
                let (file, response) = try await URLSession.shared.download(from: zip)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub returned an error.") }
                installStatus = "Installing update…"
                let app = Bundle.main.bundleURL
                guard let team = Self.teamID(ofCodeAt: app) else { throw UpdateError("This copy isn't signed with a Developer ID.") }
                try await Task.detached {
                    try UpdateChecker.installUpdate(zip: file, expectedVersion: version, teamID: team, replacing: app)
                }.value
                Self.relaunch(app)
            } catch {
                installStatus = nil
                show(title: "Couldn't install the update",
                     message: "\(error.localizedDescription)\n\nYou can download it from GitHub instead. Nothing was changed.",
                     buttons: ["Download", "Cancel"]) { if $0 == 0 { NSWorkspace.shared.open(releasePage) } }
            }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Unpacks the downloaded zip, checks the app inside, and swaps it in for the app at `target`.
    /// The new app must have the same bundle ID, the expected version, a valid signature from the same
    /// Developer ID team as this copy, and Gatekeeper's approval (notarized). Throws without touching
    /// `target` if anything doesn't match.
    nonisolated static func installUpdate(zip: URL, expectedVersion: String, teamID: String, replacing target: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("converterator-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        guard runTool("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else { throw UpdateError("The download couldn't be unzipped.") }
        let new = work.appendingPathComponent("Converterator.app")
        guard let info = NSDictionary(contentsOf: new.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError("The download doesn't contain Converterator.") }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateError("The download is a different version than expected.")
        }
        guard validSignature(new, teamID: teamID) else {
            throw UpdateError("The download isn't signed by the same developer as this copy, so it wasn't installed.")
        }
        guard runTool("/usr/sbin/spctl", ["--assess", "--type", "execute", new.path]) == 0 else {
            throw UpdateError("macOS Gatekeeper didn't approve the download, so it wasn't installed.")
        }

        // Copy next to the current app first (same volume), then swap it in.
        let staged = target.deletingLastPathComponent().appendingPathComponent(".Converterator-update-\(UUID().uuidString).app")
        guard runTool("/usr/bin/ditto", [new.path, staged.path]) == 0 else {
            try? fm.removeItem(at: staged)
            throw UpdateError("The new version couldn't be copied next to the current one.")
        }
        do {
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// Checks the code signature of every architecture and nested executable, and that it's a
    /// Developer ID signature for this app from the given team.
    nonisolated static func validSignature(_ app: URL, teamID: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let safeTeam = teamID.filter { $0.isLetter || $0.isNumber }
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(safeTeam)\""
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    /// The Developer ID team that signed the code at `url`, or nil (ad-hoc or unsigned).
    nonisolated static func teamID(ofCodeAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated static func runTool(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Quits, and reopens the app once this process has exited.
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Shows an alert as a sheet on the main window. `onChoice` gets the index of the button clicked.
    private func show(title: String, message: String, buttons: [String], onChoice: ((Int) -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for b in buttons { alert.addButton(withTitle: b) }
        let handle: (NSApplication.ModalResponse) -> Void = { onChoice?($0.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        // Attach to the window as a sheet so it can't get lost behind other windows.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}

// MARK: - Notifications

/// Posts "Batch finished" to Notification Center when a batch ends while you're in another app.
enum Notifier {
    /// Asks once; macOS remembers the answer, and it can be changed in System Settings → Notifications.
    /// Notification Center only works for a real .app bundle.
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor
    static func batchFinished(counts: String, saved: String?, failed: Bool) {
        guard available, !NSApp.isActive else { return }   // you're looking at the window already
        let content = UNMutableNotificationContent()
        content.title = failed ? "Batch finished with errors" : "Batch finished"
        content.body = ([counts] + (saved.map { [$0] } ?? [])).joined(separator: " · ")
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "batch-finished", content: content, trigger: nil))
    }
}

extension Optional {
    /// Keeps the value only if it passes `test`.
    func filter(_ test: (Wrapped) -> Bool) -> Wrapped? { flatMap { test($0) ? $0 : nil } }
}

// MARK: - UI

struct ContentView: View {
    @ObservedObject private var c = Converter.shared
    @ObservedObject private var updater = UpdateChecker.shared
    @State private var dropTargeted = false
    @State private var showLog = false
    @State private var confirmCancel = false
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            if !c.toolsReady { missingToolsBanner }

            Group {
                if c.jobs.isEmpty { dropPrompt } else { jobList }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .opacity(dropTargeted ? 1 : 0)
                    .padding(4)
            )
            .dropDestination(for: URL.self) { urls, _ in
                c.add(urls); return true
            } isTargeted: { dropTargeted = $0 }

            Divider()
            options.padding(.horizontal, 14).padding(.vertical, 10)

            if showLog {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(c.log.isEmpty ? "Nothing yet." : c.log)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(height: 160)
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: c.log) { _, _ in proxy.scrollTo("bottom") }
                }
            }

            Divider()
            if !c.batchJobs.isEmpty {
                batchBar.padding(.horizontal, 14).padding(.top, 10)
            }
            bottomBar.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(minWidth: 560, minHeight: 420)
        .alert("Stop converting?", isPresented: $confirmCancel) {
            Button("Stop Converting", role: .destructive) {
                if c.isRunning { c.cancel() }   // the batch may have finished while the dialog was open
            }
            Button("Keep Converting", role: .cancel) {}
        } message: {
            Text(cancelMessage)
        }
        .onChange(of: c.isRunning) { _, running in
            if !running { confirmCancel = false }   // nothing left to cancel
        }
        .onChange(of: c.batchProgress) { _, p in
            // Percentage on the Dock icon while a batch runs.
            NSApp.dockTile.badgeLabel = c.isRunning ? "\(Int(p * 100))%" : nil
        }
        .onChange(of: c.isRunning) { _, running in
            if !running { NSApp.dockTile.badgeLabel = nil }
        }
        // Coming back from Terminal after installing chdman clears the banner without a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: .addFiles)) { _ in
            if !c.isRunning { pickFiles() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopConverting)) { _ in
            if c.isRunning { confirmCancel = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleLog)) { _ in showLog.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            c.recheckTools()
        }
    }

    /// Explains what Stop Converting does to the current file and the rest of the queue.
    private var cancelMessage: String {
        var lines: [String] = []
        if let current = c.jobs.first(where: { $0.state == .working }) {
            lines.append("“\(current.url.lastPathComponent)” will be stopped, and its unfinished CHD deleted. Your original files aren't touched.")
        }
        let waiting = c.batchQueuedCount
        if waiting > 0 {
            lines.append("\(waiting) file\(waiting == 1 ? "" : "s") not started yet will stay in the list, so you can convert \(waiting == 1 ? "it" : "them") later.")
        }
        lines.append("CHDs already finished in this batch are kept.")
        return lines.joined(separator: "\n\n")
    }

    /// Overall progress for the whole Convert run, then a summary once it finishes.
    private var batchBar: some View {
        // Ticks every second so the estimate keeps moving even while a file reports no progress.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            batchBarContent(now: timeline.date)
        }
    }

    private func batchBarContent(now: Date) -> some View {
        let total = c.batchJobs.count
        let finished = c.batchDoneCount + c.batchFailedCount
        let pct = Int(c.batchProgress * 100)
        let status: String
        var timeText = ""
        if c.isRunning {
            status = "Converting file \(min(finished + 1, total)) of \(total)"
            timeText = c.batchTimeRemaining(now: now).map(Converter.describeRemaining) ?? "Estimating time left…"
        } else {
            status = "Batch finished: " + c.batchCountsText
            var parts: [String] = []
            if let s = c.batchStart, let e = c.batchEnd {
                parts.append("Took " + Converter.describeDuration(e.timeIntervalSince(s)))
            }
            if let saved = c.batchSavedText { parts.append(saved) }
            timeText = parts.joined(separator: " · ")
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(status)
                Spacer()
                Text("\(pct)%").monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(c.isRunning ? .primary : .secondary)
            ProgressView(value: c.batchProgress)
                .tint(!c.isRunning && c.batchFailedCount > 0 ? .orange : .accentColor)
            if !timeText.isEmpty {
                Text(timeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    static let installCommand = "brew install rom-tools"
    @State private var copiedCommand = false

    private var missingToolsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if c.chdman == nil {
                Label("Converterator needs chdman, from the free rom-tools package.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if Converter.homebrewInstalled {
                    Text("Open Terminal, paste this command and press Return. The banner goes away once it's installed.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Text("First install Homebrew by following the steps at").foregroundStyle(.secondary)
                        Link("brew.sh", destination: URL(string: "https://brew.sh")!)
                        Text("Then run this in Terminal:").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(Self.installCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                    Button(copiedCommand ? "Copied" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.installCommand, forType: .string)
                        copiedCommand = true
                    }
                    Button("Open Terminal") {
                        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                            NSWorkspace.shared.openApplication(at: terminal, configuration: .init())
                        }
                    }
                    Button("Check Again") { c.recheckTools() }
                }
            }
            if c.psxpackager == nil {
                Label("PSXPackager is missing from the app, so .pbp files can't be converted. Download Converterator again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private var dropPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "opticaldisc").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Drop .pbp, .cue, .gdi, .iso, .zip or .7z files (or folders) here").font(.title3)
            Text("BIN/CUE, GDI and ISO images are compressed straight to CHD. PBPs and zip or 7z archives are unpacked first, and those temporary files are cleaned up. Drop a .chd file to turn it back into BIN/CUE, GDI or ISO.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Add Files…", action: pickFiles).padding(.top, 4)
        }
        .padding(30)
    }

    private var jobList: some View {
        List(selection: $selection) {
            ForEach(c.jobs) { job in
                HStack(spacing: 10) {
                    icon(for: job).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        if let p = job.progress, job.state == .working {
                            ProgressView(value: p).controlSize(.small)
                        }
                        Text(job.detail).font(.caption)
                            .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
                    // Acts on the whole selection when the clicked row is part of it.
                    let targets = selection.contains(job.id) ? selection : [job.id]
                    Button(targets.count > 1 ? "Remove \(targets.count) from List" : "Remove from List") {
                        removeFromList(targets)
                    }
                    .disabled(job.state == .working && targets.count == 1)
                }
            }
        }
        // Delete (⌫) removes the selected rows.
        .onDeleteCommand { removeFromList(selection) }
    }

    @ViewBuilder private func icon(for job: Job) -> some View {
        switch job.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Save to:")
                Text(c.outputDir?.path(percentEncoded: false) ?? "Same folder as each source file")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…", action: pickOutput)
                if c.outputDir != nil { Button("Reset") { c.outputDir = nil } }
            }
            HStack(spacing: 20) {
                Toggle("Overwrite existing CHDs", isOn: $c.overwrite)
                Toggle("Make .m3u playlist for multi-disc games", isOn: $c.makeM3U)
            }
            HStack(spacing: 20) {
                Toggle("Verify CHDs after writing", isOn: $c.verify)
                    .help("Checks each CHD's checksums with chdman verify. CHDs that already exist are checked too, so you can re-add a folder to test it.")
                Picker("ISO images:", selection: $c.isoMode) {
                    ForEach(ISOMode.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                .help("Automatic makes a DVD CHD for PS2 and PSP games and anything bigger than a CD, and a CD CHD otherwise.")
            }
            Toggle("Move source files to Trash after a successful conversion", isOn: $c.trashSources)
                .help("Moves the .pbp/.cue/.gdi/.iso file and any .bin tracks it lists to the Trash, only after its CHD is written. For a .chd you extract, moves the .chd. Turns off each time the app starts.")
        }
        .disabled(c.isRunning)
    }

    /// "Version 1.2.2" from the app's Info.plist (set in build.sh).
    static let versionLabel: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v.map { "Version \($0)" } ?? ""
    }()

    private var bottomBar: some View {
        HStack {
            Button("Add Files…", action: pickFiles).disabled(c.isRunning)
            Menu("Clear") {
                Button("Clear Finished", action: c.clearFinished)
                Button("Retry Failed", action: c.retryFailed)
                Button("Clear All", action: c.clearAll)
            }
            .fixedSize()
            .disabled(c.isRunning || c.jobs.isEmpty)
            Toggle("Show Log", isOn: $showLog).toggleStyle(.button)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.versionLabel)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                if let status = updater.installStatus {
                    Text(status).foregroundStyle(.secondary)
                } else if updater.isChecking {
                    Text("Checking…").foregroundStyle(.secondary)
                } else {
                    Button("Check for Updates") { updater.check() }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
                .padding(.trailing, 6)
            if c.isRunning {
                Button("Cancel", role: .cancel) { confirmCancel = true }
            } else {
                Button("Convert", action: c.start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!c.toolsReady || !c.hasQueued)
            }
        }
    }

    /// Removes rows from the list (never the one converting), and drops them from the selection.
    private func removeFromList(_ ids: Set<UUID>) {
        for id in ids { c.remove(id) }
        selection.subtract(ids)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ["pbp", "cue", "gdi", "iso", "bin", "chd", "zip", "7z"].compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.message = "Choose .pbp, .cue, .gdi, .iso, .zip or .7z files or folders to compress, or .chd files to extract"
        present(panel) { c.add(panel.urls) }
    }

    /// Shows the panel as a sheet attached to the main window, so it can't get lost behind other windows.
    private func present(_ panel: NSOpenPanel, onOK: @escaping () -> Void) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        if let window {
            panel.beginSheetModal(for: window) { if $0 == .OK { onOK() } }
        } else if panel.runModal() == .OK {
            onOK()
        }
    }

    private func pickOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should the .chd files be saved?"
        present(panel) { c.outputDir = panel.url }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    /// Files dropped on the Dock icon or opened with "Open With → Converterator".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Converter.shared.add(urls) }
    }
}

@main
struct ConverteratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Converterator", id: "main") { ContentView() }
            .defaultSize(width: 640, height: 520)
            .commands { AppCommands() }
    }
}

extension Notification.Name {
    /// Menu commands that need the window: open the file picker, confirm a stop, show the log.
    static let addFiles = Notification.Name("ConverteratorAddFiles")
    static let stopConverting = Notification.Name("ConverteratorStopConverting")
    static let toggleLog = Notification.Name("ConverteratorToggleLog")
}

/// Menu bar items and their keyboard shortcuts.
struct AppCommands: Commands {
    @ObservedObject private var c = Converter.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateChecker.shared.check() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { NotificationCenter.default.post(name: .addFiles, object: nil) }
                .keyboardShortcut("o")
                .disabled(c.isRunning)
        }
        CommandMenu("Convert") {
            Button("Convert") { c.start() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(c.isRunning || !c.toolsReady || !c.hasQueued)
            Button("Stop Converting…") { NotificationCenter.default.post(name: .stopConverting, object: nil) }
                .keyboardShortcut(".")
                .disabled(!c.isRunning)
            Divider()
            Button("Clear Finished") { c.clearFinished() }
                .keyboardShortcut("k")
                .disabled(c.isRunning || c.jobs.isEmpty)
            Button("Retry Failed") { c.retryFailed() }
                .keyboardShortcut("r")
                .disabled(c.isRunning || !c.jobs.contains { $0.state == .failed })
            Button("Clear All") { c.clearAll() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(c.isRunning || c.jobs.isEmpty)
        }
        CommandGroup(after: .toolbar) {
            Button("Show or Hide Log") { NotificationCenter.default.post(name: .toggleLog, object: nil) }
                .keyboardShortcut("l")
        }
    }
}
