// Converterator — a small macOS front end for PSXPackager (PBP → BIN/CUE) and chdman (BIN/CUE → CHD).
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

struct Job: Identifiable {
    enum State { case queued, working, done, failed }
    let id = UUID()
    let url: URL
    var state: State = .queued
    var detail: String = "Waiting"
    var progress: Double? = nil
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

    let psxpackager: URL? = Converter.findTool("psxpackager")
    let chdman: URL? = Converter.findTool("chdman")

    private var currentProcess: Process?
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
    }

    var toolsReady: Bool { psxpackager != nil && chdman != nil }
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
        for root in ["/opt/homebrew/opt/dotnet/libexec", "/usr/local/opt/dotnet/libexec", "/usr/local/share/dotnet"]
        where FileManager.default.fileExists(atPath: root) {
            env["DOTNET_ROOT"] = env["DOTNET_ROOT"] ?? root
            break
        }
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        return env
    }()

    // MARK: Queue

    /// Inputs we accept. .pbp goes through PSXPackager first; the rest go straight to chdman.
    static let inputExtensions: Set<String> = ["pbp", "cue", "gdi", "iso"]

    func add(_ urls: [URL]) {
        let fm = FileManager.default
        var found: [URL] = []
        func consider(_ f: URL) {
            let ext = f.pathExtension.lowercased()
            if Converter.inputExtensions.contains(ext) {
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
                    if Converter.inputExtensions.contains(f.pathExtension.lowercased()) { found.append(f) }
                }
            } else {
                consider(url)
            }
        }
        let existing = Set(jobs.map { $0.url.standardizedFileURL })
        let new = found.map { $0.standardizedFileURL }
            .filter { !existing.contains($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        jobs += new.map { Job(url: $0) }
        if found.isEmpty && !urls.isEmpty { append("No .pbp, .cue, .gdi or .iso files found in what was added.") }
    }

    func clearFinished() { jobs.removeAll { $0.state == .done || $0.state == .failed } }
    func clearAll() { if !isRunning { jobs.removeAll() } }
    func remove(_ id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state != .working { jobs.remove(at: i) }
    }
    func retryFailed() {
        for i in jobs.indices where jobs[i].state == .failed {
            jobs[i].state = .queued; jobs[i].detail = "Waiting"; jobs[i].progress = nil
        }
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
        Task {
            while !cancelRequested, let i = jobs.firstIndex(where: { $0.state == .queued }) {
                await convert(index: i)
            }
            isRunning = false
            append(cancelRequested ? "— Cancelled —" : "— All done —")
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]) }
    }

    private func convert(index: Int) async {
        let job = jobs[index]
        let id = job.id
        let fm = FileManager.default
        let src = job.url
        let base = src.deletingPathExtension().lastPathComponent
        let outDir = outputDir ?? src.deletingLastPathComponent()
        let tmp = fm.temporaryDirectory.appendingPathComponent("pbp2chd-\(UUID().uuidString)", isDirectory: true)

        func fail(_ msg: String) {
            update(id) { $0.state = .failed; $0.detail = msg; $0.progress = nil }
            append("✗ \(src.lastPathComponent): \(msg)")
        }

        let isPBP = src.pathExtension.lowercased() == "pbp"
        update(id) { $0.state = .working; $0.detail = isPBP ? "Extracting BIN/CUE…" : "Starting…"; $0.progress = nil }
        append("▶ \(src.lastPathComponent)")

        do {
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            if isPBP { try fm.createDirectory(at: tmp, withIntermediateDirectories: true) }
        } catch { return fail("Can't create folder: \(error.localizedDescription)") }
        defer { if isPBP { try? fm.removeItem(at: tmp) } }

        // Step 1 (PBP only): PBP → BIN/CUE in a temp folder. CUE/GDI/ISO inputs go straight to chdman.
        var cues = [src]
        if isPBP {
            let s1 = await run(psxpackager!, ["-i", src.path, "-o", tmp.path, "-x", "-v", "2"]) { [weak self] line in
                self?.append("  [psxpackager] \(line)")
            }
            if cancelRequested { return fail("Cancelled") }
            cues = (fm.enumerator(at: tmp, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension.lowercased() == "cue" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard s1 == 0 || !cues.isEmpty else { return fail("PSXPackager failed (exit \(s1)) — see log") }
            guard !cues.isEmpty else { return fail("PSXPackager produced no .cue file — see log") }
        }

        // Step 2: BIN/CUE → CHD, one per disc
        var made: [URL] = []
        var allNewlyCreated = true   // false if any CHD was skipped because it already existed
        for (n, cue) in cues.enumerated() {
            let name = cues.count == 1 ? base : cue.deletingPathExtension().lastPathComponent
            let out = outDir.appendingPathComponent(name + ".chd")
            let label = cues.count == 1 ? "Compressing to CHD" : "Compressing disc \(n + 1) of \(cues.count)"

            if fm.fileExists(atPath: out.path) && !overwrite {
                append("  \(out.lastPathComponent) already exists — skipped (turn on Overwrite to replace)")
                made.append(out)
                allNewlyCreated = false
                continue
            }
            update(id) { $0.detail = label + "…"; $0.progress = 0 }

            var args = ["createcd", "-i", cue.path, "-o", out.path]
            if overwrite { args.append("-f") }
            let s2 = await run(chdman!, args) { [weak self] line in
                if let r = line.range(of: #"([0-9.]+)% complete"#, options: .regularExpression) {
                    let pct = Double(line[r].split(separator: "%")[0]) ?? 0
                    self?.update(id) { $0.progress = pct / 100; $0.detail = "\(label) — \(Int(pct))%" }
                } else {
                    self?.append("  [chdman] \(line)")
                }
            }
            if s2 != 0 || cancelRequested {
                try? fm.removeItem(at: out)
                return fail(cancelRequested ? "Cancelled" : "chdman failed (exit \(s2)) — see log")
            }
            made.append(out)
        }

        // Multi-disc playlist
        if made.count > 1 && makeM3U {
            let m3u = outDir.appendingPathComponent(base + ".m3u")
            let body = made.map { $0.lastPathComponent }.joined(separator: "\n") + "\n"
            do { try body.write(to: m3u, atomically: true, encoding: .utf8); append("  wrote \(m3u.lastPathComponent)") }
            catch { append("  couldn't write \(m3u.lastPathComponent): \(error.localizedDescription)") }
        }

        var summary = made.count == 1 ? made[0].lastPathComponent : "\(made.count) discs → CHD"

        // Optional: move the originals to the Trash, only when every CHD was freshly and fully written.
        if trashSources {
            let outputsOK = made.allSatisfy {
                ((try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0) > 0
            }
            if !allNewlyCreated {
                append("  Kept source files: a CHD already existed and wasn't rewritten.")
            } else if !outputsOK {
                append("  Kept source files: a CHD looks empty or missing.")
            } else {
                var trashed = 0
                for f in Converter.sourceFiles(for: src) {
                    do { try fm.trashItem(at: f, resultingItemURL: nil); trashed += 1 }
                    catch { append("  couldn't move \(f.lastPathComponent) to Trash: \(error.localizedDescription)") }
                }
                append("  moved \(trashed) source file\(trashed == 1 ? "" : "s") to Trash")
                summary += " · originals moved to Trash"
            }
        }

        update(id) { $0.state = .done; $0.detail = summary; $0.progress = nil }
        append("✓ \(summary)")
    }

    /// The input file plus any track files it references (for .cue and .gdi), limited to files that
    /// exist inside the input's own folder.
    nonisolated static func sourceFiles(for src: URL) -> [URL] {
        let dir = src.deletingLastPathComponent().standardizedFileURL
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

        var result = [src]
        var seen: Set<String> = [src.standardizedFileURL.path]
        for name in names {
            let f = dir.appendingPathComponent(name).standardizedFileURL
            guard f.path.hasPrefix(dir.path + "/"),
                  FileManager.default.fileExists(atPath: f.path),
                  seen.insert(f.path).inserted else { continue }
            result.append(f)
        }
        return result
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

// MARK: - UI

struct ContentView: View {
    @ObservedObject private var c = Converter.shared
    @State private var dropTargeted = false
    @State private var showLog = false

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
            bottomBar.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var missingToolsBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            if c.chdman == nil {
                Label("chdman not found. Install it in Terminal with:  brew install rom-tools", systemImage: "exclamationmark.triangle.fill")
            }
            if c.psxpackager == nil {
                Label("psxpackager not found inside the app or in /opt/homebrew/bin.", systemImage: "exclamationmark.triangle.fill")
            }
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private var dropPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "opticaldisc").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Drop .pbp, .cue, .gdi or .iso files (or folders) here").font(.title3)
            Text("BIN/CUE, GDI and ISO images are compressed straight to CHD. PBPs are unpacked to BIN/CUE first, and those temporary files are cleaned up.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Add Files…", action: pickFiles).padding(.top, 4)
        }
        .padding(30)
    }

    private var jobList: some View {
        List {
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
                    Button("Remove from List") { c.remove(job.id) }.disabled(job.state == .working)
                }
            }
        }
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
                Text("Save CHDs to:")
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
            Toggle("Move source files to Trash after a successful conversion", isOn: $c.trashSources)
                .help("Moves the .pbp/.cue/.gdi/.iso file and any .bin tracks it lists to the Trash, only after its CHD is written. Turns off each time the app starts.")
        }
        .disabled(c.isRunning)
    }

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
            if c.isRunning {
                Button("Cancel", role: .cancel, action: c.cancel)
            } else {
                Button("Convert", action: c.start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!c.toolsReady || !c.hasQueued)
            }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ["pbp", "cue", "gdi", "iso", "bin"].compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.message = "Choose .pbp, .cue, .gdi or .iso files, or folders containing them"
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
    }
}
