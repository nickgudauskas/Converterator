// Converterator's tests. Built and run by tests/test.sh, which makes the sample files first.
// Arguments: <fixtures folder> <scratch folder> [--network] <repo folder>
import AppKit

var failures = 0, passes = 0
func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    if ok { passes += 1; print("  ✓ \(what)") }
    else { failures += 1; print("  ✗ \(what)\(detail().isEmpty ? "" : " — \(detail())")") }
}
func section(_ name: String) { print("\n\(name)") }

let fm = FileManager.default
func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
/// Converterator's temporary folders that exist right now.
func tempFolders() -> Set<String> {
    Set(((try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []).filter {
        ($0.hasPrefix("converterator-") && !$0.hasPrefix("converterator-tests")) || $0.hasPrefix("pbp2chd-")
    })
}
func sha1(_ u: URL) -> String? { RedumpResult.sha1Hex(of: u) { _ in } }
/// A fresh folder with copies of the given fixture files (relative paths keep their subfolders).
func workspace(_ name: String, from fixtures: URL, _ files: [String], into work: URL) -> URL {
    let dir = work.appendingPathComponent(name)
    try? fm.removeItem(at: dir)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for f in files {
        let dest = dir.appendingPathComponent((f as NSString).lastPathComponent)
        try! fm.copyItem(at: fixtures.appendingPathComponent(f), to: dest)
    }
    return dir
}
@MainActor func runBatch(_ urls: [URL]) async -> [Job] {
    let c = Converter.shared
    c.clearAll()
    c.add(urls)
    c.start()
    while c.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
    return c.jobs
}
/// The job whose file path ends with `suffix` ("convert/game.cue", or just "ps2.iso").
func job(_ jobs: [Job], _ suffix: String) -> Job? { jobs.first { $0.url.path.hasSuffix("/" + suffix) } }
@MainActor func tags(_ chd: URL) -> String {
    let p = Process(); p.executableURL = Converter.findTool("chdman"); p.arguments = ["info", "-i", chd.path]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run(); let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
    return out
}

@main struct Tests {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        let F = url(args[1]), W = url(args[2])
        let network = args.contains("--network")
        let repo = url(args.last!)
        try? fm.createDirectory(at: W, withIntermediateDirectories: true)

        let c = Converter.shared
        let db = RedumpDB.shared
        Converter.stallTimeout = 6
        db.autoDownload = false
        db.systems = []
        c.verify = false; c.overwrite = false; c.trashSources = false; c.outputDir = nil; c.makeM3U = true; c.isoMode = .automatic
        db.enabled = false; db.renameToRedump = false
        check(c.chdman != nil, "chdman found")

        // MARK: Names
        section("Disc names")
        let names: [(String, String?, Int?)] = [
            ("Game (USA) (Disc 2)", "Game (USA)", 2), ("Game (Disc 2 of 3)", "Game", 2),
            ("Armored Core - Master of Arena - Disc 2", "Armored Core - Master of Arena", 2),
            ("Final Fantasy VII CD2", "Final Fantasy VII", 2), ("Game_Disc3", "Game", 3),
            ("Discworld (USA)", nil, nil), ("Disc Station", nil, nil),
        ]
        for (n, key, disc) in names {
            let p = DiscName.parse(n)
            check(p?.key == key && p?.disc == disc, "“\(n)”", "got \(p.map { "\($0.key) / \($0.disc)" } ?? "none")")
        }
        check(Converter.safeFileName("A: B / C") == "A - B - C", "Redump names made safe for files")
        check(UpdateChecker.isNewer("1.10.0", than: "1.9.0") && !UpdateChecker.isNewer("1.9.0", than: "1.10.0")
              && UpdateChecker.isNewer("v2.0", than: "1.99.9") && !UpdateChecker.isNewer("1.9", than: "1.9.0"),
              "version comparison (1.10 is newer than 1.9)")

        // MARK: ISO type
        section("ISO: CD or DVD")
        for (n, dvd) in [("psp", true), ("ps2", true), ("ps1", false), ("plain", false), ("big", true)] {
            let (isDVD, why) = Converter.isoLooksLikeDVD(F.appendingPathComponent("\(n).iso"))
            check(isDVD == dvd, "\(n).iso → \(dvd ? "DVD" : "CD")", why)
        }

        // MARK: Converting
        section("Converting")
        c.verify = true
        let conv = workspace("convert", from: F, ["cd/game.cue", "cd/game.bin", "ps2.iso", "plain.iso"], into: W)
        // An existing damaged CHD next to a source: verify must stop chdman and fail it, keeping the file.
        let broken = workspace("broken", from: F, ["cd/game.cue", "cd/game.bin"], into: W)
        try! fm.copyItem(at: F.appendingPathComponent("chd/bad.chd"), to: broken.appendingPathComponent("game.chd"))
        // A cue whose track file is missing
        let missing = W.appendingPathComponent("missing"); try? fm.createDirectory(at: missing, withIntermediateDirectories: true)
        try! "FILE \"gone.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".write(to: missing.appendingPathComponent("gone.cue"), atomically: true, encoding: .utf8)
        var jobs = await runBatch([conv, broken.appendingPathComponent("game.cue"), missing.appendingPathComponent("gone.cue")])
        check(job(jobs, "convert/game.cue")?.state == .done && exists(conv.appendingPathComponent("game.chd")), "CUE → CHD", job(jobs, "convert/game.cue")?.detail ?? "")
        check(job(jobs, "ps2.iso")?.state == .done && tags(conv.appendingPathComponent("ps2.chd")).contains("Tag='DVD '"), "PS2 ISO → DVD CHD")
        check(tags(conv.appendingPathComponent("ps2.chd")).contains("2,048 bytes"), "DVD CHD uses 2048-byte hunks")
        check(tags(conv.appendingPathComponent("plain.chd")).contains("Tag='CHT2'"), "plain ISO → CD CHD")
        check(job(jobs, "convert/game.cue")?.detail.contains("verified") == true, "Verify runs after writing")
        let brokenJob = jobs.first { $0.url.path.contains("/broken/") }
        check(brokenJob?.state == .failed && brokenJob?.detail.contains("stopped responding") == true, "damaged existing CHD stops the watchdog", brokenJob?.detail ?? "")
        check(exists(broken.appendingPathComponent("game.chd")), "damaged CHD that already existed is kept")
        check(job(jobs, "gone.cue")?.detail.contains("Missing track file: gone.bin") == true, "missing track file flagged", job(jobs, "gone.cue")?.detail ?? "")
        c.verify = false

        // MARK: Folder scans and archives
        section("Folder scans and archives")
        let tempBefore = tempFolders()
        let arch = workspace("archives", from: F, ["zip/one.zip", "zip/two.zip", "zip/snes.zip", "chd/game.chd"], into: W)
        c.clearAll(); c.add([arch])
        let found = Set(c.jobs.map(\.url.lastPathComponent))
        check(found == ["one.zip", "two.zip"], "folder scan picks disc zips, skips cartridge zip and .chd", "\(found.sorted())")
        try? fm.removeItem(at: arch.appendingPathComponent("game.chd"))
        jobs = await runBatch([arch.appendingPathComponent("one.zip"), arch.appendingPathComponent("two.zip")])
        check(job(jobs, "one.zip")?.state == .done && exists(arch.appendingPathComponent("game.chd")), "zip with a game in a subfolder")
        check(exists(arch.appendingPathComponent("alpha.chd")) && exists(arch.appendingPathComponent("beta.chd")), "zip with two games")
        let leftovers = tempFolders().subtracting(tempBefore)
        check(leftovers.isEmpty, "temporary files cleaned up", "\(leftovers.sorted())")

        // MARK: Playlists
        section("Playlists")
        let discs = W.appendingPathComponent("discs"); try? fm.createDirectory(at: discs, withIntermediateDirectories: true)
        for n in 1...2 {
            try! fm.copyItem(at: F.appendingPathComponent("cd/game.bin"), to: discs.appendingPathComponent("Game G (Disc \(n)).bin"))
            try! "FILE \"Game G (Disc \(n)).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
                .write(to: discs.appendingPathComponent("Game G (Disc \(n)).cue"), atomically: true, encoding: .utf8)
        }
        _ = await runBatch([discs])
        let m3u = (try? String(contentsOf: discs.appendingPathComponent("Game G.m3u"), encoding: .utf8)) ?? ""
        check(m3u == "Game G (Disc 1).chd\nGame G (Disc 2).chd\n", "batch writes Game G.m3u in disc order", m3u)
        try! "Other.chd\nGame G (Disc 1).chd\n".write(to: discs.appendingPathComponent("Mine.m3u"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: discs.appendingPathComponent("Game G.m3u"))
        check(Playlist.make(in: discs).isEmpty, "a playlist someone else wrote is left alone")

        // MARK: Extracting
        section("Extracting CHDs")
        let ext = workspace("extract", from: F, ["chd/game.chd", "chd/ps2.chd"], into: W)
        jobs = await runBatch([ext.appendingPathComponent("game.chd"), ext.appendingPathComponent("ps2.chd")])
        check(sha1(ext.appendingPathComponent("game.bin")) == sha1(F.appendingPathComponent("cd/game.bin")), "CD CHD → identical BIN/CUE")
        check(sha1(ext.appendingPathComponent("ps2.iso")) == sha1(F.appendingPathComponent("ps2.iso")), "DVD CHD → identical ISO")

        // MARK: Redump while converting
        section("Redump while converting")
        db.add([F.appendingPathComponent("redump.zip")])
        while db.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
        check(db.index.gameCount == 7, "DAT read from a .zip", "\(db.index.gameCount) games")
        db.enabled = true; db.renameToRedump = true; db.keepUnmatched = true
        let rd = workspace("redump", from: F, ["cd/game.cue", "cd/game.bin", "ps2.iso", "plain.iso",
                                               "two/Two.cue", "two/Two (Track 1).bin", "two/Two (Track 2).bin"], into: W)
        c.trashSources = false
        jobs = await runBatch([rd])
        check(job(jobs, "game.cue")?.detail.contains("✓ Redump") == true && exists(rd.appendingPathComponent("Good Game (USA).chd")),
              "match, and the CHD is named after Redump", job(jobs, "game.cue")?.detail ?? "")
        check(job(jobs, "ps2.iso")?.detail.contains("✓ Redump") == true, "ISO match")
        check(job(jobs, "Two.cue")?.detail.contains("partial") == true, "partial match", job(jobs, "Two.cue")?.detail ?? "")
        check(job(jobs, "plain.iso")?.detail.contains("not in Redump") == true, "no match")
        check(RedumpCache.lookup(rd.appendingPathComponent("Good Game (USA).chd"))?.isMatch == true, "new CHD's result is remembered")
        let log = ConversionLog.load()[rd.appendingPathComponent("game.cue").standardizedFileURL.path] ?? []
        check(log.first?.hasSuffix("Good Game (USA).chd") == true, "conversion record points at the renamed CHD")
        // Trash on + unmatched: originals must stay (nothing here may reach the real Trash)
        let keep = workspace("keep", from: F, ["plain.iso"], into: W)
        c.trashSources = true
        jobs = await runBatch([keep.appendingPathComponent("plain.iso")])
        c.trashSources = false
        check(exists(keep.appendingPathComponent("plain.iso")) && job(jobs, "plain.iso")?.detail.contains("originals kept") == true,
              "unmatched originals kept with Trash on")
        db.renameToRedump = false

        // MARK: Checking CHDs
        section("Checking CHDs against Redump")
        let ck = workspace("check", from: F, ["chd/game.chd", "chd/ps2.chd", "chd/two.chd", "chd/gd.chd", "chd/bad.chd"], into: W)
        try! "game.chd\nother.chd\n".write(to: ck.appendingPathComponent("set.m3u"), atomically: true, encoding: .utf8)
        let k = CHDCheck.shared
        k.clear(); k.recheck = false
        k.add([ck])
        k.start(); while k.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        func item(_ n: String) -> CHDCheck.Item? { k.items.first { $0.url.lastPathComponent == n } }
        func why(_ n: String) -> String { item(n).map { "\($0.state): \($0.result?.long ?? $0.error ?? "no result")" } ?? "missing" }
        check(item("game.chd")?.result?.isMatch == true, "CD CHD matches", why("game.chd"))
        check(item("ps2.chd")?.result?.isMatch == true, "DVD CHD matches", why("ps2.chd"))
        check(item("gd.chd")?.result?.isMatch == true, "Dreamcast GD-ROM CHD matches (Redump layout, gaps included)", item("gd.chd")?.result?.long ?? item("gd.chd")?.error ?? "")
        if case .partial(_, 1, 2) = item("two.chd")?.result { check(true, "partial match reported") } else { check(false, "partial match reported", item("two.chd")?.result?.long ?? "") }
        check(item("bad.chd")?.state == .failed, "damaged CHD fails", item("bad.chd")?.error ?? "")
        // Second run: unchanged CHDs come from memory
        k.clear(); k.add([ck]); k.start(); while k.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        check(item("game.chd")?.remembered == true && item("gd.chd")?.remembered == true, "unchanged CHDs aren't unpacked again",
              "game: \(why("game.chd")), remembered \(item("game.chd")?.remembered ?? false); gd remembered \(item("gd.chd")?.remembered ?? false)")
        check(item("bad.chd")?.remembered == false, "failed checks aren't remembered")
        k.renameMatches()
        check(exists(ck.appendingPathComponent("Good Game (USA).chd")) && exists(ck.appendingPathComponent("GD Game (USA).chd")), "matches renamed")
        let set = (try? String(contentsOf: ck.appendingPathComponent("set.m3u"), encoding: .utf8)) ?? ""
        check(set.hasPrefix("Good Game (USA).chd\n"), "playlist updated after rename", set)
        check(RedumpCache.lookup(ck.appendingPathComponent("Good Game (USA).chd"))?.isMatch == true, "remembered result follows the rename")

        // MARK: Cleanup and library report
        section("Clean Up Originals and Library Report")
        let lib = W.appendingPathComponent("library"); try? fm.createDirectory(at: lib, withIntermediateDirectories: true)
        let chd = F.appendingPathComponent("chd/game.chd")
        for n in ["Solo.chd", "Game A (Disc 1).chd", "Game A (Disc 2).chd", "Game B (Disc 1 of 3).chd", "Game B (Disc 3 of 3).chd",
                  "Game D (USA) (Disc 1).chd", "Game D (USA) (Disc 2).chd"] {
            try! fm.copyItem(at: chd, to: lib.appendingPathComponent(n))
        }
        try! fm.copyItem(at: F.appendingPathComponent("cd/game.bin"), to: lib.appendingPathComponent("Solo.bin"))
        try! "FILE \"Solo.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n".write(to: lib.appendingPathComponent("Solo.cue"), atomically: true, encoding: .utf8)
        try! fm.copyItem(at: F.appendingPathComponent("plain.iso"), to: lib.appendingPathComponent("New.iso"))
        RedumpCache.store(lib.appendingPathComponent("Solo.chd"), .match("Solo"))
        let r = LibraryReport.build(folder: lib, outputDir: nil, sevenZip: nil, log: ConversionLog.load(),
                                    redump: db.index, checked: RedumpCache.all()) { _ in }
        check(r.unconverted.map(\.lastPathComponent) == ["New.iso"], "not converted yet", "\(r.unconverted.map(\.lastPathComponent))")
        check(r.leftovers.map(\.source.lastPathComponent) == ["Solo.cue"] && r.leftovers.first?.files.count == 2, "original with a CHD (cue + bin)")
        let gaps = Dictionary(uniqueKeysWithValues: r.missingDiscs.map { ($0.name, $0.missing) })
        check(gaps["Game B"] == [2], "missing disc from “Disc 1 of 3” / “3 of 3”", "\(gaps)")
        check(gaps["Game D (USA)"] == [3], "missing disc from Redump's disc count", "\(gaps)")
        check(Set(r.needsPlaylist.map(\.name)) == ["Game A", "Game B", "Game D (USA)"], "sets without playlists", "\(r.needsPlaylist.map(\.name))")
        check(r.redumpMatched == 1 && r.redumpUnchecked.count == 6, "Redump counts from remembered results", "\(r.redumpMatched) / \(r.redumpUnchecked.count)")
        // Ambiguous: two originals pointing at one CHD in a shared folder are left out of cleanup
        let shared = W.appendingPathComponent("shared"); let a1 = W.appendingPathComponent("amb1"), a2 = W.appendingPathComponent("amb2")
        for d in [shared, a1, a2] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try! fm.copyItem(at: chd, to: shared.appendingPathComponent("game.chd"))
        for d in [a1, a2] { for f in ["game.cue", "game.bin"] { try! fm.copyItem(at: F.appendingPathComponent("cd/\(f)"), to: d.appendingPathComponent(f)) } }
        let amb = Cleanup.findConverted(in: W, outputDir: shared, sevenZip: nil)
        let (clear, skipped) = Cleanup.unambiguous(amb.filter { $0.source.path.contains("/amb") })
        check(clear.isEmpty && skipped == 2, "files sharing one CHD name are left out of cleanup")

        // MARK: Patches
        section("Patches")
        @MainActor func chdBin(_ chd: URL) -> String? {
            let out = W.appendingPathComponent("unpacked-\(UUID().uuidString)")
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let p = Process(); p.executableURL = c.chdman
            p.arguments = ["extractcd", "-i", chd.path, "-o", out.appendingPathComponent("x.cue").path, "-sb"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            let bins = ((try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return bins.compactMap(sha1).joined(separator: ",")
        }
        let wantPatched = sha1(F.appendingPathComponent("patch/target.bin"))
        check(Converter.findTool("xdelta3") != nil, "xdelta3 found")
        for (patchName, chdName) in [("Base (English).xdelta", "Base (English).chd"), ("Base (IPS).ips", "Base (IPS).chd"),
                                     ("Base (BPS).bps", "Base (BPS).chd"), ("Base (PPF).ppf", "Base (PPF).chd")] {
            let ws = workspace("patch-\(PatchFormat.of(url(patchName))!.rawValue)", from: F, ["patch/Base.cue", "patch/Base.bin", "patch/\(patchName)"], into: W)
            c.clearAll(); c.add([ws.appendingPathComponent("Base.cue")])
            if let id = c.jobs.first?.id { c.setPatch(ws.appendingPathComponent(patchName), for: id) }
            c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            let chd = ws.appendingPathComponent(chdName)
            check(c.jobs.first?.state == .done && exists(chd) && chdBin(chd) == wantPatched,
                  "\(PatchFormat.of(url(patchName))!.rawValue) patch applied, CHD named after it", c.jobs.first?.detail ?? "")
            check(!exists(ws.appendingPathComponent("Base.chd")) && sha1(ws.appendingPathComponent("Base.bin")) == sha1(F.appendingPathComponent("patch/Base.bin")),
                  "\(PatchFormat.of(url(patchName))!.rawValue): original untouched, no unpatched CHD")
        }
        // Wrong game: the patch must refuse, not produce garbage
        let wrong = workspace("patch-wrong", from: F, ["cd/game.cue", "plain.iso"], into: W)
        try! fm.copyItem(at: F.appendingPathComponent("two/Two (Track 1).bin"), to: wrong.appendingPathComponent("game.bin"))
        for p in ["Base (English).xdelta", "Base (BPS).bps", "Base (PPF).ppf"] {
            try? fm.copyItem(at: F.appendingPathComponent("patch/\(p)"), to: wrong.appendingPathComponent(p))
            c.clearAll(); c.add([wrong.appendingPathComponent("game.cue")])
            if let id = c.jobs.first?.id { c.setPatch(wrong.appendingPathComponent(p), for: id) }
            c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            check(c.jobs.first?.state == .failed && c.jobs.first?.detail.contains("doesn't fit") == true,
                  "\(PatchFormat.of(url(p))!.rawValue) patch for a different game is refused", c.jobs.first?.detail ?? "")
        }
        // Multi-track: the xdelta patch for track 2 is found and applied to track 2 only
        let mt = workspace("patch-two", from: F, ["two/Two.cue", "two/Two (Track 1).bin", "two/Two (Track 2).bin", "patch/Two (Fixed).xdelta"], into: W)
        try! fm.moveItem(at: mt.appendingPathComponent("Two (Fixed).xdelta"), to: mt.appendingPathComponent("Two.xdelta"))
        c.clearAll(); c.add([mt.appendingPathComponent("Two.cue")])
        check(c.jobs.first?.patch?.lastPathComponent == "Two.xdelta", "a patch next to the game with the same name is picked up")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        let wantTwo = [F.appendingPathComponent("two/Two (Track 1).bin"), F.appendingPathComponent("patch/two-track2-target.bin")].compactMap(sha1).joined(separator: ",")
        check(chdBin(mt.appendingPathComponent("Two.chd")) == wantTwo, "multi-track: only the track the patch was made for is changed",
              c.jobs.first?.detail ?? "")
        // Dropped together with its game
        let dz = workspace("patch-drop", from: F, ["patch/Base.cue", "patch/Base.bin", "patch/Base (BPS).bps"], into: W)
        c.clearAll(); c.add([dz.appendingPathComponent("Base.cue"), dz.appendingPathComponent("Base (BPS).bps")])
        check(c.jobs.count == 1 && c.jobs.first?.patch?.lastPathComponent == "Base (BPS).bps", "a patch dropped with its game goes with it")
        c.clearAll()

        // MARK: Pause and the saved queue
        section("Pause, Resume and the saved queue")
        let pz = W.appendingPathComponent("pause"); try? fm.createDirectory(at: pz, withIntermediateDirectories: true)
        for n in 1...3 {
            try! fm.copyItem(at: F.appendingPathComponent("cd/game.bin"), to: pz.appendingPathComponent("p\(n).bin"))
            try! "FILE \"p\(n).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
                .write(to: pz.appendingPathComponent("p\(n).cue"), atomically: true, encoding: .utf8)
        }
        c.clearAll(); c.add([pz]); c.start()
        while !c.jobs.contains(where: { $0.state == .working }) { try? await Task.sleep(for: .milliseconds(10)) }
        c.pause()
        while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(c.isPaused && c.batchDoneCount == 1 && c.batchQueuedCount == 2, "Pause stops after the current file",
              "paused \(c.isPaused), done \(c.batchDoneCount), waiting \(c.batchQueuedCount)")
        let saved = Converter.loadQueue(from: Converter.queueFile)
        check(saved.count == 3 && saved.filter { $0.state == .queued }.count == 2, "the list is saved as it changes")
        c.start()
        while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(!c.isPaused && c.batchDoneCount == 3 && c.batchJobs.count == 3, "Resume finishes the same batch")

        let slow = workspace("slow", from: F, ["slow/slow.cue", "slow/slow.bin"], into: W)
        c.clearAll(); c.add([slow.appendingPathComponent("slow.cue")]); c.start()
        while c.jobs.first?.progress ?? 0 < 0.01 && c.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        c.pause(now: true)
        while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(c.isPaused && c.jobs.first?.state == .queued && !exists(slow.appendingPathComponent("slow.chd")),
              "Pause Now puts the file back and deletes its unfinished CHD", c.jobs.first?.detail ?? "")
        c.cancel()
        check(!c.isPaused && c.batchEnd != nil, "Cancel ends a paused batch")

        // A list saved while a file was converting comes back with that file waiting again.
        let qf = W.appendingPathComponent("queue-test.json")
        let fake = [Converter.SavedJob(path: "/a.cue", state: "done", detail: "a.chd", weight: 1, bytesIn: 0, bytesOut: 0, outputs: []),
                    Converter.SavedJob(path: "/b.cue", state: "working", detail: "Compressing — 40%", weight: 1, bytesIn: 0, bytesOut: 0, outputs: [])]
        try! JSONEncoder().encode(fake).write(to: qf)
        let back = Converter.loadQueue(from: qf)
        check(back.map(\.state) == [.done, .queued] && back[1].detail.contains("interrupted"), "an interrupted file is waiting again after a restart")

        // A file that's gone (drive unplugged) fails with a clear message
        let gone = W.appendingPathComponent("gone/away.iso")
        c.clearAll(); c.jobs = [Job(url: gone)]; c.start()
        while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(c.jobs.first?.detail.contains("Can't find the file") == true, "missing file says to connect the drive", c.jobs.first?.detail ?? "")

        // MARK: Free space
        section("Free space")
        check(Converter.logicalSize("Logical size: 1,411,200 bytes") == 1_411_200, "reads chdman's logical size")
        DiskSpace.override = { _ in 1_000_000 }   // pretend every disk has 1 MB free
        let full = workspace("full", from: F, ["cd/game.cue", "cd/game.bin"], into: W)
        c.clearAll(); c.add([full.appendingPathComponent("game.cue")])
        check(c.batchSpaceWarning()?.contains("may need up to") == true, "warns before starting a batch that may not fit")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(c.jobs.first?.state == .failed && c.jobs.first?.detail.contains("Not enough free space") == true,
              "a file that won't fit fails before starting", c.jobs.first?.detail ?? "")
        check(!exists(full.appendingPathComponent("game.chd")), "nothing written")
        let tight = await CHDCheck.check(F.appendingPathComponent("chd/game.chd"), chdman: c.chdman!, index: db.index,
                                         started: { _ in }, progress: { _ in })
        if case .failure(let e) = tight { check(e.message.contains("to unpack it"), "CHD check warns when there's no room to unpack") }
        else { check(false, "CHD check warns when there's no room to unpack") }
        DiskSpace.override = nil
        check(c.batchSpaceWarning() == nil, "no warning when there's room")
        c.clearAll()

        // MARK: Updater
        section("Updater checks")
        let zip = repo.appendingPathComponent("dist/Converterator.zip")
        let installed = url("/Applications/Converterator.app")
        if exists(zip), exists(installed), let team = UpdateChecker.teamID(ofCodeAt: installed) {
            check(UpdateChecker.validSignature(installed, teamID: team) && !UpdateChecker.validSignature(installed, teamID: "ABCDE12345"),
                  "signature check accepts the right team only")
            let target = W.appendingPathComponent("upd/Converterator.app")
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: installed, to: target)
            let version = { (NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "?" }
            let before = version()
            // The version inside the zip, from its Info.plist
            let unzip = Process(); unzip.executableURL = url("/usr/bin/unzip")
            unzip.arguments = ["-p", zip.path, "Converterator.app/Contents/Info.plist"]
            let pipe = Pipe(); unzip.standardOutput = pipe; try? unzip.run()
            let plist = pipe.fileHandleForReading.readDataToEndOfFile(); unzip.waitUntilExit()
            let zipVersion = ((try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any])?["CFBundleShortVersionString"] as? String ?? "?"
            do { try UpdateChecker.installUpdate(zip: zip, expectedVersion: "0.0.1", teamID: team, replacing: target); check(false, "wrong version refused") }
            catch { check(version() == before, "wrong version refused, app untouched") }
            do { try UpdateChecker.installUpdate(zip: zip, expectedVersion: zipVersion, teamID: team, replacing: target)
                 check(version() == zipVersion, "signed release installs over a copy", "now \(version())") }
            catch { check(false, "signed release installs over a copy", error.localizedDescription) }
        } else {
            print("  – skipped (needs dist/Converterator.zip from notarize.sh and a signed app in /Applications)")
        }

        // MARK: Network
        if network {
            section("redump.org download")
            do {
                let name = try await RedumpDB.fetch(slug: "psx", haveName: nil, haveFile: false)
                let idx = RedumpDB.load(RedumpDB.storedDAT("psx"))
                check((idx?.gameCount ?? 0) > 1000, "PlayStation DAT downloaded and read", "\(name ?? "nil"), \(idx?.gameCount ?? 0) games")
                let again = try await RedumpDB.fetch(slug: "psx", haveName: name, haveFile: true)
                check(again == nil, "not downloaded again when unchanged")
            } catch { check(false, "download from redump.org", "\(error)") }
        }

        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
