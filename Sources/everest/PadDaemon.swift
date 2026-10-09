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
        var retry: TimeInterval = 2
        func note(_ why: String, _ state: PadState) {
            if waiting != why { log(why); waiting = why }
            state.publish()
        }
        while true {
            autoreleasepool {
                guard DisplayPad.isPresent else {
                    note("not connected — waiting for it", PadState(status: .absent))
                    retry = 2
                    Thread.sleep(forTimeInterval: 2)
                    return
                }
                let pad: DisplayPad
                do {
                    pad = try DisplayPad()
                } catch DisplayPad.PadError.unsupportedFirmware(let v) {
                    // Nothing more is sent to it until it is plugged in again
                    // (possibly after a firmware update).
                    note("firmware \(PadProto.firmwareString(v)) is not the tested one — left alone until it is replugged",
                         PadState(status: .unsupported, firmware: PadProto.firmwareString(v)))
                    while DisplayPad.isPresent { Thread.sleep(forTimeInterval: 2) }
                    return
                } catch {
                    note("left alone — \(error)", PadState(status: .noAnswer))
                    Thread.sleep(forTimeInterval: retry)
                    retry = min(30, retry * 2)
                    return
                }
                waiting = nil
                retry = 2
                log("connected (firmware \(pad.firmware.map(PadProto.firmwareString) ?? "?"))")
                PadState(status: .connected, firmware: pad.firmware.map(PadProto.firmwareString)).publish()
                session(pad)
                pad.close()
                log("connection lost — reconnecting")
                PadState(status: .noAnswer).publish()
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// What a key shows, to notice changes: the image path and its date.
    static func signature(_ b: ButtonConfig) -> String {
        guard let p = b.iconPath else { return "" }
        let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        return "\(p)|\(d?.timeIntervalSince1970 ?? 0)"
    }

    /// What a key shows, darkened to the pad brightness (see `PadProto.backlight`).
    static func bgr(for b: ButtonConfig, brightness: Int) -> [UInt8] {
        let raw = b.iconPath.flatMap { try? ImageTools.padBGR(path: $0) } ?? PadProto.solid(r: 0, g: 0, b: 0)
        return PadProto.dim(raw, percent: brightness)
    }

    private static func configDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Config.file.path))?[.modificationDate] as? Date
    }

    private static func session(_ pad: DisplayPad) {
        var cfg = Config.load()
        func profile() -> Int { ActiveProfile.current ?? cfg.selectedProfile }

        var shownProfile = 0
        var shown = [String](repeating: "-", count: PadProto.keyCount)
        var wanted = [String](repeating: "", count: PadProto.keyCount)
        var brightness: Int?
        var configStamp = configDate()
        var lastCheck = Date.distantPast
        var lastPing = Date()
        var missedPings = 0
        var lastTick = Date()
        var failures = 0
        var retryAt = Date.distantPast
        var lastError: String?
        var held = Set<Int>()
        var lastFired = [Date](repeating: .distantPast, count: PadProto.keyCount)

        while true {
            let stop: Bool = autoreleasepool {
                let now = Date()
                // A long gap means the Mac slept: the pad may have been reset.
                if now.timeIntervalSince(lastTick) > 10 {
                    log("woke up — setting the pad up again")
                    guard (try? pad.enable(timeout: 8)) != nil else { return true }
                    shown = shown.map { _ in "-" }
                    brightness = nil
                }
                lastTick = now

                // Config and picture files, once a second.
                if now.timeIntervalSince(lastCheck) >= 1 {
                    lastCheck = now
                    let stamp = configDate()
                    if stamp != configStamp { configStamp = stamp; cfg = Config.load() }
                    let p = profile()
                    if p != shownProfile { shown = shown.map { _ in "-" }; shownProfile = p }
                    wanted = cfg.padButtons(for: p).map(signature)
                }

                if !PadBusy.active {
                    if now >= retryAt {
                        do {
                            if brightness != cfg.padBrightness {
                                try pad.setBrightness(PadProto.backlight(for: cfg.padBrightness))
                                brightness = cfg.padBrightness
                                shown = shown.map { _ in "-" }   // redraw at the new level
                            }
                            let keys = cfg.padButtons(for: shownProfile)
                            let changed = (0..<PadProto.keyCount).filter { wanted[$0] != shown[$0] }
                            if !changed.isEmpty {
                                try pad.setKeyImages(changed.map { ($0, bgr(for: keys[$0], brightness: cfg.padBrightness)) }) { k in
                                    shown[k] = wanted[k]
                                }
                                if changed.count > 1 { log("profile \(shownProfile): \(changed.count) keys drawn") }
                            }
                            failures = 0
                            lastError = nil
                        } catch let e as DisplayPad.PadError {
                            if failed("\(e)") { return true }
                        } catch let e as PadPixelPipe.PipeError {
                            if failed("\(e)") { return true }
                        } catch {
                            return true   // write failed: unplugged
                        }
                    }

                    // Keep-alive on its own schedule: three unanswered queries
                    // in a row mean the handle is stale.
                    if now.timeIntervalSince(lastPing) >= 3 {
                        lastPing = now
                        guard let answer = try? pad.brightness() else { return true }
                        missedPings = answer == nil ? missedPings + 1 : 0
                        if missedPings >= 3 { return true }
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
                return false
            }
            if stop { return }
            Thread.sleep(forTimeInterval: 0.05)
        }

        /// A picture did not go through: wait longer each time, say so once,
        /// and reconnect (host mode again) after five failures in a row.
        func failed(_ message: String) -> Bool {
            failures += 1
            if message != lastError { log("\(message) — retrying"); lastError = message }
            retryAt = Date().addingTimeInterval(min(30, 0.5 * pow(2, Double(failures))))
            return failures >= 5
        }
    }
}

/// What the daemon knows about the pad, for the app's status line
/// (`.pad-state` in the config directory).
struct PadState: Codable, Equatable {
    enum Status: String, Codable { case absent, noAnswer, unsupported, connected }
    var status: Status
    var firmware: String?

    static var url: URL { Config.directory.appendingPathComponent(".pad-state") }

    func publish() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? data.write(to: PadState.url, options: .atomic)
    }

    static func read() -> PadState? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PadState.self, from: $0) }
    }
}

