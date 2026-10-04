import Foundation

/// Physical key codes used by the firmware remap commands (§4 and §10 of the
/// protocol notes). They are matrix positions, not HID usages: the key below
/// ESC is 0x01, Tab is 0x10, Caps Lock 0x1E, Left Shift 0x2C, and on an ISO
/// keyboard the extra key between Left Shift and Z is 0x2D (Z becomes 0x2E).
enum KeyCodes {
    static let table: [String: UInt8] = [
        "`": 0x01, "grave": 0x01,
        "1": 0x02, "2": 0x03, "3": 0x04, "4": 0x05, "5": 0x06,
        "6": 0x07, "7": 0x08, "8": 0x09, "9": 0x0A, "0": 0x0B,
        "-": 0x0C, "minus": 0x0C, "=": 0x0D, "equal": 0x0D,
        "backspace": 0x0F, "tab": 0x10,
        "q": 0x11, "w": 0x12, "e": 0x13, "r": 0x14, "t": 0x15, "y": 0x16,
        "u": 0x17, "i": 0x18, "o": 0x19, "p": 0x1A,
        "[": 0x1B, "leftbracket": 0x1B, "]": 0x1C, "rightbracket": 0x1C,
        "\\": 0x1D, "backslash": 0x1D,
        "capslock": 0x1E, "caps": 0x1E,
        "a": 0x1F, "s": 0x20, "d": 0x21, "f": 0x22, "g": 0x23, "h": 0x24,
        "j": 0x25, "k": 0x26, "l": 0x27,
        ";": 0x28, "semicolon": 0x28, "'": 0x29, "quote": 0x29,
        "#": 0x2A, "hash": 0x2A,
        "enter": 0x2B, "return": 0x2B,
        "lshift": 0x2C, "leftshift": 0x2C, "shift": 0x2C,
        "iso": 0x2D, "iso-extra": 0x2D, "oem102": 0x2D,
        "z": 0x2E, "x": 0x2F, "c": 0x30, "v": 0x31, "b": 0x32, "n": 0x33, "m": 0x34,
        ",": 0x35, "comma": 0x35, ".": 0x36, "period": 0x36, "/": 0x37, "slash": 0x37,
        "rshift": 0x39, "rightshift": 0x39,
        "lctrl": 0x3A, "lcontrol": 0x3A, "ctrl": 0x3A, "control": 0x3A,
        "lgui": 0x3B, "lcmd": 0x3B, "lcommand": 0x3B, "super": 0x3B, "cmd": 0x3B,
        "lalt": 0x3C, "loption": 0x3C, "alt": 0x3C, "option": 0x3C,
        "space": 0x3D,
        "ralt": 0x3E, "roption": 0x3E,
        "rgui": 0x3F, "rcmd": 0x3F, "rcommand": 0x3F,
        "rctrl": 0x40, "rcontrol": 0x40,
        "insert": 0x4B, "delete": 0x4C,
        "left": 0x4F, "home": 0x50, "end": 0x51, "up": 0x53, "down": 0x54,
        "pgup": 0x55, "pageup": 0x55, "pgdn": 0x56, "pagedown": 0x56, "right": 0x59,
        "numlock": 0x5A,
        "kp1": 0x52, "kp4": 0x5C, "kp7": 0x5B, "kp8": 0x60, "kp5": 0x61, "kp2": 0x62,
        "kp0": 0x63, "kp*": 0x64, "kpmultiply": 0x64, "kp9": 0x65, "kp6": 0x66,
        "kp3": 0x67, "kp.": 0x68, "kpdecimal": 0x68, "kp-": 0x69, "kpminus": 0x69,
        "kp+": 0x6A, "kpplus": 0x6A,
    ]

    static func code(_ name: String) -> UInt8? {
        let key = name.lowercased()
        if key.hasPrefix("0x"), let v = UInt8(key.dropFirst(2), radix: 16) { return v }
        if let v = UInt8(key) { return v }   // raw decimal
        return table[key]
    }

    /// All names for a code, for `everest keycode <n>` style help.
    static func names(for code: UInt8) -> [String] {
        table.filter { $0.value == code }.map(\.key).sorted()
    }
}
