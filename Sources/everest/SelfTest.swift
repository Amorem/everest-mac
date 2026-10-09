import Foundation

/// `everest selftest [--lighting] [--upload <1-4>]` — talks to the real
/// keyboard to catch communication regressions. `everest selftest --pad
/// [--draw]` does the same for the DisplayPad (see `runPad`).
///
/// - default: read-only. Opens the device, checks that every query is answered
///   by the right reply (the keyboard sends each answer to every program that
///   has it open, so the next packet is not necessarily yours), that the handle can be closed and reopened, and that the
///   values make sense.
/// - `--lighting`: switches the lighting slot twice, checks the keyboard
///   reports it, and puts the original slot back. Nothing is saved to flash.
/// - `--upload N`: sends a test picture to display key N (about 20 s), then
///   resets that key to its factory picture. Writes to flash; the same
///   mechanism as an icon upload from the app.
enum SelfTest {
    private static var passed = 0, failed = 0, skipped = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1 } else { failed += 1 }
        print("  \(ok ? "✓" : "✗") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func skip(_ name: String, _ why: String) {
        skipped += 1
        print("  – \(name) — skipped: \(why)")
    }

    private static func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
        exit(failed == 0 ? 0 : 1)
    }

    /// `11 00` answer: (firmware byte, active profile, active lighting slot).
    private static func info(_ kb: Keyboard) -> (fw: UInt8, profile: UInt8, slot: UInt8)? {
        try? kb.transport.write(Proto.packet([0x11, 0x00]))
        guard let r = kb.waitReply(0x00, timeout: 1.0), r.count > 11 else { return nil }
        return (r[4], r[10], r[11])
    }

    static func run(_ args: [String]) {
        if args.contains("--pad") { runPad(draw: args.contains("--draw")) }
        let doLighting = args.contains("--lighting")
        var uploadKey: Int?
        if let i = args.firstIndex(of: "--upload") {
            guard i + 1 < args.count, let n = Int(args[i + 1]), (1...4).contains(n) else { fail("--upload needs a key 1-4") }
            uploadKey = n - 1
        }

        print("Reading the keyboard (read-only)")
        guard let kb = try? Keyboard() else {
            check("keyboard found (3282:0001)", false, "is it plugged in, and not held by another program?")
            finish()
        }
        check("keyboard found and opened", true)
        kb.wake()

        // Layout (reply to 11 12).
        if let code = kb.layoutCode {
            let layout = KeyboardLayout(firmwareCode: code)
            check("layout answered", true, "code \(code) → \(layout.title)")
        } else {
            check("layout answered", false, "no reply to 11 12")
        }

        // Firmware info, active profile.
        guard let first = info(kb) else {
            check("firmware info answered (11 00)", false)
            kb.close(); finish()
        }
        check("firmware info answered (11 00)", true, String(format: "firmware %x, profile %d, lighting slot %d", first.fw, first.profile, first.slot))
        check("firmware version looks real", first.fw >= 0x10 && first.fw != 0xFF)
        check("active profile is 1…5", (1...5).contains(first.profile))
        check("lighting slot is 0…8", first.slot <= 8)

        // State report (11 14).
        if let state = kb.state() {
            let mode = Proto.MainMode.allCases.first { $0.menuByte == state.modeByte }
            check("state report parsed (11 14)", true, "\(state.attachedSummary), dial: \(mode?.rawValue ?? String(format: "0x%02x", state.modeByte))")
            check("dial mode is a known menu", mode != nil)
        } else {
            check("state report parsed (11 14)", false)
        }

        // Each query must be answered by its own reply, whatever else is on
        // the channel (the daemon's traffic reaches every open session). The
        // keyboard has a single command buffer: queries sent back to back are
        // answered only for the last one, so they go one at a time.
        for cmd: UInt8 in [0x12, 0x00, 0x14] {
            try? kb.transport.write(Proto.packet([0x11, cmd]))
            let reply = kb.waitReply(cmd, timeout: 1.0)
            check("query 11 \(String(format: "%02x", cmd)) gets its own reply", reply != nil)
        }
        kb.transport.flush()
        let again = info(kb)
        check("the firmware byte is not confused with another reply", again?.fw == first.fw,
              String(format: "%x then %x", first.fw, again?.fw ?? 0))

        // Keep-alive stays answered (a stale handle stops answering).
        var answered = 0
        for _ in 0..<8 {
            try? kb.transport.write(Proto.keepalive)
            if kb.waitReply(0x14, timeout: 1.0) != nil { answered += 1 }
        }
        check("keep-alive answered 8/8", answered == 8, "\(answered)/8")

        // Closing and reopening the HID session works, and says the same thing.
        kb.close()
        var reopened = 0
        var sameLayout = true
        for _ in 0..<3 {
            if let k = try? Keyboard() {
                k.wake()
                if info(k) != nil { reopened += 1 }
                if k.layoutCode != kb.layoutCode { sameLayout = false }
                k.close()
            }
        }
        check("closed and reopened 3 times", reopened == 3, "\(reopened)/3")
        check("layout code stable across sessions", sameLayout)

        // Optional: lighting slot round-trip.
        if doLighting { lightingTest(original: first) }

        // Optional: picture upload.
        if let key = uploadKey { uploadTest(key: key, fwByte: first.fw) }

        finish()
    }

    private static func lightingTest(original: (fw: UInt8, profile: UInt8, slot: UInt8)) {
        print("\nLighting slot round-trip (not saved to flash)")
        guard let kb = try? Keyboard() else { check("reopen for lighting", false); return }
        defer { kb.close() }
        kb.wake()
        for effect in [FirmwareLighting.Effect.staticColor, .wave, .breathing] {
            var l = FirmwareLighting(); l.effect = effect
            kb.apply(l, save: false)
            usleep(300_000)
            let now = info(kb)
            check("\(effect.title): slot \(effect.slot) reported", now?.slot == effect.slot, "reported \(now.map { String($0.slot) } ?? "nothing")")
        }
        // Put the user's lighting back.
        kb.send(FirmwareLighting.switchProfile(original.profile, slot: original.slot), wait: 0.4)
        usleep(300_000)
        let back = info(kb)
        check("original slot \(original.slot) restored", back?.slot == original.slot && back?.profile == original.profile)
    }

    private static func uploadTest(key: Int, fwByte: UInt8) {
        print("\nPicture upload to D\(key + 1) (writes flash; the key is reset afterwards)")
        guard fwByte >= 0x57 else {
            skip("upload", "firmware \(String(format: "%x", fwByte)) is older than 57 and takes about half an hour per picture")
            return
        }
        guard let kb = try? Keyboard() else { check("reopen for upload", false); return }
        defer { kb.close() }
        kb.wake()
        let profile = Int(kb.currentProfile())
        // A diagonal gradient: not a flat colour, so a wrong byte order shows.
        var image = [UInt8]()
        for y in 0..<72 { for x in 0..<72 {
            let r = x * 31 / 71, g = y * 63 / 71, b = (71 - x) * 31 / 71
            let v = UInt16(r << 11 | g << 5 | b)
            image.append(UInt8(v & 0xFF)); image.append(UInt8(v >> 8))
        } }
        let start = Date()
        var lastPct = -1
        do {
            try kb.uploadIcon(button: key, image: image, slot: profile) { pct in
                if pct / 25 != lastPct / 25 { lastPct = pct; stderr("    \(pct) %") }
            }
            let seconds = Date().timeIntervalSince(start)
            check("transfer completed", true, String(format: "%.0f s", seconds))
            check("transfer took under 60 s", seconds < 60, "the descriptor must be accepted on a quick re-send, not after a full retry")
        } catch {
            check("transfer completed", false, "\(error.localizedDescription)")
        }
        // Back to the factory picture, and neutralise the factory shortcut it brings back.
        kb.send(Proto.resetNumpadPics(1 << UInt8(key), slot: profile), wait: 0.6)
        kb.neutraliseKeyActions()
        check("keyboard still answers after the upload", info(kb) != nil)
    }

    // MARK: DisplayPad

    /// Read-only by default: host mode, firmware gate, queries matched to their
    /// replies, reopening, the picture interface, and the allow-list. With
    /// `--draw`, a test pattern on key 12 in RAM, then the configured picture
    /// back (nothing is written to the pad's flash).
    static func runPad(draw: Bool) -> Never {
        print("Reading the DisplayPad (\(draw ? "draws on key 12, RAM only" : "read-only"))")
        // Keep the daemon off the command channel meanwhile.
        PadBusy.set()
        defer { PadBusy.clear() }
        guard DisplayPad.isPresent else {
            check("DisplayPad on the USB bus (3282:0009)", false, "plugged in? straight into the Mac, not a hub")
            PadBusy.clear(); finish()
        }
        check("DisplayPad on the USB bus", true)

        let started = Date()
        let pad: DisplayPad
        do {
            pad = try DisplayPad(allowUnsupported: true)
        } catch {
            check("host mode answered (11 80)", false, "\(error)")
            PadBusy.clear(); finish()
        }
        check("host mode answered (11 80)", true, String(format: "%.1f s", Date().timeIntervalSince(started)))
        if let v = pad.firmware {
            check("firmware info answered (11 00)", true, "firmware \(PadProto.firmwareString(v))")
            check("firmware is the tested one", v == PadProto.supportedFirmware,
                  "tested: \(PadProto.firmwareString(PadProto.supportedFirmware))")
        } else {
            check("firmware info answered (11 00)", false)
        }

        // Each query must get its own reply, even with other programs talking.
        let level = try? pad.brightness()
        check("brightness answered (12 00 00 01)", level != nil, level.map { "\($0) %" } ?? "")
        let sleep = try? pad.request(PadProto.sleepQuery, echo: 2, timeout: 0.6)
        check("screen sleep answered (22 00 00 01)", sleep != nil)
        var matched = 0
        for _ in 0..<4 {
            if (try? pad.request(PadProto.firmwareInfo, echo: 2, timeout: 0.6)).flatMap({ $0 }).flatMap(PadProto.firmwareVersion) != nil { matched += 1 }
            if (try? pad.brightness()).flatMap({ $0 }) != nil { matched += 1 }
        }
        check("alternating queries get their own replies", matched == 8, "\(matched)/8")

        // The allow-list stops dangerous packets before they are written.
        var refused = false
        do { try pad.send(PadProto.packet([0x30, 0xAA, 0x55])) } catch DisplayPad.PadError.refused { refused = true } catch {}
        check("firmware command refused before sending", refused)

        // The picture interface opens (exclusive) and is released.
        do {
            let pipe = try PadPixelPipe()
            pipe.close()
            check("picture interface opened and released (IOUSBHost, interface 1)", true)
        } catch {
            check("picture interface opened and released (IOUSBHost, interface 1)", false, "\(error)")
        }

        if draw {
            let key = PadProto.keyCount - 1
            var pattern = [UInt8]()
            for y in 0..<PadProto.keySide {
                for _ in 0..<PadProto.keySide {
                    // Red top row, green bottom row, blue elsewhere: the whole
                    // picture must arrive (see docs/DISPLAYPAD.md, Pixels).
                    pattern += y == 0 ? [0, 0, 255] : y == PadProto.keySide - 1 ? [0, 255, 0] : [255, 0, 0]
                }
            }
            do {
                try pad.setKeyImage(key, bgr: pattern)
                check("test pattern drawn on P12", true, "blue, red top row, green bottom row")
                Thread.sleep(forTimeInterval: 3)
                let cfg = Config.load()
                let b = cfg.padButtons(for: cfg.selectedProfile)[key]
                try pad.setKeyImage(key, bgr: PadDaemon.bgr(for: b, brightness: cfg.padBrightness))
                check("P12 restored", true)
            } catch {
                check("test pattern drawn on P12", false, "\(error)")
            }
        }

        pad.close()
        var reopened = 0
        for _ in 0..<3 {
            if let p = try? DisplayPad(allowUnsupported: true, startup: 2) { reopened += 1; p.close() }
        }
        check("closed and reopened 3 times", reopened == 3, "\(reopened)/3")
        PadBusy.clear()
        finish()
    }
}
