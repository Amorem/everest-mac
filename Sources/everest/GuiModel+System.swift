import AppKit
import SwiftUI

// The button daemon, recovery and launch at login.
extension EverestModel {
    // MARK: - Daemon & recovery

    /// Start or stop the D1–D4 listener, and remember the choice: while it is
    /// on, the app starts it at launch and restarts it if it ever dies.
    func toggleDaemon() {
        config.daemonEnabled = daemonProcess == nil
        persist()
        if config.daemonEnabled { startDaemon() } else { stopDaemon() }
    }


    func startDaemon() {
        guard daemonProcess == nil else { return }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["listen", "--no-prompt"]
        // Keep the daemon's output: it says which key fired what, and warns
        // when macOS refuses to post key events.
        let logURL = Config.directory.appendingPathComponent("daemon.log")
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 512_000 {
            try? FileManager.default.removeItem(at: logURL)   // keep it small
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.daemonProcess === proc else { return }
                self.daemonProcess = nil
                self.daemonRunning = false
                // Unexpected end: bring it back unless the user switched it off.
                if self.config.daemonEnabled && !self.quitting {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.config.daemonEnabled, !self.quitting else { return }
                        self.startDaemon()
                    }
                }
            }
        }
        do {
            try p.run()
            daemonProcess = p
            daemonRunning = true
            report(tr("status.daemonOn"))
        } catch {
            report(tr("status.daemonStartFailed", error.localizedDescription), error: true)
        }
    }

    func stopDaemon() {
        let p = daemonProcess
        daemonProcess = nil
        daemonRunning = false
        p?.terminate()
        report(tr("status.daemonOff"))
    }

    // MARK: - Launch at login


    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginItemNote = LoginItem.status == .requiresApproval
                ? tr("status.loginApproval") : nil
        } catch {
            loginItemNote = tr("status.changeFailed", error.localizedDescription)
        }
        launchAtLogin = LoginItem.enabled
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func recover() {
        runDevice(tr("status.recovering")) { kb in
            kb.recover()
            return tr("status.recoverySent")
        }
    }

    func clearFlashActions() {
        runDevice(tr("status.cleaning")) { kb in
            kb.neutraliseKeyActions()
            return tr("status.leftoversCleared")
        }
    }
}
