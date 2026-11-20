// Help → Copy Diagnostic Info / Report a Bug: what a bug report needs, ready to paste.
import AppKit

enum Diagnostics {
    /// The app and macOS versions, the Mac, the built-in tools, the settings that change what happens,
    /// the list and the recent log. Paths in your home folder are shortened to "~".
    @MainActor static func report(logLines: Int = 150) -> String {
        let c = Converter.shared, db = RedumpDB.shared, patches = PatchLibrary.shared
        var lines: [String] = []
        func on(_ b: Bool) -> String { b ? "on" : "off" }

        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown (not a release build)"
        lines.append("Converterator \(version)")
        lines.append("macOS " + ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: ""))
        let translated = sysctlInt("sysctl.proc_translated") == 1
        lines.append("Mac: \(sysctlString("hw.model") ?? "unknown"), \(Converter.arch == "arm64" ? "Apple Silicon" : "Intel")"
                     + (translated ? " (running under Rosetta)" : ""))
        lines.append("App: \(shorten(Bundle.main.bundleURL.path))")

        lines.append("")
        lines.append("Tools")
        for (label, name) in [("chdman", "chdman"), ("7-Zip", "7zz"), ("xdelta3", "xdelta3"),
                              ("dolphin-tool", "dolphin-tool"), ("PSXPackager", "psxpackager")] {
            lines.append("  \(label): \(describeTool(name))")
        }

        lines.append("")
        lines.append("Settings")
        lines.append("  Make: \(c.outputFormat.label)" + (c.outputFormat == .pbp ? " (EBOOT.PBP folders: \(on(c.pbpFolders)))" : ""))
        lines.append("  Save to: \(c.outputDir == nil ? "same folder as each source file" : "a chosen folder")")
        lines.append("  ISO images: \(c.isoMode.label); verify: \(on(c.verify)); overwrite: \(on(c.overwrite)); "
                     + ".m3u playlists: \(on(c.makeM3U)); move sources to Trash: \(on(c.trashSources))")
        lines.append("  Redump check: \(on(db.enabled)) (\(db.systems.count) system\(db.systems.count == 1 ? "" : "s"), "
                     + "rename: \(on(db.renameToRedump)), keep unmatched: \(on(db.keepUnmatched)), auto-download: \(on(db.autoDownload)))")
        lines.append("  Patches folder: \(patches.folder == nil ? "not set" : "set, \(patches.patchCount) patches, finding them \(on(patches.enabled))")")
        lines.append("  Patches box: \(c.addedPatches.count)")

        lines.append("")
        let counts = Dictionary(grouping: c.jobs, by: { "\($0.state)" }).mapValues(\.count)
        lines.append("List: \(c.jobs.count) file\(c.jobs.count == 1 ? "" : "s")"
                     + (counts.isEmpty ? "" : " (" + counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ") + ")"))
        for j in c.jobs.prefix(30) {
            lines.append("  \(j.url.lastPathComponent) — \(j.state): \(j.detail)")
        }

        lines.append("")
        let log = c.log.split(separator: "\n").suffix(logLines)
        lines.append(log.isEmpty ? "Recent log: empty" : "Recent log (last \(log.count) line\(log.count == 1 ? "" : "s"))")
        lines += log.map { "  " + $0 }
        return shorten(lines.joined(separator: "\n"))
    }

    /// "built in: chdman 0.289", or where else it was found, or "missing".
    nonisolated static func describeTool(_ name: String) -> String {
        guard let tool = Converter.findTool(name) else { return "missing" }
        let res = Bundle.main.resourceURL?.standardizedFileURL.path ?? "/nonexistent"
        let folder = tool.deletingLastPathComponent()
        let source = (try? String(contentsOf: folder.appendingPathComponent("SOURCE.txt"), encoding: .utf8))?
            .split(separator: "\n").first.map(String.init).map(versionPart)
        let what = source ?? name
        return tool.standardizedFileURL.path.hasPrefix(res + "/") ? "built in, \(what)" : "\(what) at \(shorten(tool.path))"
    }

    /// The name-and-version start of a SOURCE.txt line: "chdman 0.289, built from…" → "chdman 0.289".
    nonisolated static func versionPart(_ line: String) -> String {
        var s = line
        for stop in [",", ":", " (", " by "] {
            if let r = s.range(of: stop) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func shorten(_ text: String) -> String {
        text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    /// Copies the report and says so.
    @MainActor static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
        let a = NSAlert()
        a.messageText = "Diagnostic info copied"
        a.informativeText = "Paste it into a bug report. It has your Converterator and macOS versions, your Mac, the built-in tools, your settings, the list and the recent log, with your home folder shortened to “~”. File names in the list and log are included, so look it over before sharing."
        a.runModal()
    }

    /// Copies the report and opens GitHub's bug report form.
    @MainActor static func reportBug() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(), forType: .string)
        let a = NSAlert()
        a.messageText = "Report a bug on GitHub"
        a.informativeText = "The diagnostic info is copied. Paste it into the “Diagnostic info” box of the form that opens (look it over first: file names in the list and log are included). You need a free GitHub account to send it."
        a.addButton(withTitle: "Open the Form")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://github.com/\(UpdateChecker.repo)/issues/new?template=bug_report.yml") {
            NSWorkspace.shared.open(url)
        }
    }
}
