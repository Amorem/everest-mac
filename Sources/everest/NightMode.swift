import CoreAudio
import Foundation

/// Night mode: one key turns everything dark and silent, the same key brings
/// it all back as it was. The state is a small file in the config directory,
/// so the app, the daemon (keyboard and DisplayPad threads) and the CLI all
/// see it, and it survives a restart overnight. Each part reacts on its own:
/// - the keyboard goes to its built-in "Off" lighting slot (a slot switch,
///   nothing is saved to flash), then back to the profile's slot;
/// - the DisplayPad backlight goes to 0 (the screen really switches off),
///   then back to the chosen brightness;
/// - the app pauses Mac-rendered lighting;
/// - the Mac's sound is muted here, and unmuted only if we muted it.
enum NightMode {
    struct State: Codable, Equatable {
        var active: Bool
        /// We muted the output (it was not muted already).
        var mutedByUs = false
        /// Output without a mute control: the volume we set to 0.
        var savedVolume: Float32?
    }

    static var url: URL { Config.directory.appendingPathComponent(".night.json") }

    static func read() -> State? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    }

    static var active: Bool { read()?.active ?? false }

    static func write(_ state: State) {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    /// The night-mode key.
    static func toggle() {
        var state = read() ?? State(active: false)
        if state.active {
            if state.mutedByUs { Audio.setMuted(false) }
            if let v = state.savedVolume { Audio.setVolume(v) }
            state = State(active: false)
        } else {
            state = State(active: true)
            if let muted = Audio.isMuted() {
                if !muted { state.mutedByUs = Audio.setMuted(true) }
            } else if let v = Audio.volume(), v > 0, Audio.setVolume(0) {
                state.savedVolume = v
            }
        }
        write(state)
    }

    /// The default output device: mute where it has a mute control, the
    /// volume scalar otherwise.
    enum Audio {
        private static func device() -> AudioDeviceID? {
            var id = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
            return id
        }

        private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain)
        }

        static func isMuted() -> Bool? {
            guard let dev = device() else { return nil }
            var addr = address(kAudioDevicePropertyMute)
            guard AudioObjectHasProperty(dev, &addr) else { return nil }
            var value = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
            return value != 0
        }

        @discardableResult
        static func setMuted(_ muted: Bool) -> Bool {
            guard let dev = device() else { return false }
            var addr = address(kAudioDevicePropertyMute)
            var value = UInt32(muted ? 1 : 0)
            return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        }

        static func volume() -> Float32? {
            guard let dev = device() else { return nil }
            var addr = address(kAudioDevicePropertyVolumeScalar)
            guard AudioObjectHasProperty(dev, &addr) else { return nil }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
            return value
        }

        @discardableResult
        static func setVolume(_ v: Float32) -> Bool {
            guard let dev = device() else { return false }
            var addr = address(kAudioDevicePropertyVolumeScalar)
            var value = v
            return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        }
    }
}
