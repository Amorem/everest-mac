import Carbon.HIToolbox
import Foundation

/// UK / ISO keyboard fixes for macOS.
///
/// A UK PC keyboard (which the Everest Max ISO is) prints `\ |` on the extra
/// key left of Z, `' @` on the key right of `;`, and `" £` on shift+2/3.
/// macOS defaults to its own "British" layout, which puts `@` on shift+2 and
/// `"` on the quote key — so the tool pushes `British-PC` instead, and can
/// fall back to a hidutil usage remap when the OS refuses to deliver the ISO
/// key at all.
enum Layout {
    static func inspect() {
        print("Input sources (keyboard layouts):")
        let layouts = inputSources().filter { $0.id.hasPrefix("com.apple.keylayout.") }
        for src in layouts {
            let marker = src.selected ? " *" : "  "
            print("\(marker) \(src.name)  [\(src.id)]")
        }
        if layouts.isEmpty {
            print("  (none found — is this running as the logged-in user?)")
        }
        if let id = currentLayoutID() {
            print("\nCurrent layout: \(id)")
        }
        print("\nKeyboard type database (PID-VID-0 => type):")
        let types = keyboardTypes()
        for (k, v) in types.sorted(by: { $0.key < $1.key }) {
            let mine = k.hasPrefix("1-12930-") ? "   <- Everest Max" : ""
            print("  \(k) => \(v)\(mine)")
        }
        print("""

        For a UK PC keyboard the right layout is British-PC:
          everest layout --use British-PC

        If the extra ISO key (left of Z / right of shift) still does nothing,
        apply the usage fallback:
          everest remap --uk-iso
        """)
    }

    static func apply(args: [String]) {
        if args.contains("--clear") {
            runHidutil(mapping: [])
            print("Cleared all hidutil key remaps")
            return
        }
        if let i = args.firstIndex(of: "--use"), i + 1 < args.count {
            let want = args[i + 1]
            selectInputSource(named: want)
            return
        }
        if args.contains("--show") {
            print(run("/usr/bin/hidutil", ["property", "--get", "UserKeyMapping"]))
            return
        }
        if args.contains("--uk-iso") {
            // The ISO extra key reports usage 0x64 (Keyboard Non-US \ and |).
            // When the layout drops it, remap it onto the ANSI backslash
            // usage 0x31, which every UK layout knows how to print.
            let mapping: [[String: UInt64]] = [[
                "HIDKeyboardModifierMappingSrc": 0x700000064,
                "HIDKeyboardModifierMappingDst": 0x700000031,
            ]]
            runHidutil(mapping: mapping)
            print("Remapped the ISO key (usage 0x64 -> 0x31 backslash)")
            print("This lasts until reboot; unplug/replug the keyboard to apply immediately.")
            return
        }
        print("""
        usage:
          everest layout                    inspect layouts and keyboard type
          everest layout --use British-PC   switch the active input source
          everest remap --uk-iso            remap the ISO key to the ANSI backslash usage
          everest remap --show              show active hidutil remaps
          everest remap --clear             remove all hidutil remaps
        """)
    }

    // MARK: - Input sources (Carbon TIS)

    struct InputSource {
        var name: String
        var id: String
        var kind: String
        var selected: Bool
    }

    static func inputSources() -> [InputSource] {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap { src in
            let name = prop(src, kTISPropertyLocalizedName) as? String ?? "?"
            let id = prop(src, kTISPropertyInputSourceID) as? String ?? "?"
            let kind = prop(src, kTISPropertyInputSourceCategory) as? String ?? "?"
            let selected = (prop(src, kTISPropertyInputSourceIsSelected) as? Bool) ?? false
            let selectable = (prop(src, kTISPropertyInputSourceIsSelectCapable) as? Bool) ?? false
            guard selectable else { return nil }
            // Keyboard layouts carry either category: TISCategoryKeyboardInputSource
            // on modern macOS, "Keyboard Layout" on older releases.
            return InputSource(name: name, id: id, kind: kind, selected: selected)
        }
    }

    private static func prop(_ src: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue()
    }

    static func currentLayoutID() -> String? {
        inputSources().first { $0.selected && $0.id.hasPrefix("com.apple.keylayout.") }?.id
    }

    static func selectInputSource(named name: String) {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else {
            fail("cannot list input sources")
        }
        for src in list {
            let id = prop(src, kTISPropertyInputSourceID) as? String ?? ""
            let local = prop(src, kTISPropertyLocalizedName) as? String ?? ""
            if id == name || local == name || id == "com.apple.keylayout.\(name)" {
                let res = TISSelectInputSource(src)
                if res == noErr {
                    print("Switched input source to \(local) [\(id)]")
                } else {
                    fail("TISSelectInputSource failed (\(res))")
                }
                return
            }
        }
        fail("input source '\(name)' not found — run `everest layout` to list them")
    }

    // MARK: - Keyboard type database

    static func keyboardTypes() -> [String: Int] {
        let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.keyboardtype.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let table = dict["keyboardtype"] as? [String: Int] else { return [:] }
        return table
    }

    // MARK: - hidutil

    static func runHidutil(mapping: [[String: UInt64]]) {
        let json: String
        if mapping.isEmpty {
            json = "{\"UserKeyMapping\":[]}"
        } else {
            let inner = mapping.map { entry in
                let src = String(format: "0x%llx", entry["HIDKeyboardModifierMappingSrc"]!)
                let dst = String(format: "0x%llx", entry["HIDKeyboardModifierMappingDst"]!)
                return "{\"HIDKeyboardModifierMappingSrc\":\(src),\"HIDKeyboardModifierMappingDst\":\(dst)}"
            }.joined(separator: ",")
            json = "{\"UserKeyMapping\":[\(inner)]}"
        }
        _ = run("/usr/bin/hidutil", ["property", "--set", json])
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "\(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
