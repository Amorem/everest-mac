import AppKit
import SwiftUI

// Lighting: colours, built-in effects and Mac-rendered effects.
extension EverestModel {
    // MARK: - Colours

    func editColor(_ target: ColorTarget) {
        editing = target
        let c: RGB
        switch target {
        case .palette(let i): c = i < effect.palette.count ? effect.palette[i] : .white
        case .firmware(let i): c = firmwareLighting.color(i)
        case .brush: c = brush
        }
        let panel = NSColorPanel.shared
        panel.setTarget(colorTarget)
        panel.setAction(#selector(ColorEditTarget.colorChanged(_:)))
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.color = NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                              blue: CGFloat(c.b) / 255, alpha: 1)
        panel.makeKeyAndOrderFront(nil)
    }

    func setColor(_ rgb: RGB, for target: ColorTarget) {
        switch target {
        case .palette(let i):
            guard i < effect.palette.count else { return }
            updateEffect { $0.palette[i] = rgb }
        case .firmware(let i):
            updateFirmware { fw in
                while fw.colors.count <= i { fw.colors.append(.white) }
                fw.colors[i] = rgb
            }
        case .brush:
            brush = rgb
        }
    }

    func addPaletteColor() {
        let vivid = ["ff2d95", "ffb300", "3dffb0", "00b3ff", "a25bff", "ff5a36", "f5ff3d", "ffffff"]
        let next = RGB(hex: vivid[effect.palette.count % vivid.count]) ?? .white
        guard effect.palette.count < 8 else { return }
        updateEffect { $0.palette.append(next) }
        editColor(.palette(effect.palette.count - 1))
    }

    func removePaletteColor(_ i: Int) {
        guard effect.palette.count > 1, i < effect.palette.count else { return }
        updateEffect { $0.palette.remove(at: i) }
    }

    // MARK: - Firmware lighting

    /// Mutate the built-in effect and push it after a short pause, the way
    /// Base Camp applies and saves on every change.
    func updateFirmware(_ mutate: (inout FirmwareLighting) -> Void) {
        mutate(&firmwareLighting)
        if source == .firmware { scheduleFirmwareApply() }
    }

    func selectFirmware(_ effect: FirmwareLighting.Effect) {
        source = .firmware
        stopPlayer()
        firmwareLighting.effect = effect
        if !effect.modes.contains(firmwareLighting.mode), let first = effect.modes.first {
            firmwareLighting.mode = effect == .wave || effect == .breathing ? .rainbow : first
        }
        scheduleFirmwareApply(delay: 0.05)
    }

    func applyFirmwareNow() {
        source = .firmware
        stopPlayer()
        scheduleFirmwareApply(delay: 0)
    }

    func scheduleFirmwareApply(delay: TimeInterval = 0.35) {
        pendingApply?.cancel()
        let fw = firmwareLighting
        let work = DispatchWorkItem { [weak self] in
            guard let kb = try? Keyboard() else {
                DispatchQueue.main.async {
                    self?.connected = false
                    self?.report(tr("status.previewOnly"), error: true)
                }
                return
            }
            defer { kb.close() }
            kb.wake()
            kb.apply(fw, save: true)
            DispatchQueue.main.async {
                self?.connected = true
                self?.report(tr("status.effectApplied", fw.effect.title))
            }
        }
        pendingApply = work
        device.asyncAfter(deadline: .now() + delay, execute: work)
        persistLightingSoon()
    }

    // MARK: - Mac effects

    func updateEffect(_ mutate: (inout LedEffect) -> Void) {
        mutate(&effect)
        player?.update(effect)
        persistLightingSoon()
    }

    /// Picking a Mac effect switches the board to it straight away.
    func selectEffect(_ kind: LedEffect.Kind) {
        source = .mac
        effect.kind = kind
        if kind != .solid { painting = false }
        if let player {
            player.update(effect)
        } else {
            startPlayer()
        }
        report(tr("status.effectRunningKeyboard", kind.title))
        persistLightingSoon()
    }

    func applyPalettePreset(_ colors: [RGB]) {
        updateEffect { $0.palette = colors }
    }

    func paintKey(_ index: Int) {
        guard effect.perKey[index] != brush else { return }
        if effect.perKey.isEmpty {
            // Start from the current solid colour so unpainted keys stay lit.
            let base = effect.palette.first ?? .white
            var map: [Int: RGB] = [:]
            for i in 0..<LedLayout.mainLedCount where LedLayout.positionTable[i] != nil { map[i] = base }
            effect.perKey = map
        }
        updateEffect { $0.perKey[index] = brush }
    }

    func clearPainting() {
        updateEffect { $0.perKey = [:] }
    }

    func startPlayer() {
        guard player == nil else { return }
        source = .mac
        pendingApply?.cancel()
        let p = LedPlayer(effect: effect)
        p.onConnection = { [weak self] up in
            DispatchQueue.main.async {
                // A firmware block is reported by its own screen, not as "gone".
                guard let self, self.firmwareBlock == nil else { return }
                self.connected = up
                self.report(up ? tr("status.keyboardConnected") : tr("status.keyboardGone"),
                            error: !up)
            }
        }
        player = p
        p.start(fps: 30)
        playing = true
    }

    func stopPlayer() {
        player?.stop()
        player = nil
        playing = false
    }

