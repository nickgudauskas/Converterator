// Converterator — Check for Updates and Install and Relaunch.
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CryptoKit

// MARK: - Updates

/// Checks the GitHub "latest release" for a newer version and offers to open its download page.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repo = "thepoisonninja/Converterator"
    nonisolated static let bundleID = "local.converterator"

    @Published var isChecking = false
    /// "Downloading update…" etc. while an update installs, nil otherwise.
    @Published var installStatus: String?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when version `a` is newer than `b`, comparing numerically ("1.10" > "1.9"). A leading "v" is ignored.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespaces)
                .drop(while: { $0 == "v" || $0 == "V" })
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let html_url: String
        let assets: [Asset]?
    }

    func check() {
        guard !isChecking, installStatus == nil else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = String(release.tag_name.drop(while: { $0 == "v" || $0 == "V" }))

                guard Self.isNewer(latest, than: currentVersion) else {
                    show(title: "You're up to date",
                         message: "Converterator \(currentVersion) is the latest version.", buttons: ["OK"])
                    return
                }
                // Only ever open or download this repo's own release files.
                let prefix = "https://github.com/\(Self.repo)/"
                let page = URL(string: release.html_url).filter { $0.absoluteString.hasPrefix(prefix) }
                    ?? URL(string: "https://github.com/\(Self.repo)/releases/latest")!
                let zip = release.assets?.first { $0.name == "Converterator.zip" }
                    .flatMap { URL(string: $0.browser_download_url) }
                    .filter { $0.absoluteString.hasPrefix(prefix + "releases/download/") }

                let blocker = installBlocker(hasZip: zip != nil)
                var message = "You have version \(currentVersion)."
                if let blocker {
                    message += " Download the new version from GitHub, then replace the app in your Applications folder.\n\n(\(blocker))"
                    show(title: "Converterator \(latest) is available", message: message,
                         buttons: ["Download", "Later"]) { if $0 == 0 { NSWorkspace.shared.open(page) } }
                } else {
                    message += " Converterator can download and install it now, then reopen itself. Your settings are kept."
                    show(title: "Converterator \(latest) is available", message: message,
                         buttons: ["Install and Relaunch", "Later", "View Release Notes"]) { choice in
                        if choice == 0, let zip { self.install(from: zip, version: latest, releasePage: page) }
                        if choice == 2 { NSWorkspace.shared.open(page) }
                    }
                }
            } catch {
                show(title: "Couldn't check for updates",
                     message: "GitHub couldn't be reached. Check your internet connection and try again.\n\n(\(error.localizedDescription))",
                     buttons: ["OK"])
            }
        }
    }

    /// Why this copy can't update itself, or nil if it can.
    private func installBlocker(hasZip: Bool) -> String? {
        if Converter.shared.isRunning { return "A batch is converting. To install from inside the app, check again when it's finished." }
        if !hasZip { return "This release has no Converterator.zip to install automatically." }
        if Self.teamID(ofCodeAt: Bundle.main.bundleURL) == nil {
            return "This copy wasn't downloaded from GitHub (it isn't signed with a Developer ID), so it can't update itself."
        }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: parent.path) {
            return "Converterator can't write to \(parent.path(percentEncoded: false))."
        }
        if Bundle.main.bundleURL.path.contains("/AppTranslocation/") {
            return "Move Converterator to your Applications folder first."
        }
        return nil
    }

    private func install(from zip: URL, version: String, releasePage: URL) {
        installStatus = "Downloading update…"
        Task {
            do {
                let (file, response) = try await URLSession.shared.download(from: zip)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub returned an error.") }
                installStatus = "Installing update…"
                let app = Bundle.main.bundleURL
                guard let team = Self.teamID(ofCodeAt: app) else { throw UpdateError("This copy isn't signed with a Developer ID.") }
                try await Task.detached {
                    try UpdateChecker.installUpdate(zip: file, expectedVersion: version, teamID: team, replacing: app)
                }.value
                Self.relaunch(app)
            } catch {
                installStatus = nil
                show(title: "Couldn't install the update",
                     message: "\(error.localizedDescription)\n\nYou can download it from GitHub instead. Nothing was changed.",
                     buttons: ["Download", "Cancel"]) { if $0 == 0 { NSWorkspace.shared.open(releasePage) } }
            }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Unpacks the downloaded zip, checks the app inside, and swaps it in for the app at `target`.
    /// The new app must have the same bundle ID, the expected version, a valid signature from the same
    /// Developer ID team as this copy, and Gatekeeper's approval (notarized). Throws without touching
    /// `target` if anything doesn't match.
    nonisolated static func installUpdate(zip: URL, expectedVersion: String, teamID: String, replacing target: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("converterator-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        guard runTool("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else { throw UpdateError("The download couldn't be unzipped.") }
        let new = work.appendingPathComponent("Converterator.app")
        guard let info = NSDictionary(contentsOf: new.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError("The download doesn't contain Converterator.") }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateError("The download is a different version than expected.")
        }
        guard validSignature(new, teamID: teamID) else {
            throw UpdateError("The download isn't signed by the same developer as this copy, so it wasn't installed.")
        }
        guard runTool("/usr/sbin/spctl", ["--assess", "--type", "execute", new.path]) == 0 else {
            throw UpdateError("macOS Gatekeeper didn't approve the download, so it wasn't installed.")
        }

        // Copy next to the current app first (same volume), then swap it in.
        let staged = target.deletingLastPathComponent().appendingPathComponent(".Converterator-update-\(UUID().uuidString).app")
        guard runTool("/usr/bin/ditto", [new.path, staged.path]) == 0 else {
            try? fm.removeItem(at: staged)
            throw UpdateError("The new version couldn't be copied next to the current one.")
        }
        do {
            _ = try fm.replaceItemAt(target, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// Checks the code signature of every architecture and nested executable, and that it's a
    /// Developer ID signature for this app from the given team.
    nonisolated static func validSignature(_ app: URL, teamID: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let safeTeam = teamID.filter { $0.isLetter || $0.isNumber }
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(safeTeam)\""
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    /// The Developer ID team that signed the code at `url`, or nil (ad-hoc or unsigned).
    nonisolated static func teamID(ofCodeAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated static func runTool(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Quits, and reopens the app once this process has exited.
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Shows an alert as a sheet on the main window. `onChoice` gets the index of the button clicked.
    private func show(title: String, message: String, buttons: [String], onChoice: ((Int) -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        for b in buttons { alert.addButton(withTitle: b) }
        let handle: (NSApplication.ModalResponse) -> Void = { onChoice?($0.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        // Attach to the window as a sheet so it can't get lost behind other windows.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
