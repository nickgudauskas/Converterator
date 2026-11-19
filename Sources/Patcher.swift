// Converterator — Applying patches (translations, fixes) to a disc image before it's compressed.
import Foundation

/// Patch formats used for disc games. xdelta is the most common for disc translations; PPF is
/// common for PlayStation; BPS and IPS turn up now and then.
enum PatchFormat: String, Sendable {
    case ips = "IPS", bps = "BPS", ppf = "PPF", xdelta = "xdelta"

    nonisolated static let byExtension: [String: PatchFormat] = [
        "ips": .ips, "bps": .bps, "ppf": .ppf,
        "xdelta": .xdelta, "xdelta3": .xdelta, "vcdiff": .xdelta, "delta": .xdelta,
    ]
    nonisolated static func of(_ url: URL) -> PatchFormat? { byExtension[url.pathExtension.lowercased()] }
}

enum Patcher {
    struct Failure: Error, Sendable { let message: String }

    // MARK: Naming

    /// The name for a patched game's CHD, e.g. "Racing Lagoon (English)".
    /// A patch already named like a title ("Tengai Makyou Zero (English)": spaces and capitals) keeps its
    /// name. Otherwise ("racinglagoonenglish", "rl_t-en_v1") it's the game's title, from Redump's name for
    /// the original dump if it matched, else the original file's name, without its region and other tags,
    /// plus what the patch is for: a language, "Undub", or "Patched".
    nonisolated static func patchedName(game: URL, patch: URL, redumpGame: String? = nil, alsoLookIn other: String? = nil) -> String {
        let patchName = patch.deletingPathExtension().lastPathComponent
        if patchName.contains(" ") && patchName.contains(where: \.isUppercase) {
            return Converter.safeFileName(patchName)
        }
        var title = redumpGame ?? game.deletingPathExtension().lastPathComponent
        if let r = title.range(of: #"\s*[\(\[]"#, options: .regularExpression) { title = String(title[..<r.lowerBound]) }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = game.deletingPathExtension().lastPathComponent }
        // `other`: the zip a patch came in, whose name often says the language when the patch's doesn't.
        let what = tag(for: patchName) ?? other.flatMap { tag(for: $0) } ?? "Patched"
        return Converter.safeFileName("\(title) (\(what))")
    }

    /// Languages (and undubs) as they show up in patch names. Full words are found even run together
    /// with other words ("racinglagoonenglish"); short codes only on their own ("rl_en_v1", "T-En").
    nonisolated static let tags: [(name: String, words: [String], codes: [String])] = [
        ("English", ["english"], ["en", "eng"]),
        ("Spanish", ["spanish", "espanol", "español"], ["es", "esp", "spa"]),
        ("French", ["french", "francais", "français"], ["fr", "fra", "fre"]),
        ("German", ["german", "deutsch"], ["de", "ger", "deu"]),
        ("Italian", ["italian", "italiano"], ["it", "ita"]),
        ("Portuguese", ["portuguese", "portugues", "português"], ["pt", "ptbr", "por", "br"]),
        ("Russian", ["russian"], ["ru", "rus"]),
        ("Polish", ["polish", "polski"], ["pl", "pol"]),
        ("Chinese", ["chinese"], ["zh", "chi", "chs", "cht"]),
        ("Korean", ["korean"], ["ko", "kor"]),
        ("Undub", ["undub", "undubbed"], []),
    ]

    nonisolated static func tag(for patchName: String) -> String? {
        let lower = patchName.lowercased()
        // "T-En" / "T_En" / "(T-En)" translation tags, then words and codes
        let tokens = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let translated = lower.range(of: #"t[-_ ]([a-z]{2,3})\b"#, options: .regularExpression)
            .map { String(lower[$0].dropFirst(2)) }
        for t in tags {
            if let code = translated, t.codes.contains(code) { return t.name }
        }
        for t in tags where t.words.contains(where: { lower.contains($0) }) { return t.name }
        for t in tags where t.codes.contains(where: { tokens.contains($0) }) { return t.name }
        return nil
    }

    /// A patch next to `game` with the same name (Game.xdelta beside Game.cue), if there is one.
    nonisolated static func findPatch(for game: URL) -> URL? {
        let base = game.deletingPathExtension()
        for ext in ["xdelta", "xdelta3", "vcdiff", "delta", "ppf", "bps", "ips"] {
            for variant in [ext, ext.uppercased()] {
                let p = base.appendingPathExtension(variant)
                if FileManager.default.fileExists(atPath: p.path) { return p }
            }
        }
        // Or still in its download zip (a zip of patches, not the game's own archive)
        let zip = base.appendingPathExtension("zip")
        if zip != game, FileManager.default.fileExists(atPath: zip.path), isPatchZip(zip) { return zip }
        return nil
    }

    /// Makes a patched copy of a disc in `work`: the track the patch fits is patched into a new file,
    /// the other tracks are linked (not copied), and the .cue/.gdi is copied beside them. Returns the
    /// file to give chdman (the .cue/.gdi, or the patched .iso) and which track was patched.
    nonisolated static func preparePatched(_ disc: URL, patch: URL, work: URL, xdelta: URL?,
                                           progress: @escaping @Sendable (Double) -> Void) async -> Result<(disc: URL, track: URL), Failure> {
        let fm = FileManager.default
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true) }
        catch { return .failure(Failure(message: "Can't create a temporary folder")) }
        let isISO = disc.pathExtension.lowercased() == "iso"
        let tracks = isISO ? [disc] : Array(Converter.sourceFiles(for: disc).dropFirst())
        guard !tracks.isEmpty else { return .failure(Failure(message: "No track files to patch")) }

        let result = await apply(patch, candidates: tracks, outputFor: { work.appendingPathComponent($0.lastPathComponent) },
                                 xdelta: xdelta, progress: progress)
        guard case .success(let patched) = result else {
            if case .failure(let f) = result { return .failure(f) }
            return .failure(Failure(message: "Patching failed"))
        }
        if isISO { return .success((work.appendingPathComponent(disc.lastPathComponent), patched)) }
        // The other tracks are linked in place, so nothing big is copied.
        for t in tracks where t != patched {
            let link = work.appendingPathComponent(t.lastPathComponent)
            try? fm.removeItem(at: link)
            do { try fm.createSymbolicLink(at: link, withDestinationURL: t) }
            catch { return .failure(Failure(message: "Couldn't link \(t.lastPathComponent)")) }
        }
        let descriptor = work.appendingPathComponent(disc.lastPathComponent)
        try? fm.removeItem(at: descriptor)
        do { try fm.copyItem(at: disc, to: descriptor) }
        catch { return .failure(Failure(message: "Couldn't copy \(disc.lastPathComponent)")) }
        return .success((descriptor, patched))
    }

