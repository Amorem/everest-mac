import Foundation

/// The keyboard profile the daemon is following, shared with the DisplayPad
/// thread so the pad shows the keys of the same profile (nil: no keyboard,
/// use the profile selected in the app).
enum ActiveProfile {
    private static let lock = NSLock()
    private static var value: Int?

    static var current: Int? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// DisplayPad half of `everest listen`, on its own thread: the pad and the
/// keyboard come and go independently.
///
/// The pad keeps pictures in RAM only, so every connection (plug-in, Mac
/// wake, profile change) sends all twelve again; a changed key in the config
/// is re-sent within a second.
enum PadDaemon {
    private static func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        stderr("\(f.string(from: Date())) pad: \(s)")
    }

    static func start() {
        let t = Thread { run() }
        t.name = "DisplayPad"
        t.start()
    }

    private static func run() {
        var waiting: String?
        while true {
            guard DisplayPad.isPresent else {
                if waiting != "absent" { log("not connected — waiting for it"); waiting = "absent" }
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            let pad: DisplayPad
            do {
                pad = try DisplayPad()
            } catch {
                let why = "\(error)"
                if waiting != why { log("left alone — \(why)"); waiting = why }
                Thread.sleep(forTimeInterval: error is DisplayPad.PadError ? 3 : 1)
                continue
            }
            waiting = nil
            log("connected (firmware \(pad.firmware.map(PadProto.firmwareString) ?? "?"))")
            session(pad)
            pad.close()
            log("connection lost — reconnecting")
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// What a key shows, to notice changes: the image path and its date.
    private static func signature(_ b: ButtonConfig) -> String {
        guard let p = b.iconPath else { return "" }
        let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        return "\(p)|\(d?.timeIntervalSince1970 ?? 0)"
    }

    /// What a key shows, darkened to the pad brightness (see `PadProto.backlight`).
    static func bgr(for b: ButtonConfig, brightness: Int) -> [UInt8] {
        let raw = b.iconPath.flatMap { try? ImageTools.padBGR(path: $0) } ?? PadProto.solid(r: 0, g: 0, b: 0)
        return PadProto.dim(raw, percent: brightness)
    }

    private static func session(_ pad: DisplayPad) {
        var cfg = Config.load()
        func profile() -> Int { ActiveProfile.current ?? cfg.selectedProfile }
        func configDate() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: Config.file.path))?[.modificationDate] as? Date
        }

        var shownProfile = 0
        var shown = [String](repeating: "-", count: PadProto.keyCount)
        var brightness: Int?
        var configStamp = configDate()
        var lastConfigCheck = Date()
        var lastPing = Date()
        var missedPings = 0
        var lastTick = Date()
        var held = Set<Int>()
        var lastFired = [Date](repeating: .distantPast, count: PadProto.keyCount)

        while true {
            let now = Date()
            // A long gap means the Mac slept: the pad may have been reset.
            if now.timeIntervalSince(lastTick) > 10 {
                log("woke up — setting the pad up again")
                guard (try? pad.enable(timeout: 8)) != nil else { return }
                shown = shown.map { _ in "-" }
                brightness = nil
            }
            lastTick = now

            if now.timeIntervalSince(lastConfigCheck) >= 1 {
                lastConfigCheck = now
                let stamp = configDate()
                if stamp != configStamp { configStamp = stamp; cfg = Config.load() }
            }

            if !PadBusy.active {
                do {
                    if brightness != cfg.padBrightness {
                        try pad.setBrightness(PadProto.backlight(for: cfg.padBrightness))
                        brightness = cfg.padBrightness
                        shown = shown.map { _ in "-" }   // redraw at the new level
                    }
                    let p = profile()
                    if p != shownProfile { shown = shown.map { _ in "-" }; shownProfile = p }
                    let keys = cfg.padButtons(for: p)
                    let changed = (0..<PadProto.keyCount).filter { signature(keys[$0]) != shown[$0] }
                    if !changed.isEmpty {
                        try pad.setKeyImages(changed.map { ($0, bgr(for: keys[$0], brightness: cfg.padBrightness)) })
                        for k in changed { shown[k] = signature(keys[k]) }
                        if changed.count > 1 { log("profile \(p): \(changed.count) keys drawn") }
                    }

                    // Keep-alive: an unanswered query three times in a row
                    // means the handle is stale.
                    if now.timeIntervalSince(lastPing) >= 3 {
                        lastPing = now
                        missedPings = try pad.brightness() == nil ? missedPings + 1 : 0
                        if missedPings >= 3 { return }
                    }
                } catch DisplayPad.PadError.imageRejected(let k) {
                    log("key \(k + 1): picture not taken, retrying")
                    Thread.sleep(forTimeInterval: 0.5)
                } catch let e as PadPixelPipe.PipeError {
                    log("\(e)")
                    Thread.sleep(forTimeInterval: 0.5)
                } catch {
                    return   // write failed: unplugged
                }
            }

            // Key presses fire on the way down, like D1–D4.
            while let pressed = pad.nextEvent(timeout: 0.05) {
                let keys = cfg.padButtons(for: profile())
                for k in pressed.subtracting(held).sorted() where Date().timeIntervalSince(lastFired[k]) >= 0.25 {
                    lastFired[k] = Date()
                    let b = keys[k]
                    log("P\(k + 1) pressed — \(b.name ?? b.action.type): \(b.action.value)")
                    ActionRunner.run(b.action)
                }
                held = pressed
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

/// Marker file: the app is talking to the DisplayPad itself (pictures or
/// brightness while the daemon is off, or a CLI command); the daemon stays
/// off the command channel meanwhile.
enum PadBusy {
    static var url: URL { Config.directory.appendingPathComponent(".pad-busy") }

    static func set() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    static var active: Bool {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(d) < 30
    }
}

/// `everest pad …`
enum PadCommand {
    static func run(_ args: [String]) {
        guard let sub = args.first else { usage(); exit(1) }
        let rest = Array(args.dropFirst())
        PadBusy.set()
        defer { PadBusy.clear() }
        let pad: DisplayPad
        do { pad = try DisplayPad(allowUnsupported: sub == "info") } catch { PadBusy.clear(); fail("Error: \(error)") }
        defer { pad.close() }
        do {
            switch sub {
            case "info":
                print("DisplayPad 3282:0009")
                print("  firmware   \(pad.firmware.map(PadProto.firmwareString) ?? "unknown")"
                      + (pad.firmware == PadProto.supportedFirmware ? " (tested)" : " (NOT tested: read-only)"))
                if let b = try pad.brightness() { print("  brightness \(b) %") }
            case "image":
                guard rest.count >= 2 else { usage(); exit(1) }
                try pad.setKeyImage(key(rest[0]), bgr: ImageTools.padBGR(path: rest[1]))
                print("Key \(rest[0]) updated (until the pad is unplugged)")
            case "color":
                guard rest.count >= 2 else { usage(); exit(1) }
                let (r, g, b) = parseColor(rest[1])
                try pad.setKeyImage(key(rest[0]), bgr: PadProto.solid(r: r, g: g, b: b))
                print("Key \(rest[0]) set to #\(rest[1])")
            case "clear":
                let keys = rest.first.map { [key($0)] } ?? Array(0..<PadProto.keyCount)
                try pad.setKeyImages(keys.map { ($0, PadProto.solid(r: 0, g: 0, b: 0)) })
                print("Cleared \(keys.count) key(s)")
            case "brightness":
                guard let v = rest.first.flatMap(Int.init), (0...100).contains(v) else { fail("usage: everest pad brightness <0-100>") }
                // Saved like the app does; the keys are redrawn at that level.
                var cfg = Config.load()
                cfg.padBrightness = PadProto.brightnessLevel(v)
                cfg.save()
                try pad.setBrightness(PadProto.backlight(for: v))
                let keys = cfg.padButtons(for: ActiveProfile.current ?? cfg.selectedProfile)
                try pad.setKeyImages((0..<PadProto.keyCount).map { ($0, PadDaemon.bgr(for: keys[$0], brightness: v)) })
                print("Brightness \(cfg.padBrightness) %")
            case "keys":
                let seconds = rest.first.flatMap(Double.init) ?? 15
                print("Press DisplayPad keys for \(Int(seconds)) s…")
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    if let k = pad.nextEvent(timeout: 0.2) {
                        print(k.isEmpty ? "  released" : "  pressed " + k.sorted().map { "P\($0 + 1)" }.joined(separator: " "))
                    }
                }
            default:
                usage(); exit(1)
            }
        } catch {
            PadBusy.clear()
            fail("Error: \(error)")
        }
    }

    private static func key(_ s: String) -> Int {
        guard let i = Int(s), (1...PadProto.keyCount).contains(i) else { fail("key must be 1-12 (top row 1-6, bottom row 7-12)") }
        return i - 1
    }

    static func usage() {
        print("""
        usage: everest pad <command>
          info                      firmware and brightness
          image <1-12> <file>       picture on a key (until the pad is unplugged)
          color <1-12> <RRGGBB>     solid colour on a key
          clear [1-12]              blank one key or all of them
          brightness <0-100>        brightness, in percent (saved; keys redrawn)
          keys [seconds]            print key presses
        Keys and pictures that stay belong in the app (DisplayPad page) or
        config.json (`pad` in each profile); `everest listen` applies them.
        """)
    }
}
