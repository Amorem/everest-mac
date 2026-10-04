import Foundation
import IOKit.hid

/// Raw keyboard-interface dump — used to see exactly which HID usages the
/// keyboard sends for the UK ISO keys that macOS mis-handles.
enum Keys {
    static let usageNames: [UInt8: String] = [
        0x04: "a", 0x05: "b", 0x06: "c", 0x07: "d", 0x08: "e", 0x09: "f", 0x0A: "g",
        0x0B: "h", 0x0C: "i", 0x0D: "j", 0x0E: "k", 0x0F: "l", 0x10: "m", 0x11: "n",
        0x12: "o", 0x13: "p", 0x14: "q", 0x15: "r", 0x16: "s", 0x17: "t", 0x18: "u",
        0x19: "v", 0x1A: "w", 0x1B: "x", 0x1C: "y", 0x1D: "z",
        0x1E: "1", 0x1F: "2", 0x20: "3", 0x21: "4", 0x22: "5", 0x23: "6", 0x24: "7",
        0x25: "8", 0x26: "9", 0x27: "0", 0x28: "return", 0x29: "escape", 0x2A: "delete",
        0x2B: "tab", 0x2C: "space", 0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\| (ANSI)",
        0x32: "#~ (ISO right)", 0x33: ";", 0x34: "'", 0x35: "`¬", 0x36: ",", 0x37: ".", 0x38: "/",
        0x39: "capslock", 0x64: "\\| (ISO extra key, left of Z)",
        0xE0: "leftctrl", 0xE1: "leftshift", 0xE2: "leftalt", 0xE3: "leftgui",
        0xE4: "rightctrl", 0xE5: "rightshift", 0xE6: "rightalt", 0xE7: "rightgui",
    ]

    static func dump(_ args: [String]) {
        let seconds = args.first.flatMap(Double.init) ?? 20
        let transport: Transport
        do {
            transport = try Transport(usagePage: 0x01, usage: 0x06)
        } catch {
            fail("""
            Cannot open the keyboard interface: \(error)

            If macOS asked for Input Monitoring permission, grant it in
            System Settings > Privacy & Security > Input Monitoring and rerun.
            """)
        }
        defer { transport.close() }
        stderr("Dumping keyboard reports for \(Int(seconds))s.")
        stderr("Press, in order: the ISO key left of Z (\\ |), the key right of ; (should be '), shift+2, shift+3, then any letter.")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let p = transport.read(timeout: 0.2) {
                describe(p)
            }
        }
    }

    private static func describe(_ p: [UInt8]) {
        // Boot-style reports: [modifiers, reserved, key...]. Report IDs, when
        // present, sit in byte 0 and shift everything by one.
        var body = p
        if p.count >= 9, p[0] == 0x01 { body = Array(p.dropFirst()) }
        let mods = body.count > 0 ? body[0] : 0
        let keys = body.count > 2 ? Array(body[2...]) : []
        var names: [String] = []
        var bits = mods
        let modNames = ["lctrl", "lshift", "lalt", "lgui", "rctrl", "rshift", "ralt", "rgui"]
        for i in 0..<8 where bits & 1 == 1 { names.append(modNames[i]); bits >>= 1; if bits == 0 { break } }
        for k in keys where k != 0 {
            names.append(usageNames[k] ?? String(format: "usage 0x%02x", k))
        }
        if !names.isEmpty {
            let hex = p.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("keys: \(names.joined(separator: " + "))   [\(hex)]")
        }
    }
}
