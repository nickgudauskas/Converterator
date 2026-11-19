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
}

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
