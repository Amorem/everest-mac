import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Executes button actions: shell commands, URLs, apps, key combos, text.
enum ActionRunner {
    static func run(_ spec: ButtonAction) {
        switch spec.type {
        case "shell":
            runShell(spec.value)
        case "url":
            openURL(spec.value)
        case "open":
            openPath(spec.value)
        case "app":
            openApp(spec.value)
        case "keypress":
            sendKeys(spec.value)
        case "text":
            typeText(spec.value)
        case "none", "":
            break
        default:
            stderr("unknown action type '\(spec.type)'")
        }
    }

    static func runShell(_ command: String) {
        guard !command.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { stderr("shell action failed: \(error)") }
    }

    static func openURL(_ s: String) {
        guard let url = URL(string: s) else { stderr("invalid URL '\(s)'"); return }
        NSWorkspace.shared.open(url)
    }

    static func openPath(_ s: String) {
        let url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        NSWorkspace.shared.open(url)
    }

    /// Launch an app, or bring it to the front with its windows if it is
    /// already running — what `open -a` does, and it works from the
    /// background daemon too (activation goes through LaunchServices).
    static func openApp(_ path: String) {
        let p = (path as NSString).expandingTildeInPath
        guard !p.isEmpty else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", p]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { stderr("app action failed: \(error)") }
    }

    // MARK: - Key simulation

    /// True when this process may post synthetic events. Without it macOS
    /// silently drops everything sent by `sendKeys`/`typeText`.
    static func accessibilityGranted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "cmd": 55, "command": 55, "shift": 56, "capslock": 57, "option": 58, "alt": 58,
        "control": 59, "ctrl": 59, "rightshift": 60, "rightoption": 61, "rightcontrol": 62,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    /// Consumer-control keys (volume etc.) posted as system-defined events.
    private static let mediaKeys: [String: Int] = [
        "volup": 0, "voldown": 1, "mute": 7,
        "playpause": 16, "play": 16, "next": 17, "nexttrack": 17, "prev": 18, "prevtrack": 18,
    ]

    static func sendKeys(_ combo: String) {
        let parts = combo.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map(String.init)
        guard !parts.isEmpty else { return }

        if parts.count == 1, let id = mediaKeys[parts[0]] {
            postMediaKey(id)
            return
        }

        var flags: CGEventFlags = []
        var keyName: String?
        for part in parts {
            switch part {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "fn": flags.insert(.maskSecondaryFn)
            default: keyName = part
            }
        }
        guard let name = keyName, let code = keyCodes[name] else {
            stderr("keypress: unknown key '\(keyName ?? combo)'")
            return
        }
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        up?.post(tap: .cghidEventTap)
    }

    static func postMediaKey(_ id: Int) {
        let flags = 0xA00
        for isDown in [true, false] {
            let data1 = (id << 16) | (flags << 8) | (isDown ? 0x0A : 0x0B)
            guard let ev = NSEvent.otherEvent(with: .systemDefined,
                                              location: .zero,
                                              modifierFlags: [],
                                              timestamp: 0,
                                              windowNumber: 0,
                                              context: nil,
                                              subtype: 8,
                                              data1: data1,
                                              data2: -1) else { continue }
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static func typeText(_ text: String) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