/// Marker files: another program (the app while the daemon is off, a CLI
/// command, the self-test) is talking to the DisplayPad; the daemon stays off
/// the command channel meanwhile. One file per process, so one finishing does
/// not clear another's; a crashed process's marker is ignored.
enum PadBusy {
    private static let prefix = ".pad-busy."
    private static var url: URL { Config.directory.appendingPathComponent(prefix + "\(getpid())") }

    static func set() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    static var active: Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Config.directory.path) else { return false }
        return names.contains { name in
            guard name.hasPrefix(prefix), let pid = Int32(name.dropFirst(prefix.count)), pid != getpid(),
                  kill(pid, 0) == 0 || errno == EPERM else { return false }
            let path = Config.directory.appendingPathComponent(name).path
            let d = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return d.map { Date().timeIntervalSince($0) < 120 } ?? false
        }
    }
}

/// `everest pad …`
enum PadCommand {
    static func run(_ args: [String]) {
        guard let sub = args.first else { usage(); exit(1) }
        let rest = Array(args.dropFirst())
        // Check the arguments before taking the pad.
        switch sub {
        case "info", "keys": break
        case "image", "color": guard rest.count >= 2 else { usage(); exit(1) }; _ = key(rest[0])
        case "clear": if let k = rest.first { _ = key(k) }
        case "brightness":
            guard let v = rest.first.flatMap(Int.init), (0...100).contains(v) else { fail("usage: everest pad brightness <0-100>") }
        default: usage(); exit(1)
        }
        let color = sub == "color" ? parseColor(rest[1]) : nil

        PadBusy.set()
        func bail(_ message: String) -> Never { PadBusy.clear(); fail(message) }
        let pad: DisplayPad
        do { pad = try DisplayPad(allowUnsupported: sub == "info") } catch { bail("Error: \(error)") }
        defer { pad.close(); PadBusy.clear() }
        do {
            switch sub {
            case "info":
                print("DisplayPad 3282:0009")
                print("  firmware   \(pad.firmware.map(PadProto.firmwareString) ?? "unknown")"
                      + (pad.firmware == PadProto.supportedFirmware ? " (tested)" : " (NOT tested: read-only)"))
                if pad.firmware == PadProto.supportedFirmware, let b = try pad.brightness() { print("  backlight  \(b) %") }
            case "image":
                try pad.setKeyImage(key(rest[0]), bgr: ImageTools.padBGR(path: rest[1]))
                print("Key \(rest[0]) updated (until the pad is unplugged)")
            case "color":
                let (r, g, b) = color!
                try pad.setKeyImage(key(rest[0]), bgr: PadProto.solid(r: r, g: g, b: b))
                print("Key \(rest[0]) set to #\(rest[1])")
            case "clear":
                let keys = rest.first.map { [key($0)] } ?? Array(0..<PadProto.keyCount)
                try pad.setKeyImages(keys.map { ($0, PadProto.solid(r: 0, g: 0, b: 0)) })
                print("Cleared \(keys.count) key(s)")
            case "brightness":
                // Like the other pad commands, this lasts until the next
                // redraw; the saved level is the app's (config.json).
                let v = Int(rest[0])!
                let cfg = Config.load()
                let keys = cfg.padButtons(for: cfg.selectedProfile)
                try pad.setBrightness(PadProto.backlight(for: v))
                try pad.setKeyImages((0..<PadProto.keyCount).map { ($0, PadDaemon.bgr(for: keys[$0], brightness: v)) })
                print("Keys redrawn at \(PadProto.brightnessLevel(v)) % (until the next redraw; set it in the app to keep it)")
            default:
                let seconds = rest.first.flatMap(Double.init) ?? 15
                print("Press DisplayPad keys for \(Int(seconds)) s…")
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    if let k = pad.nextEvent(timeout: 0.2) {
                        print(k.isEmpty ? "  released" : "  pressed " + k.sorted().map { "P\($0 + 1)" }.joined(separator: " "))
                    }
                }
            }
        } catch {
            pad.close()
            bail("Error: \(error)")
        }
    }

    private static func key(_ s: String) -> Int {
        guard let i = Int(s), (1...PadProto.keyCount).contains(i) else { fail("key must be 1-12 (top row 1-6, bottom row 7-12)") }
        return i - 1
    }

    static func usage() {
        print("""
        usage: everest pad <command>
          info                      firmware and backlight
          image <1-12> <file>       picture on a key (until the pad is unplugged)
          color <1-12> <RRGGBB>     solid colour on a key
          clear [1-12]              blank one key or all of them
          brightness <0-100>        redraw the keys at that brightness (not saved)
          keys [seconds]            print key presses
        Keys and pictures that stay belong in the app (DisplayPad page) or
        config.json (`pad` in each profile); `everest listen` applies them.
        """)
    }
}