    func togglePlayback() {
        if playing {
            stopPlayer()
            report(tr("status.animationPaused"))
        } else {
            startPlayer()
            report(tr("status.effectRunningKeyboard", effect.kind.title))
        }
    }

    /// Show the current design once and keep it in the custom slot's flash,
    /// so it survives without the app (static designs only).
    func saveStaticToKeyboard() {
        stopPlayer()
        let e = effect
        runDevice(tr("status.saving")) { kb in
            LedPlayer.applyOnce(e, keyboard: kb)
            kb.send(FirmwareLighting.saveFlash(slot: 6), wait: 0.5)
            return tr("status.frozen")
        }
    }
}

// MARK: - Display names

extension FirmwareLighting.Effect {
    var title: String {
        switch self {
        case .staticColor: return tr("fx.static")
        case .wave: return tr("fx.wave")
        case .tornado: return tr("fx.tornado")
        case .breathing: return tr("fx.breathing")
        case .reactive: return tr("fx.reactive")
        case .matrix: return tr("fx.matrix")
        case .yeti: return tr("fx.yeti")
        case .off: return tr("fx.off")
        }
    }

    var icon: String {
        switch self {
        case .staticColor: return "circle.fill"
        case .wave: return "water.waves"
        case .tornado: return "tornado"
        case .breathing: return "wind"
        case .reactive: return "hand.tap.fill"
        case .matrix: return "cloud.rain.fill"
        case .yeti: return "dot.radiowaves.left.and.right"
        case .off: return "power"
        }
    }

    var blurb: String {
        switch self {
        case .staticColor: return tr("fx.static.desc")
        case .wave: return tr("fx.wave.desc")
        case .tornado: return tr("fx.tornado.desc")
        case .breathing: return tr("fx.breathing.desc")
        case .reactive: return tr("fx.reactive.desc")
        case .matrix: return tr("fx.matrix.desc")
        case .yeti: return tr("fx.yeti.desc")
        case .off: return tr("fx.off.desc")
        }
    }
}

extension FirmwareLighting.ColorMode {
    var title: String {
        switch self {
        case .single: return tr("colormode.single")
        case .dual: return tr("colormode.dual")
        case .quad: return tr("colormode.quad")
        case .rainbow: return tr("colormode.rainbow")
        case .withBackground: return tr("colormode.withBackground")
        }
    }
}

extension LedEffect.Kind {
    var title: String {
        switch self {
        case .solid: return tr("macfx.solid")
        case .gradient: return tr("macfx.gradient")
        case .rainbow: return tr("macfx.spectrum")
        case .wave: return tr("macfx.waves")
        case .breathe: return tr("fx.breathing")
        case .aurora: return tr("macfx.aurora")
        case .plasma: return tr("macfx.plasma")
        case .vortex: return tr("macfx.spiral")
        case .ripple: return tr("macfx.ripples")
        case .fire: return tr("macfx.fire")
        case .rain: return tr("macfx.rain")
        case .starlight: return tr("macfx.stars")
        case .scanner: return tr("macfx.scanner")
        case .equalizer: return tr("macfx.equalizer")
        case .off: return tr("fx.off")
        }
    }

    var icon: String {
        switch self {
        case .solid: return "paintbrush.pointed.fill"
        case .gradient: return "circle.lefthalf.filled"
        case .rainbow: return "rainbow"
        case .wave: return "water.waves"
        case .breathe: return "wind"
        case .aurora: return "sparkles"
        case .plasma: return "drop.halffull"
        case .vortex: return "hurricane"
        case .ripple: return "dot.radiowaves.left.and.right"
        case .fire: return "flame.fill"
        case .rain: return "cloud.drizzle.fill"
        case .starlight: return "star.fill"
        case .scanner: return "arrow.left.and.right"
        case .equalizer: return "chart.bar.fill"
        case .off: return "power"
        }
    }
}

struct PalettePreset: Identifiable {
    let name: String
    let colors: [RGB]
    var id: String { name }

    static var all: [PalettePreset] { [
        PalettePreset(name: tr("macfx.aurora"), colors: ["00ffaa", "008cff", "aa3cff"]),
        PalettePreset(name: tr("palette.neon"), colors: ["ff2d95", "7a5cff", "00e5ff"]),
        PalettePreset(name: tr("palette.sunset"), colors: ["ff3d3d", "ff8a00", "ffd23f", "ff2d95"]),
        PalettePreset(name: tr("palette.ocean"), colors: ["00e0ff", "0066ff", "00ffc8"]),
        PalettePreset(name: tr("palette.cyberpunk"), colors: ["fcee0a", "ff003c", "00f0ff"]),
        PalettePreset(name: tr("palette.forest"), colors: ["b6ff3d", "00c46a", "00806b"]),
        PalettePreset(name: tr("palette.ember"), colors: ["ff1e00", "ff7a00", "ffd000"]),
        PalettePreset(name: tr("palette.ice"), colors: ["ffffff", "8fe3ff", "2d6cff"]),
        PalettePreset(name: tr("palette.vapor"), colors: ["ff71ce", "01cdfe", "05ffa1", "b967ff"]),
    ] }

    init(name: String, colors: [String]) {
        self.name = name
        self.colors = colors.compactMap { RGB(hex: $0) }
    }
}
