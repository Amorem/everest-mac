import Foundation

/// Marker file: a picture transfer is running, the daemon must stay off the
/// vendor channel (keep-alives in the middle of a flash session upset it).
enum FlashBusy {
    static var url: URL { Config.directory.appendingPathComponent(".flash-busy") }

    static func set() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    /// Busy if the marker is fresh (a crashed upload must not silence the
    /// daemon for ever).
    static var active: Bool {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(d) < 300
    }
}

/// Button listener: keeps the vendor channel alive, turns display-key presses
/// into actions, keeps the clock in sync and (optionally) pushes monitor
/// values to the dial. It survives the keyboard being unplugged: the HID
/// session is dropped and reopened as soon as the keyboard is back.
enum Daemon {
    private static func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        stderr("\(f.string(from: Date())) \(s)")
    }

    /// Exit status when another listener already runs (the app waits and
    /// tries again rather than restarting at once).
    static let alreadyRunning: Int32 = 75

    /// Held for the life of the process: two listeners would run every
    /// action twice.
    private static var lockFD: Int32 = -1

    private static func takeLock() -> Bool {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        lockFD = open(Config.directory.appendingPathComponent("listen.lock").path, O_CREAT | O_RDWR, 0o600)
        return lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0
    }

    /// Started by the app: stop with it, so a crashed or force-quit app does
    /// not leave an orphan listener behind.
    private static var parentWatch: DispatchSourceProcess?

    private static func exitWithParent(_ args: [String]) {
        guard let i = args.firstIndex(of: "--parent-pid"), i + 1 < args.count,
              let pid = pid_t(args[i + 1]) else { return }
        if kill(pid, 0) != 0 { exit(0) }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { log("the app quit — stopping"); exit(0) }
        source.resume()
        parentWatch = source
    }

    static func run(_ args: [String]) {
        let verbose = args.contains("--verbose")
        exitWithParent(args)
        guard takeLock() else {
            log("another `everest listen` is already running — not starting a second one")
            exit(alreadyRunning)
        }

        // From the app the permission is shown in its own banner, so don't
        // pop the system dialog again on every start.
        if !ActionRunner.accessibilityGranted(prompt: !args.contains("--no-prompt")) {
            log("""
            warning: Accessibility permission is not granted to this program.
            Key presses and typed text will be silently dropped by macOS.
            Open System Settings > Privacy & Security > Accessibility and add
            Everest (remove a stale entry first), then restart the daemon.
            """)
        }

        signal(SIGINT) { _ in
            stderr("\nStopping.")
            exit(0)
        }

        // Profile keys (D1–D4 or the pad) hand their request to whoever owns
        // the profile: the keyboard session below, or the pad thread.
        ActionRunner.profileHandler = { ProfileRequest.post($0) }

        // The DisplayPad is a device of its own, served on its own thread.
        if !args.contains("--no-pad") { PadDaemon.start() }

        var waiting: String?
        while true {
            let kb: Keyboard
            do {
                kb = try Keyboard()
            } catch {
                // Not found, or found but on a firmware this code was not
                // tested with: say which, once, and keep checking so that a
                // replug after a firmware update is picked up.
                let why = error is Keyboard.OpenError ? "keyboard left alone — \(error)" : "keyboard not found — waiting for it"
                if waiting != why { log(why); waiting = why }
                Thread.sleep(forTimeInterval: error is Keyboard.OpenError ? 3 : 1)
                continue
            }
            waiting = nil
            log("keyboard connected")
            session(kb, verbose: verbose)
            ActiveProfile.current = nil
            kb.close()
            log("keyboard connection lost — reconnecting")
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// One connection's worth of work; returns when the keyboard is gone.
    private static func session(_ kb: Keyboard, verbose: Bool) {
        var cfg = Config.load()
        kb.wake()

        // The keyboard's own D1–D4 shortcuts would fire next to our actions.
        // Each neutralisation writes the key-action flash, so once per
        // profile and connection is enough.
        var neutralised = Set<Int>()
        func neutralise(_ profile: Int) {
            guard !cfg.keepFlashActions, !neutralised.contains(profile) else { return }
            kb.neutraliseKeyActions()
            neutralised.insert(profile)
        }

        if cfg.applyClockOnStart {
            kb.setTime(style: cfg.clockStyle == "digital" ? 0x01 : 0x00,
                       twelveHour: cfg.clockFormat == "12h")
        }

        // The keyboard's active profile — changed from the dial or by us.
        // Night mode as last applied to the keyboard's lighting; nil after a
        // profile change (switching profile restores the profile's lighting).
        var nightApplied: Bool? = false
        var profile = Int(kb.currentProfile()) {
            didSet { ActiveProfile.current = profile; nightApplied = nil }
        }
        ActiveProfile.current = profile
        let startMode = cfg.profileIndex(profile).flatMap { cfg.profiles[$0].dialMode } ?? cfg.mainDisplayMode
        if let mode = Proto.MainMode(rawValue: startMode) { kb.setMainMode(mode) }
        var lastProfileQuery = Date()
        var lastFrontCheck = Date.distantPast
        let switcher = AutoSwitcher()
        neutralise(profile)
        log("profile \(profile) active")

        var lastButton: Int? = nil
        var lastAction = Date.distantPast
        var lastClock = Date()
        var lastMetrics = Date.distantPast
        var lastReply = Date()

        log("listening — \(cfg.buttons(for: profile).enumerated().map { "D\($0.offset + 1): \($0.element.name ?? $0.element.action.type.rawValue)" }.joined(separator: ", "))")

        func configDate() -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: Config.file.path))?[.modificationDate] as? Date
        }
        var configStamp = configDate()
        var lastConfigCheck = Date()

        while true {
            let now = Date()

            // A picture upload owns the channel: stay quiet until it is done.
            if FlashBusy.active {
                lastReply = now
                Thread.sleep(forTimeInterval: 0.3)
                continue
            }

            // A failed write means the device is gone (unplugged, or the
            // USB port reset): drop the session and reconnect.
            do {
                try kb.transport.write(Proto.keepalive)

                // Follow the dial's Profile menu.
                if now.timeIntervalSince(lastProfileQuery) >= 1 {
                    lastProfileQuery = now
                    try kb.transport.write(Proto.packet([0x11, 0x00]))
                }
            } catch {
                return
            }

            // Profiles linked to apps.
            if now.timeIntervalSince(lastFrontCheck) >= 0.5 {
                lastFrontCheck = now
                if let target = switcher.update(frontApp: AutoSwitcher.frontmostBundleID, current: profile, config: cfg),
                   let i = cfg.profileIndex(target) {
                    ProfileSwitch.activate(cfg.profiles[i], keyboard: kb)
                    profile = target
                    neutralise(target)
                    log("profile \(target) « \(cfg.profiles[i].name) » (front app)")
                }
            }

            // A profile key was pressed (D1–D4 or the DisplayPad).
            if let request = ProfileRequest.take(),
               let target = ProfileRequest.resolve(request, current: profile, config: cfg),
               let i = cfg.profileIndex(target), target != profile {
                ProfileSwitch.activate(cfg.profiles[i], keyboard: kb)
                profile = target
                neutralise(target)
                log("profile \(target) « \(cfg.profiles[i].name) » (profile key)")
            }

            // Pick up button changes made in the app without a restart.
            if now.timeIntervalSince(lastConfigCheck) >= 1 {
                lastConfigCheck = now
                // Night mode: the built-in "Off" lighting slot, then back to the
                // profile's own slot. A slot switch only; nothing is saved.
                let night = NightMode.active
                if night != nightApplied {
                    let own = cfg.profileIndex(profile).map { ProfileSwitch.slot(for: cfg.profiles[$0]) } ?? 0
                    // The settings write (dial and D1–D4 screens) brings the
                    // key lighting back on, so at night it goes first and
                    // the Off slot last; in the morning the profile's slot
                    // first, then the screens back to following the lighting.
                    let slot = night ? FirmwareLighting.Effect.off.slot : own
                    if night { kb.setDisplays(off: true) }
                    let reported = kb.switchLighting(profile: UInt8(profile), slot: slot)
                    if reported != slot { log("night mode: the keyboard reports lighting slot \(reported.map(String.init) ?? "?"), not \(slot)") }
                    if !night && nightApplied != nil { kb.setDisplays(off: false) }
                    if nightApplied != nil || night { log(night ? "night mode: lights off" : "night mode: lights back on") }
                    nightApplied = night
                }
                let stamp = configDate()
                if stamp != configStamp {
                    configStamp = stamp
                    cfg = Config.load()
                    log("config reloaded")
                }
            }

            // Drain everything the keyboard has to say.
            while let packet = kb.transport.read(timeout: 0.05) {
                if verbose {
                    stderr("rx \(packet.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")
                }
                if packet[0] == 0x11 && packet.count > 1 && (packet[1] == 0x14 || packet[1] == 0x00) { lastReply = now }
                if packet[0] == 0x11 && packet.count > 10 && packet[1] == 0x00, (1...5).contains(packet[10]) {
                    let p = Int(packet[10])
                    if p != profile {
                        profile = p
                        log("profile \(p) active (from the keyboard)")
                        neutralise(p)
                        if let i = cfg.profileIndex(p), let raw = cfg.profiles[i].dialMode,
                           let mode = Proto.MainMode(rawValue: raw) {
                            kb.setMainMode(mode)
                        }
                    }
                }
                guard packet[0] == 0x01 else { continue }
                let pressed = DeviceState.pressedButton(in: packet)
                if let p = pressed, p != lastButton, now.timeIntervalSince(lastAction) >= 0.8 {
                    lastAction = now
                    let btn = cfg.buttons(for: profile)[p]
                    log("D\(p + 1) pressed — \(btn.name ?? btn.action.type.rawValue): \(btn.action.value)")
                    ActionRunner.run(btn.action)
                }
                lastButton = pressed
            }

            // The keyboard answers the keep-alive every second; silence for
            // 6 s means the handle is stale (e.g. replugged on another port).
            if now.timeIntervalSince(lastReply) > 6 { return }

            if cfg.monitorMode, now.timeIntervalSince(lastMetrics) >= 0.5 {
                lastMetrics = now
                let m = Metrics.latest()
                kb.sendMetric(index: 0, value: m.cpu)
                kb.sendMetric(index: 1, value: m.gpu)
                kb.sendMetric(index: 2, value: m.disk)
                kb.sendMetric(index: 3, value: m.networkMBs)
                kb.sendMetric(index: 4, value: m.ram)
                if let v = m.volumeLevel { kb.sendVolume(v) }
            }

            if now.timeIntervalSince(lastClock) >= 60 {
                lastClock = now
                kb.setTime(style: cfg.clockStyle == "digital" ? 0x01 : 0x00,
                           twelveHour: cfg.clockFormat == "12h")
            }

            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    /// `everest sniff [seconds]` — raw packet dump, for reverse engineering
    /// and debugging.
    static func sniff(_ args: [String]) {
        let seconds = args.first.flatMap(Double.init) ?? 10
        let kb: Keyboard
        do { kb = try Keyboard(allowUnsupported: true) } catch { fail("Error: \(error)") }
        defer { kb.close() }
        stderr("Sniffing vendor packets for \(Int(seconds))s — press numpad buttons, turn the dial…")
        let deadline = Date().addingTimeInterval(seconds)
        var last = Date.distantPast
        while Date() < deadline {
            if Date().timeIntervalSince(last) > 1.0 {
                try? kb.transport.write(Proto.keepalive)
                last = Date()
            }
            if let p = kb.transport.read(timeout: 0.1) {
                let hex = p.map { String(format: "%02x", $0) }.joined(separator: " ")
                print("[\(String(format: "%8.3f", Date().timeIntervalSince1970))] \(hex)")
            }
        }
    }
}
