// Converterator — GameCube and Wii discs: compressed to RVZ (Dolphin's format) with dolphin-tool.
import Foundation

extension Converter {
    /// GameCube/Wii-only formats. (.iso and .gcm are checked by their contents, since .iso is shared.)
    nonisolated static let nintendoOnlyExtensions: Set<String> = ["gcm", "wbfs", "ciso", "gcz", "wia"]

    /// Whether this is a GameCube or Wii disc, which becomes an .rvz instead of a .chd.
    /// A disc image says so in its header: the Wii magic number at 0x18, or GameCube's at 0x1C.
    nonisolated static func isNintendoDisc(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["wbfs", "ciso", "gcz", "wia", "rvz"].contains(ext) { return true }
        guard ext == "iso" || ext == "gcm", let h = try? FileHandle(forReadingFrom: url.resolvingSymlinksInPath()) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 0x20), d.count == 0x20 else { return false }
        let b = [UInt8](d)
        func be32(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
        return be32(0x18) == 0x5D1C9EA3 || be32(0x1C) == 0xC2339F3D
    }

    /// "GameCube" or "Wii", for messages.
    nonisolated static func nintendoSystem(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url.resolvingSymlinksInPath()), let d = try? h.read(upToCount: 0x1C), d.count == 0x1C else { return "GameCube or Wii" }
        try? h.close()
        let b = [UInt8](d)
        return (UInt32(b[0x18]) << 24 | UInt32(b[0x19]) << 16 | UInt32(b[0x1A]) << 8 | UInt32(b[0x1B])) == 0x5D1C9EA3 ? "Wii" : "GameCube"
    }

    /// Converts a GameCube/Wii disc with dolphin-tool: to RVZ (zstd level 5, 128 KiB blocks, as Dolphin
    /// recommends), or back to a plain ISO. Returns an error message, or nil.
    func dolphinConvert(_ input: URL, to out: URL, rvz: Bool) async -> String? {
        guard let dolphin = Converter.findTool("dolphin-tool") else {
            return "dolphin-tool is missing from the app, so GameCube and Wii discs can't be converted. Download Converterator again."
        }
        try? FileManager.default.removeItem(at: out)   // only reached when it's new or Overwrite is on
        let args = rvz ? ["convert", "-i", input.path, "-o", out.path, "-f", "rvz", "-c", "zstd", "-l", "5", "-b", "131072"]
                       : ["convert", "-i", input.path, "-o", out.path, "-f", "iso"]
        let (status, lines) = await ToolRun.run(dolphin, args, watchdog: false,
                                                started: { p in Task { @MainActor in self.setCurrentProcess(p) } }) { _ in }
        for l in lines { append("  [dolphin-tool] \(l)") }
        if cancelRequested { try? FileManager.default.removeItem(at: out); return "Cancelled" }
        guard status == 0, totalSize([out]) > 0 else {
            try? FileManager.default.removeItem(at: out)
            return "dolphin-tool couldn't convert it\(lines.last.map { " (\($0))" } ?? "") — see log"
        }
        return nil
    }

    /// Reads an RVZ (or other Dolphin format) through, checking it decompresses cleanly. Returns an error, or nil.
    func dolphinVerify(_ file: URL) async -> String? {
        guard let dolphin = Converter.findTool("dolphin-tool") else { return "dolphin-tool is missing from the app" }
        let (status, lines) = await ToolRun.run(dolphin, ["verify", "-i", file.path], watchdog: false,
                                                started: { p in Task { @MainActor in self.setCurrentProcess(p) } }) { _ in }
        for l in lines { append("  [dolphin-tool] \(l)") }
        return status == 0 ? nil : "\(file.lastPathComponent) failed verification — see log"
    }
}
