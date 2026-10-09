import AppKit
import SwiftUI

// Talking to the keyboard: sessions, status refresh, layout, language.
extension EverestModel {
    // MARK: - Device access

    /// Run a short device session on the serial device queue.
    func runDevice(_ label: String, _ body: @escaping (Keyboard) -> String?) {
        report("\(label)…")
        device.async { [weak self] in
            guard let kb = try? Keyboard() else {
                DispatchQueue.main.async {
                    self?.connected = false
                    self?.report(tr("device.keyboardUnavailable"), error: true)
                }
                return
            }
            defer { kb.close() }
            kb.wake()
            let message = body(kb)
            DispatchQueue.main.async {
                if let message { self?.report(message) }
                self?.refreshDevice()
            }
        }
    }

    func refreshDevice() {
        device.async { [weak self] in
            // Read-only open: the firmware check below decides whether
            // anything else may talk to the keyboard.
            guard let kb = try? Keyboard(allowUnsupported: true) else {
                DispatchQueue.main.async {
                    self?.connected = false
                    self?.firmwareBlock = nil
                    self?.attached = tr("device.notConnected")
                }
                return
            }
            let version = kb.firmwareVersion
            // FWInfo.fwVer is BCD-like: 0x57 is firmware 57, 0x39 is 39.
            let fw = version.map { String(format: "%x", $0) } ?? "—"
            if let block = FirmwareBlock(version: version) {
                kb.close()
                DispatchQueue.main.async {
                    guard let self, self.confirmBlock(block) else { return }
                    self.connected = true
                    self.firmware = fw
                    self.attached = tr("device.blocked")
                    self.firmwareBlock = block
                    self.enforceFirmwareBlock()
                }
                return
            }
            let layoutCode = kb.layoutCode
            let state = kb.state()
            kb.close()
            var mode = "—"
            if let s = state {
                mode = Proto.MainMode.allCases.first(where: { $0.menuByte == s.modeByte })?.rawValue ?? "?"
            }
            let summary: String = {
                guard let s = state else { return tr("device.everestMax") }
                switch (s.mmDockPlugged, s.numpadPlugged) {
                case (true, true): return tr("device.full")
                case (true, false): return tr("device.withDock")
                case (false, true): return tr("device.withNumpad")
                case (false, false): return tr("device.core")
                }
            }()
            DispatchQueue.main.async {
                self?.connected = true
                self?.attached = summary
                if let code = layoutCode {
                    let detected = KeyboardLayout(firmwareCode: code)
                    if self?.detectedLayout != detected {
                        self?.detectedLayout = detected
                        self?.config.lastLayout = detected
                        self?.persist()
                    }
                    self?.applyLayout()
                }
                self?.dialMode = mode
                self?.firmware = fw
                self?.firmwareBlock = nil
                if Proto.MainMode(rawValue: mode) != nil { self?.config.mainDisplayMode = mode }
            }
        }
    }

    // MARK: - Layout

    /// Make the drawing and the effects follow the current layout.
    func applyLayout() {
        objectWillChange.send()
        LedLayout.use(layout)
    }

    /// Force a layout, or nil to follow the keyboard.
    func setLayoutOverride(_ l: KeyboardLayout?) {
        config.layoutOverride = l
        persist()
        applyLayout()
        report(l.map { tr("status.layoutForced", $0.title) } ?? tr("status.layoutAuto"))
    }

    // MARK: - Language

    /// The language the user picked, nil = follow the system.
    var language: Language? { config.language.flatMap { Language(rawValue: $0) } }

    /// Switch the interface language now: the views are rebuilt (see
    /// `RootView`), the menu-bar menu is rebuilt each time it opens, and the
    /// status line is reset so no stale message stays in the old language.
    func setLanguage(_ language: Language?) {
        L10n.use(language)
        config.language = language?.rawValue
        persist()
        if firmwareBlock != nil { enforceFirmwareBlock() } else { report(tr("status.ready")) }
        refreshDevice()
    }
}
