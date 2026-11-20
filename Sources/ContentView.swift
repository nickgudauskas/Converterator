// Converterator — The main window.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - UI

extension Notification.Name {
    /// Menu commands that need the window: open the file picker, confirm a stop, show the log.
    static let addFiles = Notification.Name("ConverteratorAddFiles")
    static let stopConverting = Notification.Name("ConverteratorStopConverting")
    static let toggleLog = Notification.Name("ConverteratorToggleLog")
    static let startConverting = Notification.Name("ConverteratorStartConverting")
}

struct ContentView: View {
    @ObservedObject private var c = Converter.shared
    @ObservedObject private var updater = UpdateChecker.shared
    @ObservedObject private var watch = WatchFolder.shared
    @State private var dropTargeted = false
    @State private var patchTargeted = false
    @State private var showLog = false
    @State private var confirmCancel = false
    @State private var selection = Set<UUID>()
    @State private var confirmSpace = false
    @State private var spaceWarning = ""

    var body: some View {
        VStack(spacing: 0) {
            if !c.toolsReady { missingToolsBanner }
            if c.restoredCount > 0 && !c.isRunning { restoredBanner }

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

            patchBox.padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 10)

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
        .alert("There may not be enough free space", isPresented: $confirmSpace) {
            Button("Convert Anyway") { c.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(spaceWarning)
        }
        .alert("Stop converting?", isPresented: $confirmCancel) {
            Button("Stop Converting", role: .destructive) {
                if c.isRunning || c.isPaused { c.cancel() }   // the batch may have finished while the dialog was open
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
            if c.isRunning || c.isPaused { confirmCancel = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startConverting)) { _ in startConverting() }
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
        } else if c.isPaused {
            status = "Paused: \(finished) of \(total) done"
            timeText = "Click Resume to carry on with the rest."
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
        // Scrolls rather than overlapping when the window is short; centred when there's room.
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "opticaldisc").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("Drop disc images or folders here").font(.title3)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                        if c.outputFormat == .pbp {
                            formatRow("PlayStation discs", "BIN/CUE, ISO, ECM, CHD", "PBP")
                        } else if c.outputFormat == .cso {
                            formatRow("PSP games", "ISO, CHD", "CSO")
                            formatRow("PS2 games", "ISO, DVD CHD", "ZSO (for OPL)")
                        } else {
                            formatRow("CD and DVD images", "BIN/CUE, GDI, ISO, ECM", "CHD")
                            formatRow("GameCube and Wii", "ISO, GCM, WBFS, CISO, GCZ, WIA", "RVZ")
                            formatRow("PS1 Classics", "PBP", "CHD")
                        }
                        formatRow("Archives", "ZIP, 7Z, RAR", "unpacked, then converted")
                        if c.outputFormat == .chd {
                            formatRow("Back again", "CHD, RVZ", "BIN/CUE, GDI or ISO")
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 12).padding(.horizontal, 16)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
    }

    /// Where translation and other patches go: each is given to the game it was made for.
    private var patchBox: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bandage").font(.title2).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                if c.addedPatches.isEmpty {
                    Text("Translations and patches").font(.headline)
                    Text("Drop IPS, BPS, PPF or xdelta patches here, or the zips they came in. Each one goes to the game it was made for.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        Text(c.addedPatches.count == 1 ? "1 patch" : "\(c.addedPatches.count) patches").font(.headline)
                        if c.matchingPatches { ProgressView().controlSize(.small) }
                    }
                    ForEach(c.addedPatches.prefix(3), id: \.self) { p in
                        let games = c.gamesPatched(by: p)
                        HStack(spacing: 4) {
                            Text(p.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            if games.isEmpty {
                                Text(c.matchingPatches ? "looking for its game…" : "no game matched yet").foregroundStyle(.secondary)
                            } else {
                                Text(games.map(\.url.lastPathComponent).joined(separator: ", "))
                                    .foregroundStyle(Color.accentColor).lineLimit(1).truncationMode(.middle)
                            }
                            Button { c.removeAddedPatch(p) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Remove this patch")
                        }
                        .font(.caption)
                    }
                    if c.addedPatches.count > 3 {
                        Text("and \(c.addedPatches.count - 3) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Button("Add Patches…", action: pickPatches)
                if c.addedPatches.count > 1 {
                    Button("Remove All") { c.clearAddedPatches() }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(patchTargeted ? 0.15 : 0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(patchTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: patchTargeted ? 2 : 1, dash: [5, 4]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            c.addPatches(urls); return true
        } isTargeted: { patchTargeted = $0 }
    }

    /// One line of the drop prompt: "CD and DVD images   BIN/CUE, GDI, ISO, ECM  →  CHD".
    private func formatRow(_ kind: String, _ formats: String, _ result: String) -> some View {
        GridRow {
            Text(kind).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(formats)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Text(result).fontWeight(.medium)
        }
    }

    private var jobList: some View {
        List(selection: $selection) {
            ForEach(c.jobs) { job in
                HStack(spacing: 10) {
                    icon(for: job).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        if let patch = job.patch, let name = job.patchedName {
                            let first = job.patchMember.map { "\(patch.lastPathComponent) → \(($0 as NSString).lastPathComponent)" } ?? patch.lastPathComponent
                            let what = ([first] + job.morePatches.map(\.lastPathComponent)).joined(separator: ", then ")
                            Label("\(job.patchFromFolder ? "Patch from your patches folder" : job.morePatches.isEmpty ? "Patch" : "Patches"): \(what) → \(name).\(c.outputFormat == .pbp ? "pbp" : c.outputFormat == .cso ? "cso/zso" : Converter.isNintendoDisc(job.url) ? "rvz" : "chd")",
                                  systemImage: "bandage")
                                .font(.caption).foregroundStyle(Color.accentColor)
                                .lineLimit(1).truncationMode(.middle)
                        }
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
                    Divider()
                    // (On a .chd, a patch makes a new, patched CHD instead of extracting it.)
                    Button(job.patch == nil ? "Add Patch…" : "Change Patch…") { pickPatch(for: job) }
                        .disabled(job.state == .working)
                    if job.patch != nil {
                        Button("Add Another Patch…") { pickPatch(for: job, adding: true) }
                            .disabled(job.state == .working)
                        Button(job.morePatches.isEmpty ? "Remove Patch" : "Remove Patches") { c.setPatch(nil, for: job.id) }
                            .disabled(job.state == .working)
                    }
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
            HStack(spacing: 12) {
                Toggle("Sort into a folder per system", isOn: $c.organizeBySystem)
                    .fixedSize()
                    .disabled(c.outputFormat == .pbp)
                    .help("Saves each game in a folder named for its console, such as PlayStation/ or Saturn/ (or psx/, saturn/: choose the style in Settings). The console comes from the game's Redump match, or from the disc itself.")
                Spacer()
                Text("Copy to:")
                    .help("Copies each finished game to a folder, such as an SD card or a Steam Deck share. Games already there are skipped.")
                Text(c.copyDestination.map { DiskSpace.volumeName($0) == $0.lastPathComponent ? $0.lastPathComponent : "\(DiskSpace.volumeName($0)) › \($0.lastPathComponent)" } ?? "Off")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(c.copyDestination?.path(percentEncoded: false) ?? "Copies each finished game to a folder, such as an SD card or a Steam Deck share.")
                Button(c.copyDestination == nil ? "Choose…" : "Change…", action: pickCopyDestination)
                if c.copyDestination != nil {
                    Button { c.copyDestination = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Stop copying")
                }
            }
            HStack(spacing: 20) {
                Picker("Make:", selection: $c.outputFormat) {
                    ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                .help("PBP makes PlayStation games for a PSP or PS Vita (PlayStation games only). Discs of one game go into one PBP.")
                if c.outputFormat == .cso {
                    Picker("Format:", selection: $c.csoFormat) {
                        ForEach(CSOFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    .help("A PSP with custom firmware reads CSO; Open PS2 Loader reads ZSO. Made from ISO images (and DVD CHDs, unpacked first).")
                }
                if c.outputFormat == .pbp {
                    Toggle("Put each in its own folder as EBOOT.PBP (for a PSP)", isOn: $c.pbpFolders)
                        .help("A PSP finds PlayStation games as PSP/GAME/<folder>/EBOOT.PBP. Copy the folders to PSP/GAME on the memory stick.")
                }
            }
            HStack(spacing: 20) {
                Toggle(c.outputFormat == .pbp ? "Overwrite existing PBPs" : c.outputFormat == .cso ? "Overwrite existing CSOs/ZSOs" : "Overwrite existing CHDs", isOn: $c.overwrite)
                Toggle("Make .m3u playlist for multi-disc games", isOn: $c.makeM3U)
                    .disabled(c.outputFormat != .chd)
            }
            HStack(spacing: 20) {
                Toggle(c.outputFormat == .cso ? "Verify after writing" : "Verify CHDs after writing", isOn: $c.verify)
                    .disabled(c.outputFormat == .pbp)
                    .help("Checks each CHD's checksums with chdman verify. CHDs that already exist are checked too, so you can re-add a folder to test it.")
                Picker("ISO images:", selection: $c.isoMode) {
                    ForEach(ISOMode.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                .help("Automatic makes a DVD CHD for PS2 and PSP games and anything bigger than a CD, and a CD CHD otherwise.")
                .disabled(c.outputFormat != .chd)
            }
            Toggle("Move source files to Trash after a successful conversion", isOn: $c.trashSources)
                .disabled(c.outputFormat != .chd)   // making PBPs, CSOs and ZSOs never moves the originals
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
                if watch.isWatching, let f = watch.folder {
                    Label("Watching “\(f.lastPathComponent)”", systemImage: "eye")
                        .foregroundStyle(.secondary)
                        .help("New games that arrive in \(f.path(percentEncoded: false)) are added\(watch.autoStart ? " and converted" : ""). Change this in Settings.")
                }
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
                Menu("Pause") {
                    Button("Pause After This File") { c.pause() }
                    Button("Pause Now") { c.pause(now: true) }
                } primaryAction: {
                    c.pause()
                }
                .fixedSize()
                .help("Pause after the current file. Pause Now stops it straight away, and it starts again from the beginning when you resume.")
                Button("Cancel", role: .cancel) { confirmCancel = true }
            } else if c.isPaused {
                Button("Cancel", role: .cancel) { confirmCancel = true }
                Button("Resume", action: startConverting)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!c.toolsReady)
            } else {
                Button("Convert", action: startConverting)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!c.toolsReady || !c.hasQueued)
            }
        }
    }

    /// Starts (or resumes), first warning if the waiting files may not fit on their disks.
    private func startConverting() {
        guard !c.isRunning, c.toolsReady, c.hasQueued else { return }
        c.restoredCount = 0
        if !c.isPaused, let warning = c.batchSpaceWarning() {
            spaceWarning = warning
            confirmSpace = true
        } else {
            c.start()
        }
    }

    /// Shown at launch when files were waiting in the list last time the app closed.
    private var restoredBanner: some View {
        HStack {
            Label("Picked up where you left off: \(c.restoredCount) file\(c.restoredCount == 1 ? "" : "s") still to convert. Click Convert to carry on.",
                  systemImage: "arrow.clockwise.circle")
            Spacer()
            Button("Dismiss") { c.restoredCount = 0 }
        }
        .font(.callout)
        .padding(10)
        .background(Color.accentColor.opacity(0.10))
    }

    /// Removes rows from the list (never the one converting), and drops them from the selection.
    private func removeFromList(_ ids: Set<UUID>) {
        for id in ids { c.remove(id) }
        selection.subtract(ids)
    }

    /// Chooses a patch (IPS, BPS, PPF or xdelta) to apply to one file before it's compressed.
    private func pickPatch(for job: Job, adding: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = (Array(PatchFormat.byExtension.keys) + ["zip"]).compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = job.url.deletingLastPathComponent()
        panel.message = "Choose a patch for \(job.url.lastPathComponent) (IPS, BPS, PPF or xdelta, or the .zip it came in)."
        if adding { panel.message = "Choose a patch to apply after \(([job.patch?.lastPathComponent].compactMap { $0 } + job.morePatches.map(\.lastPathComponent)).joined(separator: ", "))" }
        present(panel) { if let url = panel.url { adding ? c.addPatch(url, for: job.id) : c.setPatch(url, for: job.id) } }
    }

    private func pickCopyDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose where finished games are copied, such as a folder on an SD card. Games already there are skipped."
        present(panel) { if let url = panel.url { c.copyDestination = url } }
    }

    private func pickPatches() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = (Array(PatchFormat.byExtension.keys) + ["zip"]).compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.message = "Choose IPS, BPS, PPF or xdelta patches, the zips they came in, or folders of them. Each one goes to the game it was made for."
        present(panel) { c.addPatches(panel.urls) }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ["pbp", "cue", "gdi", "iso", "bin", "ecm", "chd", "zip", "7z", "rar", "gcm", "wbfs", "ciso", "gcz", "wia", "rvz", "xdelta", "vcdiff", "ppf", "bps", "ips"].compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.message = "Choose .pbp, .cue, .gdi, .iso, .ecm, .zip, .7z or .rar files or folders to compress, or .chd files to extract"
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