    /// Applies `patch` to whichever candidate it was made for, writing to `outputFor(candidate)`.
    /// Returns the candidate used. BPS and PPF say which file they expect, so the right one is picked;
    /// xdelta checks its own result, so each candidate is tried in turn; IPS can't tell, so the first
    /// (normally the data track) is used.
    nonisolated static func apply(_ patch: URL, candidates: [URL], outputFor: (URL) -> URL, xdelta: URL?,
                                  progress: @escaping @Sendable (Double) -> Void) async -> Result<URL, Failure> {
        guard let format = PatchFormat.of(patch) else { return .failure(Failure(message: "Not a patch file Converterator knows (IPS, BPS, PPF or xdelta)")) }
        guard let data = try? Data(contentsOf: patch, options: .alwaysMapped) else { return .failure(Failure(message: "Can't read the patch")) }
        let notFor = "The patch doesn't fit this game. It may be for a different version or region, or for the Redump dump."
        switch format {
        case .ips:
            let target = candidates[0]
            do { try applyIPS(data, source: target, output: outputFor(target)) } catch let f as Failure { return .failure(f) } catch { return .failure(Failure(message: "\(error)")) }
            return .success(target)
        case .bps:
            guard let want = bpsSource(data) else { return .failure(Failure(message: "Not a valid BPS patch")) }
            guard let target = candidates.first(where: { totalSize([$0]) == Double(want.size) && crc32(of: $0) == want.crc })
            else { return .failure(Failure(message: notFor + " (BPS expects a file of \(formatBytes(Double(want.size))) with CRC32 \(String(format: "%08X", want.crc)))")) }
            do { try applyBPS(data, source: target, output: outputFor(target)) } catch let f as Failure { return .failure(f) } catch { return .failure(Failure(message: "\(error)")) }
            return .success(target)
        case .ppf:
            guard let header = ppfHeader(data) else { return .failure(Failure(message: "Not a valid PPF patch")) }
            let target: URL
            if let check = header.blockCheck {
                guard let t = candidates.first(where: { ppfBlockMatches($0, check, at: header.blockOffset) }) else { return .failure(Failure(message: notFor)) }
                target = t
            } else if let size = header.originalSize {
                guard let t = candidates.first(where: { totalSize([$0]) == Double(size) }) else { return .failure(Failure(message: notFor)) }
                target = t
            } else {
                target = candidates[0]
            }
            do { try applyPPF(data, header: header, source: target, output: outputFor(target)) } catch let f as Failure { return .failure(f) } catch { return .failure(Failure(message: "\(error)")) }
            return .success(target)
        case .xdelta:
            guard let xdelta else { return .failure(Failure(message: "xdelta3 is missing from the app, so xdelta patches can't be applied. Download Converterator again.")) }
            for (n, c) in candidates.enumerated() {
                let out = outputFor(c)
                try? FileManager.default.removeItem(at: out)
                let (status, _) = await ToolRun.run(xdelta, ["-d", "-f", "-s", c.path, patch.path, out.path], watchdog: false) { _ in }
                progress(Double(n + 1) / Double(candidates.count))
                if status == 0 { return .success(c) }
                try? FileManager.default.removeItem(at: out)
            }
            return .failure(Failure(message: notFor))
        }
    }

