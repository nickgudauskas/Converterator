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
        // Export
        let csv = r.csv()
        check(csv.hasPrefix("Section,Name,Folder,Details,Size (bytes)\n") && csv.contains("Not converted yet,New.iso,")
              && csv.contains("Missing discs,Game B,") && csv.contains("\"has 1, 3; missing 2\""), "report exports as CSV (with quoting)")
        let txt = r.text(folder: lib)
        check(txt.contains("Not converted yet: 1") && txt.contains("Game B: has disc 1, 3; missing 2"), "report exports as text")
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
        let patchNames: [(game: String, patch: String, redump: String?, want: String)] = [
            ("Racing Lagoon (Japan).cue", "racinglagoonenglish.xdelta", nil, "Racing Lagoon (English)"),
            ("racinglagoon.cue", "racinglagoonenglish.xdelta", "Racing Lagoon (Japan)", "Racing Lagoon (English)"),
            ("Game (Japan) (Disc 1).cue", "game_t-es_v1.0.ppf", nil, "Game (Spanish)"),
            ("Game (Japan).cue", "GAME-PTBR.xdelta", nil, "Game (Portuguese)"),
            ("Game (Japan).cue", "game-undub.xdelta", nil, "Game (Undub)"),
            ("Game (Japan).cue", "fix.ips", nil, "Game (Patched)"),
            ("Game (Japan).cue", "Tengai Makyou Zero (English) v1.1.xdelta", nil, "Tengai Makyou Zero (English) v1.1"),
        ]
        for n in patchNames {
            let got = Patcher.patchedName(game: url("/x/\(n.game)"), patch: url("/x/\(n.patch)"), redumpGame: n.redump)
            check(got == n.want, "“\(n.patch)” on “\(n.redump ?? n.game)” → “\(n.want)”", "got “\(got)”")
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
        check(chdBin(mt.appendingPathComponent("Two (Patched).chd")) == wantTwo, "multi-track: only the track the patch was made for is changed",
              c.jobs.first?.detail ?? "")
        // MARK: Zipped patches and the patches folder
        // (Redump off here: the sample disc matches “Good Game” in the test DAT, which would name the CHDs.)
        db.enabled = false
        @MainActor func zip(_ dir: URL, _ name: String, _ files: [(from: URL, as: String)]) -> URL {
            let stage = W.appendingPathComponent("zipstage-\(UUID().uuidString)")
            try? fm.createDirectory(at: stage, withIntermediateDirectories: true)
            for f in files { try! fm.copyItem(at: f.from, to: stage.appendingPathComponent(f.as)) }
            try! "Apply with Delta Patcher.".write(to: stage.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
            let out = dir.appendingPathComponent(name)
            let p = Process(); p.executableURL = url("/usr/bin/zip"); p.currentDirectoryURL = stage
            p.arguments = ["-q", "-r", out.path, "."]; try? p.run(); p.waitUntilExit()
            return out
        }
        func waitForLookup() async { while PatchLibrary.shared.isLooking { try? await Task.sleep(for: .milliseconds(50)) } }
        let px = F.appendingPathComponent("patch")
        check(Patcher.patchedName(game: url("/x/Racing Lagoon (Japan).cue"), patch: url("/x/patch.xdelta"), alsoLookIn: "racinglagoon-english")
              == "Racing Lagoon (English)", "a patch called “patch” takes its language from the zip’s name")

        // A zip with a patch for another game and the right one: the right one is used
        let zp = workspace("patch-zip", from: F, ["patch/Base.cue", "patch/Base.bin"], into: W)
        let bundle = zip(zp, "Base English v1.zip", [(px.appendingPathComponent("Two (Fixed).xdelta"), "patch-other-game.xdelta"),
                                                     (px.appendingPathComponent("Base (English).xdelta"), "Base (English).xdelta")])
        check(Patcher.isPatchZip(bundle), "a zip of patches is recognised as a patch")
        c.clearAll(); c.add([zp.appendingPathComponent("Base.cue"), bundle])
        check(c.jobs.count == 1 && c.jobs.first?.patch == bundle, "a patch zip dropped with its game goes with it (not converted as a game)")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(zp.appendingPathComponent("Base (English).chd")) == wantPatched, "the patch in the zip that fits is applied", c.jobs.first?.detail ?? "")
        // A patch zip next to the game with the same name is picked up
        let zn = workspace("patch-zip-next", from: F, ["patch/Base.cue", "patch/Base.bin"], into: W)
        _ = zip(zn, "Base.zip", [(px.appendingPathComponent("Base (BPS).bps"), "Base (BPS).bps")])
        c.clearAll(); c.add([zn.appendingPathComponent("Base.cue")])
        check(c.jobs.first?.patch?.lastPathComponent == "Base.zip", "a patch zip next to the game is picked up")

        // Patches folder
        let plib = PatchLibrary.shared
        let pf = W.appendingPathComponent("patches-folder"); try? fm.createDirectory(at: pf, withIntermediateDirectories: true)
        try! fm.copyItem(at: px.appendingPathComponent("Base (BPS).bps"), to: pf.appendingPathComponent("some unrelated name.bps"))
        try! fm.copyItem(at: px.appendingPathComponent("Base (English).xdelta"), to: pf.appendingPathComponent("racingbaseenglish.xdelta"))
        try! fm.copyItem(at: px.appendingPathComponent("Base (English).xdelta"), to: pf.appendingPathComponent("racingbasespanish.xdelta"))
        plib.enabled = true
        plib.folder = pf
        let bf = workspace("folder-bps", from: F, ["patch/Base.cue", "patch/Base.bin"], into: W)
        c.clearAll(); c.add([bf.appendingPathComponent("Base.cue")]); await waitForLookup()
        check(c.jobs.first?.patch?.lastPathComponent == "some unrelated name.bps" && c.jobs.first?.patchFromFolder == true,
              "patches folder: BPS found by checksum, whatever its name", "\(c.jobs.first?.patch?.lastPathComponent ?? "none")")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(bf.appendingPathComponent("Base (Patched).chd")) == wantPatched, "…and applied", c.jobs.first?.detail ?? "")
        // xdelta by name: the game "Racing Base (Japan)"; English preferred over Spanish
        let nf = W.appendingPathComponent("folder-name"); try? fm.createDirectory(at: nf, withIntermediateDirectories: true)
        try! fm.copyItem(at: px.appendingPathComponent("Base.bin"), to: nf.appendingPathComponent("Racing Base (Japan).bin"))
        try! "FILE \"Racing Base (Japan).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
            .write(to: nf.appendingPathComponent("Racing Base (Japan).cue"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: pf.appendingPathComponent("some unrelated name.bps"))   // so only the name can match
        c.clearAll(); c.add([nf.appendingPathComponent("Racing Base (Japan).cue")]); await waitForLookup()
        check(c.jobs.first?.patch?.lastPathComponent == "racingbaseenglish.xdelta", "patches folder: xdelta found by the game's name, in your language",
              "\(c.jobs.first?.patch?.lastPathComponent ?? "none") (preferred: \(PatchLibrary.preferredLanguage ?? "?"))")
        check(c.jobs.first?.patchedName == "Racing Base (English)", "…and the list shows “Racing Base (English).chd”")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(nf.appendingPathComponent("Racing Base (English).chd")) == wantPatched, "…and applied", c.jobs.first?.detail ?? "")
        // A name match that doesn't fit: converted without the patch
        let nm = W.appendingPathComponent("folder-nofit"); try? fm.createDirectory(at: nm, withIntermediateDirectories: true)
        try! fm.copyItem(at: F.appendingPathComponent("two/Two (Track 1).bin"), to: nm.appendingPathComponent("Racing Base (Japan).bin"))
        try! fm.copyItem(at: nf.appendingPathComponent("Racing Base (Japan).cue"), to: nm.appendingPathComponent("Racing Base (Japan).cue"))
        c.clearAll(); c.add([nm.appendingPathComponent("Racing Base (Japan).cue")]); await waitForLookup()
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(c.jobs.first?.state == .done && exists(nm.appendingPathComponent("Racing Base (Japan).chd"))
              && c.jobs.first?.detail.contains("didn't fit") == true, "a folder patch that doesn't fit: converted without it", c.jobs.first?.detail ?? "")
        // PPF inside a zip in the folder, found by checksum
        let pf2 = W.appendingPathComponent("patches-folder-2"); try? fm.createDirectory(at: pf2, withIntermediateDirectories: true)
        _ = zip(pf2, "stuff.zip", [(px.appendingPathComponent("Base (PPF).ppf"), "random.ppf")])
        plib.folder = pf2
        let ppfGame = workspace("folder-ppf", from: F, ["patch/Base.cue", "patch/Base.bin"], into: W)
        c.clearAll(); c.add([ppfGame.appendingPathComponent("Base.cue")]); await waitForLookup()
        check(c.jobs.first?.patch?.lastPathComponent == "stuff.zip" && c.jobs.first?.patchMember == "random.ppf",
              "patches folder: PPF inside a zip found by checksum")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(ppfGame.appendingPathComponent("Base (Patched).chd")) == wantPatched, "…and applied", c.jobs.first?.detail ?? "")
        plib.folder = nil
        c.clearAll()

        // MARK: Stacked patches, patching a CHD, and patches in the Library Report
        // Translation, then a fix on top
        let st = workspace("stack", from: F, ["patch/Base.cue", "patch/Base.bin", "patch/Base (English).xdelta", "patch/bugfix.ips"], into: W)
        c.clearAll(); c.add([st.appendingPathComponent("Base.cue")])
        if let id = c.jobs.first?.id {
            c.setPatch(st.appendingPathComponent("Base (English).xdelta"), for: id)
            c.addPatch(st.appendingPathComponent("bugfix.ips"), for: id)
        }
        check(c.jobs.first?.morePatches.map(\.lastPathComponent) == ["bugfix.ips"], "a second patch is added after the first")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(st.appendingPathComponent("Base (English).chd")) == sha1(F.appendingPathComponent("patch/target2.bin")),
              "stacked: translation then fix, named after the first", c.jobs.first?.detail ?? "")
        check(sha1(st.appendingPathComponent("Base.bin")) == sha1(F.appendingPathComponent("patch/Base.bin")), "stacked: original untouched")
        // Two tracks: xdelta changes track 2, then an IPS changes track 1 (a linked original: must be copied, not written through)
        let st2 = workspace("stack-two", from: F, ["two/Two.cue", "two/Two (Track 1).bin", "two/Two (Track 2).bin",
                                                   "patch/Two (Fixed).xdelta", "patch/track1fix.ips"], into: W)
        c.clearAll(); c.add([st2.appendingPathComponent("Two.cue")])
        if let id = c.jobs.first?.id {
            c.setPatch(st2.appendingPathComponent("Two (Fixed).xdelta"), for: id)
            c.addPatch(st2.appendingPathComponent("track1fix.ips"), for: id)
        }
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        let wantBoth = [F.appendingPathComponent("patch/two-track1-target.bin"), F.appendingPathComponent("patch/two-track2-target.bin")]
            .compactMap(sha1).joined(separator: ",")
        check(chdBin(st2.appendingPathComponent("Two (Fixed).chd")) == wantBoth, "stacked on two tracks: each patch changes its own track",
              c.jobs.first?.detail ?? "")
        check(sha1(st2.appendingPathComponent("Two (Track 1).bin")) == sha1(F.appendingPathComponent("two/Two (Track 1).bin"))
              && sha1(st2.appendingPathComponent("Two (Track 2).bin")) == sha1(F.appendingPathComponent("two/Two (Track 2).bin")),
              "stacked on two tracks: the original tracks are untouched")

        // Patching a CHD you already have
        let pc = W.appendingPathComponent("patch-chd"); try? fm.createDirectory(at: pc, withIntermediateDirectories: true)
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: pc.appendingPathComponent("Base (Japan).chd"))   // game.bin = Base.bin
        try! fm.copyItem(at: px.appendingPathComponent("Base (English).xdelta"), to: pc.appendingPathComponent("Base (English).xdelta"))
        let chdBefore = sha1(pc.appendingPathComponent("Base (Japan).chd"))
        c.clearAll(); c.add([pc.appendingPathComponent("Base (Japan).chd")])
        check(c.jobs.first?.isExtraction == true && c.jobs.first?.patch == nil, "a CHD on its own is still extracted (no patch picked up)")
        if let id = c.jobs.first?.id { c.setPatch(pc.appendingPathComponent("Base (English).xdelta"), for: id) }
        check(c.jobs.first?.isExtraction == false, "…with a patch, it's patched instead")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(pc.appendingPathComponent("Base (English).chd")) == wantPatched, "a CHD is unpacked, patched and compressed again",
              c.jobs.first?.detail ?? "")
        check(sha1(pc.appendingPathComponent("Base (Japan).chd")) == chdBefore, "…and the original CHD is untouched")

        // Library Report: patches available
        let rl = W.appendingPathComponent("report-patches"); try? fm.createDirectory(at: rl, withIntermediateDirectories: true)
        try! fm.copyItem(at: px.appendingPathComponent("Base.bin"), to: rl.appendingPathComponent("Racing Base (Japan).bin"))
        try! "FILE \"Racing Base (Japan).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
            .write(to: rl.appendingPathComponent("Racing Base (Japan).cue"), atomically: true, encoding: .utf8)
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: rl.appendingPathComponent("Speed Base (Japan).chd"))
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: rl.appendingPathComponent("Done Base (Japan).chd"))
        try! fm.copyItem(at: F.appendingPathComponent("chd/game.chd"), to: rl.appendingPathComponent("Done Base (English).chd"))
        let rp = W.appendingPathComponent("report-patches-folder"); try? fm.createDirectory(at: rp, withIntermediateDirectories: true)
        for n in ["racingbaseenglish", "speedbaseenglish", "donebaseenglish"] {
            try! fm.copyItem(at: px.appendingPathComponent("Base (English).xdelta"), to: rp.appendingPathComponent("\(n).xdelta"))
        }
        let offers = LibraryReport.patchOffers(patchesFolder: rp, prefer: "English", outputDir: nil,
                                               unconverted: [rl.appendingPathComponent("Racing Base (Japan).cue")], leftovers: [],
                                               chds: ["Speed Base (Japan).chd", "Done Base (Japan).chd", "Done Base (English).chd"].map { rl.appendingPathComponent($0) })
        check(offers.map(\.name) == ["Racing Base (English)", "Speed Base (English)"],
              "report offers patches for a game and a CHD, not for ones already patched", "\(offers.map(\.name))")
        // What “Convert Patched Versions” does
        c.clearAll()
        for o in offers {
            c.add([o.game])
            if let job = c.jobs.last(where: { $0.url.standardizedFileURL == o.game.standardizedFileURL }) { c.setPatch(o.patch.url, member: o.patch.member, for: job.id) }
        }
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(chdBin(rl.appendingPathComponent("Racing Base (English).chd")) == wantPatched
              && chdBin(rl.appendingPathComponent("Speed Base (English).chd")) == wantPatched, "Convert Patched Versions makes both",
              c.jobs.map(\.detail).joined(separator: " | "))
        c.clearAll()

        // Dropped together with its game
        let dz = workspace("patch-drop", from: F, ["patch/Base.cue", "patch/Base.bin", "patch/Base (BPS).bps"], into: W)
        c.clearAll(); c.add([dz.appendingPathComponent("Base.cue"), dz.appendingPathComponent("Base (BPS).bps")])
        check(c.jobs.count == 1 && c.jobs.first?.patch?.lastPathComponent == "Base (BPS).bps", "a patch dropped with its game goes with it")
        c.clearAll()

        // MARK: Making PBPs
        section("Making PBPs (PSP / PS Vita)")
        @MainActor func pbpBins(_ pbp: URL) -> [String] {
            let out = W.appendingPathComponent("pbp-out-\(UUID().uuidString)")
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            let p = Process(); p.executableURL = c.psxpackager
            p.arguments = ["-i", pbp.path, "-o", out.path, "-x", "-v", "1"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            return ((try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "bin" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .compactMap(sha1)
        }
        check(c.psxpackager != nil, "PSXPackager found")
        c.outputFormat = .pbp
        let d1 = sha1(F.appendingPathComponent("ps1/PS1 Game (Disc 1).bin")), d2 = sha1(F.appendingPathComponent("ps1/PS1 Game (Disc 2).bin"))
        // One disc
        let pb1 = workspace("pbp-single", from: F, ["ps1/PS1 Game (Disc 1).cue", "ps1/PS1 Game (Disc 1).bin"], into: W)
        jobs = await runBatch([pb1])
        check(pbpBins(pb1.appendingPathComponent("PS1 Game (Disc 1).pbp")) == [d1].compactMap { $0 }, "a disc becomes a PBP with the same data",
              jobs.first?.detail ?? "")
        // Two discs, one PBP
        let pb2 = workspace("pbp-multi", from: F, ["ps1/PS1 Game (Disc 1).cue", "ps1/PS1 Game (Disc 1).bin",
                                                   "ps1/PS1 Game (Disc 2).cue", "ps1/PS1 Game (Disc 2).bin"], into: W)
        jobs = await runBatch([pb2])
        check(pbpBins(pb2.appendingPathComponent("PS1 Game.pbp")) == [d1, d2].compactMap { $0 }, "two discs of a game go into one PBP",
              jobs.map(\.detail).joined(separator: " | "))
        check(jobs.allSatisfy { $0.state == .done } && jobs.contains { $0.detail.contains("with the other discs") }, "…and both are marked done")
        // Patched
        let pb3 = workspace("pbp-patched", from: F, ["ps1/PS1 Game (Disc 1).cue", "ps1/PS1 Game (Disc 1).bin", "ps1/psgameenglish.xdelta"], into: W)
        c.clearAll(); c.add([pb3.appendingPathComponent("PS1 Game (Disc 1).cue")])
        if let id = c.jobs.first?.id { c.setPatch(pb3.appendingPathComponent("psgameenglish.xdelta"), for: id) }
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(pbpBins(pb3.appendingPathComponent("PS1 Game (English).pbp")) == [sha1(F.appendingPathComponent("ps1/patched-disc1.bin"))].compactMap { $0 },
              "a patched game becomes a patched PBP, named “PS1 Game (English)”", c.jobs.first?.detail ?? "")
        check(sha1(pb3.appendingPathComponent("PS1 Game (Disc 1).bin")) == d1, "…and the original is untouched")
        // From a CHD, into a PSP folder
        c.pbpFolders = true
        let pb4 = workspace("pbp-chd", from: F, ["ps1/PS1 Game (Disc 1).chd"], into: W)
        c.clearAll(); c.add([pb4])   // a folder scan picks up CHDs when making PBPs
        check(c.jobs.count == 1, "making PBPs, a folder scan picks up CHDs")
        c.start(); while c.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(pbpBins(pb4.appendingPathComponent("PS1 Game (Disc 1)/EBOOT.pbp")) == [d1].compactMap { $0 },
              "a CHD becomes PS1 Game (Disc 1)/EBOOT.PBP for a PSP", c.jobs.first?.detail ?? "")
        c.pbpFolders = false
        // Not a PlayStation game
        let pb5 = workspace("pbp-notps1", from: F, ["plain.iso"], into: W)
        jobs = await runBatch([pb5.appendingPathComponent("plain.iso")])
        check(jobs.first?.state == .failed && jobs.first?.detail.contains("PlayStation") == true && !exists(pb5.appendingPathComponent("plain.pbp")),
              "a disc that isn't a PlayStation game is refused", jobs.first?.detail ?? "")
        c.outputFormat = .chd
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
