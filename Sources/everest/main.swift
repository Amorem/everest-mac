import CoreGraphics
import Foundation

// MARK: - helpers

func stderr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func fail(_ msg: String) -> Never {
    stderr(msg)
    exit(1)
}

func openKeyboard() -> Keyboard {
    do {
        let kb = try Keyboard()
        kb.wake()
        return kb
    } catch {
        fail("Error: \(error)")
    }
}

func progressBar() -> (Int) -> Void {
    var last = -1
    return { pct in
        let p = max(0, min(100, pct))
        guard p != last else { return }
        last = p
        let filled = p / 5
        let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: 20 - filled)
        stderr("\r  [\(bar)] \(p)%")
        if p >= 100 { stderr("") }
    }
}

func parseColor(_ s: String) -> (UInt8, UInt8, UInt8) {
    var hex = s
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else {
        fail("invalid color '\(s)' — expected RRGGBB")
    }
    return (UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
}

func parseButton(_ s: String) -> Int {
    guard let i = Int(s), i >= 1, i <= 4 else { fail("button must be 1-4 (D1-D4)") }
    return i - 1
}

func usage() {
    print("""
    everest — Mountain Everest Max companion for macOS

    Usage: everest <command> [options]

    Display
      info                          show attached accessories and display state
      clock [analog|digital] [12h|24h]
                                    sync the clock on the dial display
      mode <image|clock|volume|cpu|gpu|hd|network|ram>
                                    switch the main display mode
      image <file> [--frame N]      upload an image to the main display (240x204)
      reset-dial                    restore the factory logo on the dial
      icons                         list the built-in icon variants

    Numpad buttons (D1-D4)
      icon <n> <file> [--frame N]   upload an image to numpad button n (72x72)
      glyph <n> <variant>           select a built-in glyph on button n
      clear-buttons                 clear Base Camp leftovers from button flash

    Lighting
      rgb <effect> [--speed 0-100] [--brightness 0-100] [--colors RRGGBB,...] [--direction right|down|left|up|cw|ccw]
                                    built-in effects, as Base Camp sends them: static, wave,
                                    wave-dual, wave-4, wave-rainbow, tornado, tornado-rainbow,
                                    breathing, breathing-dual, breathing-rainbow, reactive,
                                    matrix, yeti, off
      effect <name> [--colors RRGGBB,...] [--speed N] [--brightness N] [--direction 0|2|4|6|8]
                                    Mac-rendered per-key effect (Ctrl-C to stop)

    Monitoring
      metrics                       send one round of CPU/RAM/network/volume values
      monitor                       run the live monitor loop (Ctrl-C to stop)

    DisplayPad
      pad info|image|color|clear|brightness|keys
                                    talk to the DisplayPad (`everest pad` for details)

    Buttons daemon
      listen [--no-pad]             watch D1-D4 and the DisplayPad, run the configured actions
      config                        show the config file location and contents
      init-config                   write a starter config file

    Keyboard layout
      layout                        inspect input sources and the keyboard type database
      layout --use British-PC       switch the active input source
      remap --uk-iso                hidutil fallback: ISO key (0x64) -> ANSI backslash (0x31)
      remap --show / --clear        show or remove hidutil remaps
      remap-key <key> <newkey>      firmware-level remap (see `keycodes`)
      keycodes [name]               physical key codes used by the firmware remap

    Recovery
      recover                       clear a wedged flash session (SDK device reset + picture resets)

    Self-test
      selftest [--lighting] [--upload N]
                                    talk to the keyboard and check the answers (read-only
                                    by default; --lighting switches the slot and restores
                                    it; --upload N sends a test picture to key N, then
                                    resets that key)
      selftest --pad [--draw]       the same for the DisplayPad (read-only; --draw shows a
                                    test pattern on key 12 in RAM, then restores it)

    Misc
      gui                           open the graphical interface
      sniff [seconds]               dump raw vendor packets
      keys [seconds]                dump raw keyboard-interface usages
      version                       print the tool version
    """)
}

// MARK: - commands

enum Command {
    static func info() {
        // Read-only, so it works on any firmware — and says whether the rest
        // of the tool will talk to this keyboard.
        let kb: Keyboard
        do { kb = try Keyboard(allowUnsupported: true) } catch { fail("Error: \(error)") }
        defer { kb.close() }
        guard let state = kb.state() else { fail("no reply from keyboard") }
        print("Keyboard : Mountain Everest Max (3282:0001)")
        if let v = kb.firmwareVersion {
            let tested = Keyboard.isSupported(firmware: v)
            print("Firmware : \(String(format: "%x", v))" + (tested ? "" : "  — NOT SUPPORTED (tested: \(String(format: "%x", Keyboard.supportedFirmware))); everest will not write to this keyboard"))
        } else {
            print("Firmware : unknown — everest will not write to this keyboard")
        }
        print("State    : \(state.raw.map { String(format: "%02x", $0) }.prefix(16).joined(separator: " "))")
        print("Attached : \(state.attachedSummary)")
        let modeName = Proto.MainMode.allCases.first { $0.menuByte == state.modeByte }?.rawValue ?? String(format: "0x%02x", state.modeByte)
        print("Dial mode: \(modeName)")
        print("Device   : \(state.deviceBytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
        let profile = kb.currentProfile()
        print("Profile  : \(profile)")
        if let code = kb.layoutCode {
            let layout = KeyboardLayout(firmwareCode: code)
            print("Layout   : \(layout.title) (firmware code \(code), \(layout.family == .iso ? "ISO" : "ANSI"))")
        }
    }

    static func clock(_ args: [String]) {
        let kb = openKeyboard()
        defer { kb.close() }
        var style: UInt8 = 0x00
        var twelve = false
        for a in args {
            switch a.lowercased() {
            case "digital": style = 0x01
            case "analog": style = 0x00
            case "12h": twelve = true
            case "24h": twelve = false
            default: fail("unknown clock option '\(a)'")
            }
        }
        kb.setTime(style: style, twelveHour: twelve)
        print("Clock synced (\(style == 0x01 ? "digital" : "analog"), \(twelve ? "12h" : "24h"))")
    }

    static func mode(_ args: [String]) {
        guard let name = args.first, let mode = Proto.MainMode(rawValue: name) else {
            fail("mode must be one of: \(Proto.MainMode.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let kb = openKeyboard()
        defer { kb.close() }
        kb.setMainMode(mode)
        print("Main display mode: \(mode.rawValue)")
    }

    static func image(_ args: [String]) {
        guard let path = args.first else { fail("usage: everest image <file> [--frame N]") }
        var frame = 0
        if let i = args.firstIndex(of: "--frame"), i + 1 < args.count { frame = Int(args[i + 1]) ?? 0 }
        do {
            let bytes = try ImageTools.rgb565(path: path, width: Keyboard.mainW, height: Keyboard.mainH, frame: frame)
            let kb = openKeyboard()
            defer { kb.close() }
            try kb.uploadMainDisplay(image: bytes, progress: progressBar())
            print("Uploaded \(path) to the main display")
        } catch {
            fail("Error: \(error)")
        }
    }

    static func icon(_ args: [String]) {
        guard args.count >= 2 else { fail("usage: everest icon <1-4> <file> [--frame N]") }
        let button = parseButton(args[0])
        let path = args[1]
        var frame = 0
        if let i = args.firstIndex(of: "--frame"), i + 1 < args.count { frame = Int(args[i + 1]) ?? 0 }
        do {
            let bytes = try ImageTools.rgb565(path: path, width: Keyboard.iconW, height: Keyboard.iconH, frame: frame)
            let kb = openKeyboard()
            defer { kb.close() }
            try kb.uploadIcon(button: button, image: bytes, progress: progressBar())
            print("Uploaded \(path) to button D\(button + 1)")
        } catch {
            fail("Error: \(error)")
        }
    }

    static func glyph(_ args: [String]) {
        guard args.count >= 2, let variant = Int(args[1]), variant >= 0, variant <= 8 else {
            fail("usage: everest glyph <1-4> <0-8>")
        }
        let button = parseButton(args[0])
        let kb = openKeyboard()
        defer { kb.close() }
        kb.setIcon(button: button, variant: variant)
        print("Button D\(button + 1) glyph set to variant \(variant)")
    }

    static func icons() {
        let names: [Int: [String]] = [
            0: ["up arrow", "down arrow", "left arrow", "right arrow", "circle", "dot", "square", "clock", "logo"],
        ]
        print("Variants 0-8 map to the factory glyph sheet; variant 7 is the plain clock.")
        for (_, v) in names { for (i, n) in v.enumerated() { print("  \(i): \(n)") } }
    }

    static func clearButtons() {
        let kb = openKeyboard()
        defer { kb.close() }
        for i in 0..<4 { kb.writeAction(button: i, command: ":") }
        print("Cleared leftover Base Camp actions from D1-D4")
    }

    static func rgb(_ args: [String]) {
        // Built-in effects, encoded the way Base Camp does (see Firmware.swift).
        let names: [String: (FirmwareLighting.Effect, FirmwareLighting.ColorMode)] = [
            "static": (.staticColor, .single), "off": (.off, .single),
            "breathing": (.breathing, .single), "breathing-dual": (.breathing, .dual),
            "breathing-rainbow": (.breathing, .rainbow),
            "wave": (.wave, .single), "wave-dual": (.wave, .dual), "wave-4": (.wave, .quad),
            "wave-rainbow": (.wave, .rainbow),
            "tornado": (.tornado, .single), "tornado-rainbow": (.tornado, .rainbow),
            "reactive": (.reactive, .withBackground), "yeti": (.yeti, .withBackground),
            "matrix": (.matrix, .withBackground),
        ]
        guard let name = args.first, let (effect, mode) = names[name] else {
            fail("effect must be one of: \(names.keys.sorted().joined(separator: ", "))")
        }
        var fw = FirmwareLighting()
        fw.effect = effect
        fw.mode = mode
        var colors: [RGB] = []
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--speed" where i + 1 < args.count: fw.speed = Double(args[i + 1]) ?? 50; i += 1
            case "--brightness" where i + 1 < args.count: fw.brightness = Double(args[i + 1]) ?? 100; i += 1
            case "--color" where i + 1 < args.count, "--colors" where i + 1 < args.count:
                colors += args[i + 1].split(separator: ",").compactMap { RGB(hex: String($0)) }; i += 1
            case "--color2" where i + 1 < args.count:
                if let c = RGB(hex: args[i + 1]) { colors.append(c) }; i += 1
            case "--direction" where i + 1 < args.count:
                let d = args[i + 1]
                if let dir = ["right": FirmwareLighting.Direction.right, "down": .down, "left": .left, "up": .up][d] {
                    fw.direction = dir
                } else if let n = Int(d), let dir = FirmwareLighting.Direction(rawValue: n) {
                    fw.direction = dir
                }
                if d == "ccw" || d == "10" { fw.clockwise = false }
                if d == "cw" || d == "9" { fw.clockwise = true }
                i += 1
            case "--no-save": noSave = true
            case "--dry-run": dryRun = true
            default: fail("unknown rgb option '\(args[i])'")
            }
            i += 1
        }
        for (n, c) in colors.prefix(4).enumerated() { fw.colors[n] = c }
        if dryRun {
            let hex = { (p: [UInt8]) in p.prefix(26).map { String(format: "%02x", $0) }.joined(separator: " ") }
            print("switch  \(hex(FirmwareLighting.switchProfile(1, slot: fw.effect.slot)))")
            print("effect  \(hex(fw.packet()))")
            print("save    \(hex(FirmwareLighting.saveFlash(slot: fw.effect.slot)))")
            return
        }
        let kb = openKeyboard()
        defer { kb.close() }
        kb.apply(fw, save: !noSave)
        print("RGB effect: \(name) (slot \(fw.effect.slot), speed level \(fw.speedLevel + 1)/5)")
    }
    private static var noSave = false
    private static var dryRun = false

    static func metricsOnce() {
        let kb = openKeyboard()
        defer { kb.close() }
        // CPU is a delta between two reads; take a first sample to prime it.
        _ = Metrics.sample()
        usleep(250_000)
        let m = Metrics.sample()
        kb.sendMetric(index: 0, value: m.cpu)
        kb.sendMetric(index: 1, value: m.gpu)
        kb.sendMetric(index: 2, value: m.disk)
        kb.sendMetric(index: 3, value: m.networkMBs)
        kb.sendMetric(index: 4, value: m.ram)
        if let v = m.volumeLevel { kb.sendVolume(v) }
        print("cpu \(m.cpu)%  gpu \(m.gpu)%  disk \(m.disk)%  net \(m.networkMBs) MB/s  ram \(m.ram)%  volume \(m.volumeLevel.map(String.init) ?? "-")")
    }

    static func monitor() {
        let kb = openKeyboard()
        defer { kb.close() }
        kb.setMainMode(.cpu)
        stderr("Monitor loop running — Ctrl-C to stop")
        var tick = 0
        var lastClock = Date.distantPast
        while true {
            let m = Metrics.sample()
            kb.sendMetric(index: 0, value: m.cpu)
            kb.sendMetric(index: 1, value: m.gpu)
            kb.sendMetric(index: 2, value: m.disk)
            kb.sendMetric(index: 3, value: m.networkMBs)
            kb.sendMetric(index: 4, value: m.ram)
            if let v = m.volumeLevel { kb.sendVolume(v) }
            if Date().timeIntervalSince(lastClock) >= 60 {
                kb.setTime(style: 0x00, twelveHour: false)
                lastClock = Date()
            }
            tick += 1
            if tick % 25 == 0 { stderr("  cpu \(m.cpu)% ram \(m.ram)% net \(m.networkMBs) MB/s") }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    static func resetDial() {
        let kb = openKeyboard()
        defer { kb.close() }
        kb.resetDial()
        print("Dial image reset to the factory logo")
    }

    static func resetNumpad(_ args: [String]) {
        let kb = openKeyboard()
        defer { kb.close() }
        var bitmap: UInt8 = 0
        for (i, flag) in ["--d1", "--d2", "--d3", "--d4"].enumerated() where args.contains(flag) { bitmap |= 1 << UInt8(i) }
        if bitmap == 0 { bitmap = 0x0F }
        let slot = Int(kb.currentProfile())
        try? kb.transport.write(Proto.resetNumpadPics(bitmap, slot: slot))
        _ = kb.transport.read(timeout: 0.5)
        kb.neutraliseKeyActions()   // the reset brings back the factory key actions
        print(String(format: "Numpad display images reset to factory (bitmap 0x%02x)", bitmap))
    }

    static func featureProbe() {
        let kb = openKeyboard()
        defer { kb.close() }
        print("getFeature baseline: \(hex(kb.transport.getFeature()))")
        var cmd = [UInt8](repeating: 0, count: 64)
        cmd[0] = 0xAA; cmd[1] = 0x55; cmd[2] = 0x80; cmd[3] = 0x00
        try? kb.transport.setFeature(cmd)
        usleep(100_000)
        print("after  aa 55 80 00 : \(hex(kb.transport.getFeature()))")
        cmd[2] = 0x21; cmd[3] = 0x04
        try? kb.transport.setFeature(cmd)
        usleep(100_000)
        print("after  aa 55 21 04 : \(hex(kb.transport.getFeature()))")
    }

    private static func hex(_ p: [UInt8]) -> String {
        p.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func layout(_ args: [String] = []) {
        if args.isEmpty {
            Layout.inspect()
        } else {
            Layout.apply(args: args)
        }
    }

    static func remap(_ args: [String]) {
        Layout.apply(args: args)
    }

    static func effect(_ args: [String]) {
        guard let name = args.first, let kind = LedEffect.Kind(rawValue: name) else {
            fail("effect must be one of: \(LedEffect.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var effect = LedEffect()
        effect.kind = kind
        var speed = 50.0, brightness = 100.0, fps = 30.0, duration = 0.0, direction = 0
        var palette: [RGB] = []
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--speed" where i + 1 < args.count: speed = Double(args[i + 1]) ?? 50; i += 1
            case "--brightness" where i + 1 < args.count: brightness = Double(args[i + 1]) ?? 100; i += 1
            case "--fps" where i + 1 < args.count: fps = Double(args[i + 1]) ?? 30; i += 1
            case "--duration" where i + 1 < args.count: duration = Double(args[i + 1]) ?? 0; i += 1
            case "--direction" where i + 1 < args.count: direction = Int(args[i + 1]) ?? 0; i += 1
            case "--blend": break   // kept for old scripts: palettes always blend now
            case "--colors" where i + 1 < args.count, "--color" where i + 1 < args.count:
                for hex in args[i + 1].split(separator: ",") {
                    if let c = RGB(hex: String(hex)) { palette.append(c) }
                }
                i += 1
            default: fail("unknown effect option '\(args[i])'")
            }
            i += 1
        }
        if !palette.isEmpty { effect.palette = palette }
        effect.speed = speed
        effect.brightness = brightness
        effect.direction = direction

        let player = LedPlayer(effect: effect)
        player.onConnection = { stderr($0 ? "keyboard connected" : "keyboard not available — waiting for it") }
        print("Effect \(effect.kind.rawValue) — \(effect.palette.map(\.hex).joined(separator: ", ")) — Ctrl-C to stop")
        player.start(fps: fps)
        let deadline = duration > 0 ? Date().addingTimeInterval(duration) : Date.distantFuture
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        player.stop()
    }

    /// Dump the physical layout with the normalised positions the effects use.
    static func layoutDump() {
        if let name = CommandLine.arguments.dropFirst(2).first, let l = KeyboardLayout(rawValue: name) { LedLayout.use(l) }
        var seen: [Int: String] = [:]
        for key in LedLayout.keys {
            guard let idx = key.index else { continue }
            if let other = seen[idx] {
                print("DUPLICATE index \(idx): \(other) and \(key.label)")
            }
            seen[idx] = key.label
        }
        let pos = LedLayout.keyPositions
        for key in LedLayout.keys.sorted(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) {
            let p = key.index.flatMap { pos[$0] }
            print(String(format: "%-6@ idx=%@ x=%6.1f y=%6.1f  norm=(%.3f, %.3f)",
                         key.label as NSString,
                         (key.index.map { String($0) } ?? "—") as NSString,
                         key.x, key.y, p?.x ?? -1, p?.y ?? -1))
        }
        print("keys=\(LedLayout.keys.count) mapped=\(seen.count)")
    }

    static func recover() {
        let kb = openKeyboard()
        defer { kb.close() }
        kb.recover()
        print("Recovery sequence sent (device reset + picture resets)")
    }

    static func remapKey(_ args: [String]) {
        guard args.count >= 2 else {
            fail("usage: everest remap-key <key> <newkey> [--mods 0-15]\n       key names from `everest keycodes` (e.g. iso, backslash, a)")
        }
        guard let key = KeyCodes.code(args[0]) else { fail("unknown key '\(args[0])' — run `everest keycodes`") }
        guard let target = KeyCodes.code(args[1]) else { fail("unknown key '\(args[1])' — run `everest keycodes`") }
        var mods: UInt8? = nil
        if let i = args.firstIndex(of: "--mods"), i + 1 < args.count { mods = UInt8(args[i + 1]) }
        let kb = openKeyboard()
        defer { kb.close() }
        kb.remapKey(key, to: target, modifiers: mods)
        print(String(format: "Remapped key 0x%02x -> 0x%02x%@", key, target, mods.map { String(format: " (mods 0x%02x)", $0) } ?? ""))
    }

    static func keycodes(_ args: [String]) {
        if let first = args.first {
            if let code = KeyCodes.code(first) {
                print(String(format: "%@ = 0x%02x", first, code))
                return
            }
            fail("unknown key '\(first)'")
        }
        let sorted = KeyCodes.table.sorted { $0.value < $1.value }
        for (name, code) in sorted {
            print(String(format: "  0x%02x  %@", code, name))
        }
    }
}

// MARK: - dispatch

let rawArgs = Array(CommandLine.arguments.dropFirst())
// Launched from Everest.app (no arguments): open the window.
guard let command = rawArgs.first ?? (Bundle.main.bundlePath.hasSuffix(".app") ? "gui" : nil) else {
    usage()
    exit(0)
}
let rest = Array(rawArgs.dropFirst())

switch command {
case "info": Command.info()
case "clock": Command.clock(rest)
case "mode": Command.mode(rest)
case "image": Command.image(rest)
case "icon": Command.icon(rest)
case "glyph": Command.glyph(rest)
case "icons": Command.icons()
case "clear-buttons": Command.clearButtons()
case "rgb": Command.rgb(rest)
case "metrics": Command.metricsOnce()
case "monitor": Command.monitor()
case "reset-dial": Command.resetDial()
case "reset-numpad": Command.resetNumpad(rest)
case "listen": Daemon.run(rest)
case "pad": PadCommand.run(rest)
case "sniff": Daemon.sniff(rest)
case "keys": Keys.dump(rest)
case "feature-test": Command.featureProbe()
case "config": ConfigCommand.show()
case "init-config": ConfigCommand.initFile()
case "layout": Command.layout(rest)
case "remap": Command.remap(rest)
case "remap-key": Command.remapKey(rest)
case "keycodes": Command.keycodes(rest)
case "effect": Command.effect(rest)
case "menubar-sheet": MainActor.assumeIsolated { Gui.menuBarSheet(to: rest.first ?? "menubar.png") }
case "selftest": SelfTest.run(rest)
case "layout-sheet": MainActor.assumeIsolated { Gui.layoutSheet(to: rest.first ?? "layouts.png") }
case "icon-sheet": MainActor.assumeIsolated { Gui.iconSheet(to: rest.first ?? "icons.png") }
case "effect-sheet": MainActor.assumeIsolated { Gui.effectSheet(to: rest.first ?? "effects.png") }
case "layout-dump": Command.layoutDump()
case "recover": Command.recover()
case "gui": Gui.run()
case "version": print("everest 0.1.0")
case "help", "-h", "--help": usage()
default:
    stderr("unknown command '\(command)'\n")
    usage()
    exit(1)
}