    // MARK: IPS

    nonisolated static func applyIPS(_ p: Data, source: URL, output: URL) throws {
        let b = [UInt8](p)
        guard b.count >= 8, Array(b[0..<5]) == Array("PATCH".utf8) else { throw Failure(message: "Not a valid IPS patch") }
        try copy(source, to: output)
        let h = try FileHandle(forUpdating: output)
        defer { try? h.close() }
        var i = 5
        while i + 3 <= b.count {
            if Array(b[i..<(i + 3)]) == Array("EOF".utf8) {
                // Optional 3-byte size to truncate to.
                if i + 6 <= b.count { try h.truncate(atOffset: UInt64(Int(b[i + 3]) << 16 | Int(b[i + 4]) << 8 | Int(b[i + 5]))) }
                return
            }
            guard i + 5 <= b.count else { break }
            let offset = Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2])
            let size = Int(b[i + 3]) << 8 | Int(b[i + 4])
            i += 5
            try h.seek(toOffset: UInt64(offset))
            if size == 0 {   // run of one byte
                guard i + 3 <= b.count else { break }
                let count = Int(b[i]) << 8 | Int(b[i + 1])
                h.write(Data(repeating: b[i + 2], count: count))
                i += 3
            } else {
                guard i + size <= b.count else { break }
                h.write(Data(b[i..<(i + size)]))
                i += size
            }
        }
        throw Failure(message: "The IPS patch is incomplete")
    }

    // MARK: BPS

    nonisolated static func bpsSource(_ p: Data) -> (size: UInt64, crc: UInt32)? {
        let b = [UInt8](p.prefix(64))
        guard p.count >= 16, b.count >= 4, Array(b[0..<4]) == Array("BPS1".utf8) else { return nil }
        var i = 4
        guard let size = varint(b, &i) else { return nil }
        let crc = p.withUnsafeBytes { raw in raw.loadUnaligned(fromByteOffset: p.count - 12, as: UInt32.self).littleEndian }
        return (size, crc)
    }

    nonisolated static func applyBPS(_ p: Data, source: URL, output: URL) throws {
        let b = [UInt8](p)
        var i = 4
        guard let sourceSize = varint(b, &i), let targetSize = varint(b, &i), let metaSize = varint(b, &i) else { throw Failure(message: "Not a valid BPS patch") }
        i += Int(metaSize)
        let src = try Data(contentsOf: source, options: .alwaysMapped)
        guard UInt64(src.count) == sourceSize else { throw Failure(message: "The BPS patch is for a different file") }
        var out = [UInt8](repeating: 0, count: Int(targetSize))
        var o = 0, srcRel = 0, tgtRel = 0
        let end = b.count - 12
        try src.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
            while i < end {
                guard let v = varint(b, &i) else { throw Failure(message: "The BPS patch is damaged") }
                let cmd = v & 3, len = Int(v >> 2) + 1
                guard o + len <= out.count else { throw Failure(message: "The BPS patch is damaged") }
                switch cmd {
                case 0: for k in 0..<len { out[o + k] = s[o + k] }                       // SourceRead
                case 1: for k in 0..<len { out[o + k] = b[i + k] }; i += len               // TargetRead
                case 2:                                                                     // SourceCopy
                    guard let d = varint(b, &i) else { throw Failure(message: "The BPS patch is damaged") }
                    srcRel += (d & 1 == 1 ? -1 : 1) * Int(d >> 1)
                    for k in 0..<len { out[o + k] = s[srcRel + k] }; srcRel += len
                default:                                                                    // TargetCopy
                    guard let d = varint(b, &i) else { throw Failure(message: "The BPS patch is damaged") }
                    tgtRel += (d & 1 == 1 ? -1 : 1) * Int(d >> 1)
                    for k in 0..<len { out[o + k] = out[tgtRel + k] }; tgtRel += len
                }
                o += len
            }
        }
        let wantTarget = p.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p.count - 8, as: UInt32.self).littleEndian }
        guard crc32(out) == wantTarget else { throw Failure(message: "The patched file's checksum is wrong, so the patch didn't apply cleanly") }
        try Data(out).write(to: output)
    }

    nonisolated static func varint(_ b: [UInt8], _ i: inout Int) -> UInt64? {
        var data: UInt64 = 0, shift: UInt64 = 1
        while i < b.count {
            let x = UInt64(b[i]); i += 1
            data += (x & 0x7f) * shift
            if x & 0x80 != 0 { return data }
            shift <<= 7
            data += shift
            if shift > 1 << 56 { return nil }
        }
        return nil
    }

    // MARK: PPF

    struct PPFHeader: Sendable {
        let version: Int
        let recordsStart: Int
        let recordsEnd: Int
        let originalSize: UInt32?   // PPF2
        let blockCheck: [UInt8]?    // 1024 bytes that must match the source
        let blockOffset: UInt64
        let hasUndo: Bool
    }

    nonisolated static func ppfHeader(_ p: Data) -> PPFHeader? {
        let b = [UInt8](p)
        guard b.count >= 56, Array(b[0..<3]) == Array("PPF".utf8) else { return nil }
        // A file_id.diz description may be stuck on the end.
        var end = b.count
        if let r = p.range(of: Data("@BEGIN_FILE_ID.DIZ".utf8), options: .backwards) { end = r.lowerBound }
        switch b[5] {
        case 0:   // PPF1: header 56 bytes, records of offset(4) len(1) data
            return PPFHeader(version: 1, recordsStart: 56, recordsEnd: end, originalSize: nil, blockCheck: nil, blockOffset: 0x9320, hasUndo: false)
        case 1:   // PPF2: + original size(4) + block check(1024)
            guard b.count >= 1084 else { return nil }
            let size = UInt32(b[56]) | UInt32(b[57]) << 8 | UInt32(b[58]) << 16 | UInt32(b[59]) << 24
            return PPFHeader(version: 2, recordsStart: 1084, recordsEnd: end, originalSize: size,
                             blockCheck: Array(b[60..<1084]), blockOffset: 0x9320, hasUndo: false)
        case 2:   // PPF3: image type(1) block check flag(1) undo flag(1) dummy(1) [+ block check(1024)]
            let imageType = b[56], hasCheck = b[57] != 0, undo = b[58] != 0
            let start = 60 + (hasCheck ? 1024 : 0)
            guard b.count >= start else { return nil }
            return PPFHeader(version: 3, recordsStart: start, recordsEnd: end, originalSize: nil,
                             blockCheck: hasCheck ? Array(b[60..<1084]) : nil,
                             blockOffset: imageType == 1 ? 0x80A0 : 0x9320, hasUndo: undo)
        default: return nil
        }
    }

    nonisolated static func ppfBlockMatches(_ file: URL, _ check: [UInt8], at offset: UInt64) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil, let d = try? h.read(upToCount: check.count) else { return false }
        return [UInt8](d) == check
    }

    nonisolated static func applyPPF(_ p: Data, header: PPFHeader, source: URL, output: URL) throws {
        let b = [UInt8](p)
        try copy(source, to: output)
        let h = try FileHandle(forUpdating: output)
        defer { try? h.close() }
        var i = header.recordsStart
        let offsetSize = header.version == 3 ? 8 : 4
        while i + offsetSize + 1 <= header.recordsEnd {
            var offset: UInt64 = 0
            for k in 0..<offsetSize { offset |= UInt64(b[i + k]) << (8 * UInt64(k)) }
            let len = Int(b[i + offsetSize])
            i += offsetSize + 1
            guard i + len <= header.recordsEnd else { throw Failure(message: "The PPF patch is damaged") }
            try h.seek(toOffset: offset)
            h.write(Data(b[i..<(i + len)]))
            i += len + (header.hasUndo ? len : 0)
        }
    }

    // MARK: Helpers

    nonisolated static func copy(_ from: URL, to: URL) throws {
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.copyItem(at: from, to: to)
        // A copy of a read-only original is read-only too; the patch has to write to it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: to.path)
    }

    nonisolated static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    nonisolated static func crc32<S: Sequence>(_ bytes: S, start: UInt32 = 0xFFFFFFFF) -> UInt32 where S.Element == UInt8 {
        var c = start
        for x in bytes { c = crcTable[Int((c ^ UInt32(x)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    nonisolated static func crc32(of file: URL) -> UInt32? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var c: UInt32 = 0xFFFFFFFF
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty {
            chunk.withUnsafeBytes { raw in
                for x in raw { c = crcTable[Int((c ^ UInt32(x)) & 0xff)] ^ (c >> 8) }
            }
        }
        return c ^ 0xFFFFFFFF
    }
}

// MARK: - Zipped patches

extension Patcher {
    /// A .zip holding patch files but no disc images, as translation patches are usually downloaded.
    nonisolated static func isPatchZip(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "zip", let entries = Converter.zipEntryNames(url) else { return false }
        let exts = entries.map { ($0 as NSString).pathExtension.lowercased() }
        return exts.contains { PatchFormat.byExtension[$0] != nil } && !exts.contains { Converter.inputExtensions.contains($0) }
    }

    /// The patch files to try: the file itself, or (for a zip) every patch inside it, newest-looking
    /// first ("v1.1" before "v1.0"). `member` limits a zip to one file inside it.
    nonisolated static func patchFiles(_ patch: URL, member: String?, unpackInto dir: URL) -> [URL] {
        guard patch.pathExtension.lowercased() == "zip" else { return [patch] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard UpdateChecker.runTool("/usr/bin/ditto", ["-x", "-k", patch.path, dir.path]) == 0 else { return [] }
        let all = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .allObjects as? [URL] ?? [])
            .filter { PatchFormat.of($0) != nil && !$0.path.contains("/__MACOSX/") }
        if let member {
            return all.filter { $0.path.hasSuffix("/" + member) || $0.lastPathComponent == (member as NSString).lastPathComponent }
        }
        return all.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
    }
}

// MARK: - Patches folder

/// A folder where you keep all your patches (loose or still in their download zips). When it's on,
/// each game added to the list is given the patch made for it: BPS and PPF patches by checksum (they
/// record what they were made for), xdelta and IPS patches by name.
@MainActor
final class PatchLibrary: ObservableObject {
    static let shared = PatchLibrary()

    @Published var folder: URL? {
        didSet { UserDefaults.standard.set(folder?.path, forKey: "patchesFolder"); refreshCount(); lookUpWaitingGames() }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "patchesFolderEnabled"); lookUpWaitingGames() }
    }
    @Published private(set) var patchCount = 0
    @Published private(set) var isLooking = false

    var active: Bool { enabled && folder != nil }

    init() {
        let d = UserDefaults.standard
        if let p = d.string(forKey: "patchesFolder"), FileManager.default.fileExists(atPath: p) {
            folder = URL(fileURLWithPath: p, isDirectory: true)
        }
        enabled = d.object(forKey: "patchesFolderEnabled") as? Bool ?? true
        refreshCount()
    }

    struct Entry: Sendable {
        let url: URL            // the patch file, or the zip it's in
        let member: String?     // its path inside the zip
        let name: String        // its file name
        let format: PatchFormat
        let key: String         // name in lowercase letters and digits only, for matching
        let bps: (size: UInt64, crc: UInt32)?
        let ppfBlock: (bytes: [UInt8], offset: UInt64)?
    }

    private func refreshCount() {
        guard let folder else { patchCount = 0; return }
        Task.detached { let n = PatchLibrary.index(folder).count; await MainActor.run { self.patchCount = n } }
    }

    /// Finds patches for games waiting in the list that don't have one yet.
    func lookUpWaitingGames() {
        let c = Converter.shared
        lookUp(c.jobs.filter { $0.state == .queued && $0.patch == nil && !$0.isExtraction }.map { ($0.id, $0.url) })
    }

    /// Looks for a patch for each game, in the background, and gives each game the one found.
    func lookUp(_ games: [(UUID, URL)]) {
        guard active, let folder, !games.isEmpty else { return }
        isLooking = true
        let prefer = PatchLibrary.preferredLanguage
        Task.detached {
            let entries = PatchLibrary.index(folder)
            var found: [(UUID, Entry)] = []
            for (id, game) in games {
                if let e = PatchLibrary.match(game: game, entries: entries, prefer: prefer) { found.append((id, e)) }
            }
            let results = found
            await MainActor.run {
                for (id, e) in results { Converter.shared.setFolderPatch(e.url, member: e.member, for: id) }
                self.isLooking = false
            }
        }
    }

    /// The language you use on this Mac ("English"), preferred when several patches fit a game.
    nonisolated static var preferredLanguage: String? {
        guard let code = Locale.preferredLanguages.first.map({ Locale(identifier: $0).language.languageCode?.identifier ?? $0 }) else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: code)
    }

    /// Lowercase letters and digits only: "Racing Lagoon (Japan)" → "racinglagoonjapan".
    nonisolated static func key(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// A game's title for matching: its name without region and other tags, as a key.
    nonisolated static func titleKey(_ game: URL) -> String {
        var t = game.deletingPathExtension().lastPathComponent
        if let r = t.range(of: #"\s*[\(\[]"#, options: .regularExpression) { t = String(t[..<r.lowerBound]) }
        return key(t)
    }

    /// Every patch in the folder (and its subfolders), including those inside zips, with what BPS and
    /// PPF patches say they're for.
    nonisolated static func index(_ folder: URL) -> [Entry] {
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .allObjects as? [URL] ?? [])
        var entries: [Entry] = []
        func entry(url: URL, member: String?, name: String, data: () -> Data?) -> Entry? {
            guard let format = PatchFormat.byExtension[(name as NSString).pathExtension.lowercased()] else { return nil }
            var bps: (UInt64, UInt32)?, ppf: ([UInt8], UInt64)?
            if format == .bps || format == .ppf, let d = data() {
                if format == .bps, let s = Patcher.bpsSource(d) { bps = (s.size, s.crc) }
                if format == .ppf, let h = Patcher.ppfHeader(d), let b = h.blockCheck { ppf = (b, h.blockOffset) }
            }
            return Entry(url: url, member: member, name: name, format: format,
                         key: key((name as NSString).deletingPathExtension), bps: bps, ppfBlock: ppf)
        }
        for f in files where !f.path.contains("/__MACOSX/") {
            if f.pathExtension.lowercased() == "zip" {
                for m in Converter.zipEntryNames(f) ?? [] where PatchFormat.byExtension[(m as NSString).pathExtension.lowercased()] != nil {
                    if let e = entry(url: f, member: m, name: (m as NSString).lastPathComponent, data: { unzipMember(f, m) }) { entries.append(e) }
                }
            } else if let e = entry(url: f, member: nil, name: f.lastPathComponent, data: { try? Data(contentsOf: f, options: .alwaysMapped) }) {
                entries.append(e)
            }
        }
        return entries
    }

    nonisolated static func unzipMember(_ zip: URL, _ member: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", zip.path, member]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? d : nil
    }

    /// The patch for `game`: first a BPS or PPF made for one of its tracks (checked by checksum), then an
    /// xdelta or IPS whose name contains the game's title (preferring your language). Nil if none.
    nonisolated static func match(game: URL, entries: [Entry], prefer: String?) -> Entry? {
        let ext = game.pathExtension.lowercased()
        let tracks: [URL] = ext == "iso" ? [game] : (ext == "cue" || ext == "gdi") ? Array(Converter.sourceFiles(for: game).dropFirst()) : []
        for t in tracks {
            let size = UInt64(totalSize([t]))
            var crc: UInt32?
            for e in entries {
                if let b = e.bps, b.size == size {
                    if crc == nil { crc = Patcher.crc32(of: t) }
                    if crc == b.crc { return e }
                }
                if let p = e.ppfBlock, Patcher.ppfBlockMatches(t, p.bytes, at: p.offset) { return e }
            }
        }
        let title = titleKey(game)
        guard title.count >= 5 else { return nil }   // too short to match by name safely
        let named = entries.filter { ($0.format == .xdelta || $0.format == .ips) && $0.key.contains(title) }
        return named.first { Patcher.tag(for: ($0.name as NSString).deletingPathExtension) == prefer } ?? named.first
    }
}
