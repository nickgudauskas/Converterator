// Converterator — Making PBPs (PlayStation games for a PSP or PS Vita) with PSXPackager.
import Foundation

extension Converter {
    /// Makes a PBP from a PlayStation game: a .cue, .iso, .chd, or a zip/7z of one, with its patches
    /// applied first. Discs of the same game queued together ("Game (Disc 1)", "Game (Disc 2)") go into
    /// one multi-disc PBP. Originals are never moved to the Trash.
    func makePBP(index: Int) async {
        let job = jobs[index]
        let id = job.id
        let fm = FileManager.default
        let src = job.url
        func fail(_ msg: String) {
            update(id) { $0.state = .failed; $0.detail = msg; $0.progress = nil; $0.timed = false }
            append("✗ \(src.lastPathComponent): \(msg)")
        }
        update(id) { $0.state = .working; $0.detail = "Starting…"; $0.progress = nil; $0.fraction = 0; $0.timed = true }
        append("▶ \(src.lastPathComponent) → PBP")
        guard let psxpackager else { return fail("PSXPackager is missing from the app. Download Converterator again.") }
        guard fm.fileExists(atPath: src.path) else {
            return fail("Can't find the file. If it's on an external drive, connect it, then use Clear → Retry Failed.")
        }
        let ext = src.pathExtension.lowercased()
        guard ext != "pbp" else { return fail("It's already a PBP") }
        guard ext != "gdi" else { return fail("A PBP can only hold PlayStation games (this is a Dreamcast disc)") }

        // The other discs of this game, if they're waiting too, go in the same PBP.
        var discs = [job]
        if let d = DiscName.parse(Converter.gameName(src)) {
            let dir = src.deletingLastPathComponent()
            let siblings = jobs.filter { j in
                j.id != id && j.state == .queued && j.url.deletingLastPathComponent() == dir
                    && DiscName.parse(j.url.deletingPathExtension().lastPathComponent)?.key == d.key
            }
            discs = ([job] + siblings).sorted {
                (DiscName.parse($0.url.deletingPathExtension().lastPathComponent)?.disc ?? 0)
                    < (DiscName.parse($1.url.deletingPathExtension().lastPathComponent)?.disc ?? 0)
            }
            for s in siblings { update(s.id) { $0.state = .working; $0.detail = "Going into the same PBP as \(src.lastPathComponent)" } }
        }
        func failAll(_ msg: String) {
            for d in discs where d.id != id { update(d.id) { $0.state = .failed; $0.detail = msg; $0.progress = nil; $0.timed = false } }
            fail(msg)
        }

        let work = fm.temporaryDirectory.appendingPathComponent("converterator-pbp-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)

        // Each disc as PSXPackager will read it: as it is, or patched (a CHD or archive unpacked first).
        var inputs: [URL] = []
        var firstPatch: URL?
        for (n, d) in discs.enumerated() {
            var input = d.url
            if let patch = d.patch {
                update(id) { $0.detail = "Applying \(patch.lastPathComponent)…" }
                let dw = work.appendingPathComponent("disc\(n + 1)")
                switch await patchedDisc(d, work: dw) {
                case .success(let r): input = r.disc; firstPatch = firstPatch ?? r.firstPatch
                case .failure(let e): return failAll("\(d.url.lastPathComponent): \(e.message)")
                }
                if cancelRequested { return failAll("Cancelled") }
            } else if Converter.needsECM(input) {
                switch await expandECM(input, into: work.appendingPathComponent("disc\(n + 1)-ecm"), id: id) {
                case .success(let disc): input = disc
                case .failure(let e): return failAll("\(d.url.lastPathComponent): \(e.message)")
                }
                if cancelRequested { return failAll("Cancelled") }
            }
            inputs.append(input)
        }

        // Name: the game ("Game" for "Game (Disc 1)"), or the patched name ("Racing Lagoon (English)").
        var name = discs.count > 1
            ? DiscName.parse(Converter.gameName(src))?.key ?? Converter.gameName(src)
            : Converter.gameName(src)
        if let firstPatch, let patch = discs.first(where: { $0.patch != nil })?.patch {
            name = Patcher.patchedName(game: discs.count > 1 ? src.deletingLastPathComponent().appendingPathComponent(name + ".cue") : src,
                                       patch: firstPatch, alsoLookIn: patch.deletingPathExtension().lastPathComponent)
        }
        name = Converter.safeFileName(name)
        let baseDir = outputDir ?? src.deletingLastPathComponent()
        let outDir = pbpFolders ? baseDir.appendingPathComponent(name, isDirectory: true) : baseDir
        let fileName = pbpFolders ? "EBOOT" : name
        let out = outDir.appendingPathComponent(fileName + ".pbp")
        do { try fm.createDirectory(at: outDir, withIntermediateDirectories: true) }
        catch { return failAll("Can't create folder: \(error.localizedDescription)") }
        if fm.fileExists(atPath: out.path) && !overwrite {
            append("  \(out.lastPathComponent) already exists — skipped (turn on Overwrite to replace)")
            for d in discs { update(d.id) { $0.state = .done; $0.detail = "\(name).pbp · already existed"; $0.progress = nil; $0.timed = false } }
            return
        }
        let inSize = totalSize(discs.flatMap { Converter.sourceFiles(for: $0.url) })
        if let p = DiskSpace.problem(needs: inSize, at: outDir) { return failAll(p) }

        // Several discs: an .m3u listing them, which PSXPackager turns into one multi-disc PBP.
        var input = inputs[0]
        if inputs.count > 1 {
            input = work.appendingPathComponent("\(name).m3u")
            try? inputs.map(\.path).joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        }
        update(id) { $0.detail = "Making \(name).pbp…"; $0.progress = 0 }
        var errors: [String] = []
        let status = await run(psxpackager, ["-i", input.path, "-o", outDir.path, "-f", fileName, "-x", "-v", "2"]) { [weak self] line in
            if let r = line.range(of: #"(\d+)%(?!.*\d+%)"#, options: .regularExpression), let p = Double(line[r].dropLast()) {
                self?.update(id) { $0.progress = p / 100; $0.fraction = p / 100; $0.detail = "Making \(name).pbp — \(Int(p))%" }
            } else {
                if line.lowercased().contains("error") || line.contains("must") || line.contains("not ") { errors.append(line) }
                self?.append("  [psxpackager] \(line)")
            }
        }
        if cancelRequested { try? fm.removeItem(at: out); return failAll("Cancelled") }
        // PSXPackager reports success even when it couldn't make anything, so check for the file.
        guard status == 0, totalSize([out]) > 0 else {
            try? fm.removeItem(at: out)
            let why = errors.first.map { " (\($0))" } ?? ""
            return failAll("PSXPackager couldn't make a PBP\(why). Is it a PlayStation game?")
        }
        let outSize = totalSize([out])
        var summary = (pbpFolders ? "\(name)/EBOOT.PBP" : "\(name).pbp") + " · \(formatBytes(outSize))"
        if discs.count > 1 { summary += " · \(discs.count) discs" }
        if let firstPatch { summary += " · patched with \(firstPatch.lastPathComponent)" }
        if let note = await copyToDevice([pbpFolders ? out.deletingLastPathComponent() : out], id: id) { summary += " · " + note }
        for d in discs {
            update(d.id) {
                $0.state = .done; $0.progress = nil; $0.timed = true
                $0.detail = d.id == id ? summary : "In \(name).pbp with the other discs"
                $0.outputs = [out]
                if d.id == id { $0.bytesIn = inSize; $0.bytesOut = outSize }
            }
        }
        append("✓ \(summary)")
    }

    /// One disc with its patches applied, in `work`: a CHD or archive is unpacked first.
    func patchedDisc(_ job: Job, work: URL) async -> Result<(disc: URL, firstPatch: URL?), CHDCheck.CheckError> {
        guard let patch = job.patch else { return .success((job.url, nil)) }
        let fm = FileManager.default
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        var disc = job.url
        switch job.url.pathExtension.lowercased() {
        case "chd":
            switch await Converter.unpackCHD(job.url, into: work.appendingPathComponent("unpacked"), chdman: chdman!) {
            case .success(let d): disc = d
            case .failure(let e): return .failure(e)
            }
        case "zip", "7z", "rar":
            if let err = await unpackArchive(job.url, to: work.appendingPathComponent("unpacked")) { return .failure(.init(message: err)) }
            guard let d = Converter.gamesInFolder(work.appendingPathComponent("unpacked")).first else {
                return .failure(.init(message: "No disc image inside the archive"))
            }
            disc = d
        default: break
        }
        if Converter.needsECM(disc) {
            switch await expandECM(disc, into: work.appendingPathComponent("ecm"), id: job.id) {
            case .success(let d): disc = d
            case .failure(let e): return .failure(e)
            }
        }
        let xdelta = Converter.findTool("xdelta3")
        var first: URL?
        for (k, p) in ([patch] + job.morePatches).enumerated() {
            let candidates = Patcher.patchFiles(p, member: k == 0 ? job.patchMember : nil, unpackInto: work.appendingPathComponent("patches\(k)"))
            var done = false
            var why = candidates.isEmpty ? "There's no patch in \(p.lastPathComponent)" : "The patch doesn't fit this game"
            for (j, c) in candidates.enumerated() {
                switch await Patcher.preparePatched(disc, patch: c, work: work.appendingPathComponent("stage\(k)-\(j)"), xdelta: xdelta, progress: { _ in }) {
                case .success(let r):
                    disc = r.disc; done = true
                    if k == 0 { first = c }
                    append("  applied \(c.lastPathComponent) to \(r.track.lastPathComponent)")
                case .failure(let f): why = f.message
                }
                if done { break }
            }
            guard done else { return .failure(.init(message: k == 0 ? why : "\(p.lastPathComponent): \(why)")) }
        }
        return .success((disc, first))
    }
}
