// Make: CSO / ZSO, for real PSP and PS2 hardware: a PSP reads CSO (with custom firmware), and Open PS2 Loader
// reads ZSO. Made from ISO images with the built-in maxcso.
import Foundation

enum CSOFormat: String, CaseIterable, Identifiable {
    case automatic, cso, zso
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic (PSP → CSO, PS2 → ZSO)"
        case .cso: return "Always CSO"
        case .zso: return "Always ZSO"
        }
    }
}

extension Converter {
    /// CSO for a PSP game, ZSO for a PS2 game (what Open PS2 Loader reads), or the chosen one.
    nonisolated static func csoExtension(for iso: URL, setting: CSOFormat) -> String {
        switch setting {
        case .cso: return "cso"
        case .zso: return "zso"
        case .automatic:
            let names = isoRootNames(iso)
            if names.contains("SYSTEM.CNF"), let cnf = isoRootFile(iso, named: "SYSTEM.CNF"),
               String(decoding: cnf, as: UTF8.self).uppercased().contains("BOOT2") { return "zso" }
            return "cso"
        }
    }

    func makeCSO(index: Int) async {
        let job = jobs[index]
        let id = job.id
        let fm = FileManager.default
        let src = job.url
        func fail(_ msg: String) {
            update(id) { $0.state = .failed; $0.detail = msg; $0.progress = nil; $0.timed = false }
            append("✗ \(src.lastPathComponent): \(msg)")
        }
        update(id) { $0.state = .working; $0.detail = "Starting…"; $0.progress = nil; $0.fraction = 0; $0.timed = true }
        append("▶ \(src.lastPathComponent) → CSO/ZSO")
        guard let maxcso = Converter.findTool("maxcso") else { return fail("maxcso is missing from the app. Download Converterator again.") }
        guard fm.fileExists(atPath: src.path) else {
            return fail("Can't find the file. If it's on an external drive, connect it, then use Clear → Retry Failed.")
        }
        let work = fm.temporaryDirectory.appendingPathComponent("converterator-cso-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)

        // The ISO to compress: as it is, patched, or unpacked from a CHD or an archive first.
        let ext = src.pathExtension.lowercased()
        var iso = src
        var firstPatch: URL?
        if job.patch != nil {
            update(id) { $0.detail = "Applying \(job.patch!.lastPathComponent)…" }
            switch await patchedDisc(job, work: work) {
            case .success(let r): iso = r.disc; firstPatch = r.firstPatch
            case .failure(let e): return fail(e.message)
            }
        } else if ext == "chd" {
            update(id) { $0.detail = "Unpacking the CHD…" }
            guard let chdman else { return fail("chdman is missing") }
            switch await Converter.unpackCHD(src, into: work.appendingPathComponent("unpacked"), chdman: chdman) {
            case .success(let d): iso = d
            case .failure(let e): return fail(e.message)
            }
        } else if Converter.archiveExtensions.contains(ext) {
            update(id) { $0.detail = "Unpacking \(ext)…" }
            if let err = await unpackArchive(src, to: work.appendingPathComponent("unpacked")) { return fail(err) }
            guard let d = Converter.gamesInFolder(work.appendingPathComponent("unpacked")).first(where: { $0.pathExtension.lowercased() == "iso" }) else {
                return fail("No .iso inside the archive (CSO and ZSO are made from ISO images)")
            }
            iso = d
        }
        if cancelRequested { return fail("Cancelled") }
        guard iso.pathExtension.lowercased() == "iso" else {
            return fail(ext == "chd" || ext == "cue" || ext == "gdi"
                        ? "CSO and ZSO are made from ISO images (PSP and PS2 DVD games). This is a CD image, which PSP and PS2 loaders don't use."
                        : "CSO and ZSO are made from ISO images (PSP and PS2 games).")
        }
        if Converter.isNintendoDisc(iso) { return fail("GameCube and Wii games can't be made into CSO or ZSO; they become RVZ with Make: CHD.") }

        let fmt = Converter.csoExtension(for: iso, setting: csoFormat)
        let name = job.patchedName ?? Converter.gameName(src)
        var outDir = outputDir ?? src.deletingLastPathComponent()
        if organizeBySystem, let system = Systems.detect(iso) {
            outDir = outDir.appendingPathComponent(systemFolderName(system), isDirectory: true)
        }
        do { try fm.createDirectory(at: outDir, withIntermediateDirectories: true) }
        catch { return fail("Can't create folder: \(error.localizedDescription)") }
        let out = outDir.appendingPathComponent("\(name).\(fmt)")
        let inSize = totalSize(Converter.sourceFiles(for: src))

        func finish(_ summary: String, outSize: Double) async {
            var summary = summary
            if let note = await copyToDevice([out], id: id) { summary += " · " + note }
            update(id) {
                $0.state = .done; $0.detail = summary; $0.progress = nil; $0.timed = true; $0.outputs = [out]
                $0.bytesIn = inSize; $0.bytesOut = outSize
            }
            append("✓ \(summary)")
        }
        if fm.fileExists(atPath: out.path) && !overwrite {
            return await finish("\(out.lastPathComponent) · already existed", outSize: totalSize([out]))
        }
        if let p = DiskSpace.problem(needs: totalSize([iso]), at: outDir) { return fail(p) }

        let label = fmt.uppercased()
        update(id) { $0.detail = "Making \(out.lastPathComponent)…"; $0.progress = nil }
        let partial = outDir.appendingPathComponent(".converterator-partial-\(out.lastPathComponent)")
        try? fm.removeItem(at: partial)
        let status = await run(maxcso, ["--format=" + (fmt == "cso" ? "cso1" : "zso"), iso.path, "-o", partial.path]) { [weak self] line in
            if let r = line.range(of: #"(\d+)%"#, options: .regularExpression), let p = Double(line[r].dropLast()) {
                self?.update(id) { $0.progress = p / 100; $0.fraction = p / 100; $0.detail = "Making \(label) — \(Int(p))%" }
            } else {
                self?.append("  [maxcso] \(line)")
            }
        }
        if cancelRequested { try? fm.removeItem(at: partial); return fail("Cancelled") }
        guard status == 0, totalSize([partial]) > 0 else {
            try? fm.removeItem(at: partial)
            return fail("maxcso couldn't make the \(label) (exit \(status)) — see log")
        }
        do {
            if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
            try fm.moveItem(at: partial, to: out)
        } catch { return fail("Couldn't save \(out.lastPathComponent): \(error.localizedDescription)") }

        // Verify: the CSO/ZSO must hold exactly the ISO (same CRC32 of the uncompressed data).
        var verified = false
        if verify {
            update(id) { $0.detail = "Verifying…"; $0.progress = nil }
            func crc(_ f: URL) async -> String? {
                var found: String?
                _ = await run(maxcso, ["--crc", f.path]) { line in
                    if let r = line.range(of: #"CRC32: [0-9a-fA-F]{8}"#, options: .regularExpression) { found = String(line[r].suffix(8)).lowercased() }
                }
                return found
            }
            let a = await crc(iso), b = await crc(out)
            guard let a, a == b else {
                try? fm.removeItem(at: out)
                return fail("\(out.lastPathComponent) didn't match the ISO when checked, so it was deleted")
            }
            verified = true
        }

        let outSize = totalSize([out])
        var summary = "\(out.lastPathComponent) · " + Converter.describeSaving(input: totalSize([iso]), output: outSize)
        if let firstPatch { summary += " · patched with \(firstPatch.lastPathComponent)" }
        if verified { summary += " · verified" }
        await finish(summary, outSize: outSize)
    }
}
