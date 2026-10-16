import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// The Mac's screens during night mode, a thread of `everest listen`.
///
/// `pmset displaysleepnow` only lasts until the next sign of activity: a
/// nudged mouse, or a remote-control session (RustDesk and the like hold a
/// "prevent display sleep" assertion and inject input), wakes them.
/// - Woken on the desk (no remote session): the whole night mode ends, as
///   with the night key. If the session is still locked 20 s later (nobody
///   there to unlock it), night mode starts again.
/// - Held awake by a remote session: their gamma tables turn black, so the
///   screens look off on the desk but the picture sent away is untouched
///   (the tables apply after capture); when the session lets go, they sleep
///   again. macOS restores the tables by itself when this process ends, so a
///   crash or a quit never leaves the screens black.
///
/// A night begun before the last restart is not enforced (the daemon ends
/// it as it starts).
enum NightScreens {
    private static func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        stderr("\(f.string(from: Date())) screens: \(s)")
    }

    static func start() {
        let t = Thread { run() }
        t.name = "NightScreens"
        t.start()
    }

    enum Step: Equatable { case none, wake, blackOut, restore, restoreAndSleep }

    /// What to do on one tick. `enforce`: night mode (from this boot) is on,
    /// with "screens too", past the grace period for the key's own sleep.
    /// `awakeFor`: how long the screens have been on (nil: asleep); a second
    /// leaves a remote session time to show its assertion.
    static func step(enforce: Bool, awakeFor: TimeInterval?, remote: Bool, blackedOut: Bool) -> Step {
        guard enforce else { return blackedOut ? .restore : .none }
        if remote { return awakeFor != nil && !blackedOut ? .blackOut : .none }
        if blackedOut { return .restoreAndSleep }
        return (awakeFor ?? 0) >= 1 ? .wake : .none
    }

    enum Trial: Equatable { case wait, over, nightAgain }

    /// After a wake on the desk: unlocked, the night is over; still locked
    /// after 20 s, or a remote session meanwhile, night mode again.
    static func trial(elapsed: TimeInterval, locked: Bool, remote: Bool) -> Trial {
        if remote { return .nightAgain }
        if !locked { return .over }
        return elapsed >= 20 ? .nightAgain : .wait
    }

    private static func run() {
        var nightSince: Date?
        var displays = true
        var configStamp: Date?
        var blackedOut = false
        var awakeSince: Date?
        var remoteName: String?
        var wokenAt: Date?   // night mode ended by a wake, on trial

        while true {
            autoreleasepool {
                let now = Date()
                let state = NightMode.read()
                let night = state?.active == true && state?.bootTime == bootTime()
                if night {
                    if nightSince == nil { nightSince = now }
                    wokenAt = nil   // the night key again
                    let stamp = Config.fileStamp
                    if stamp != configStamp { configStamp = stamp; displays = Config.load().nightSleepsDisplays }
                } else {
                    nightSince = nil
                }

                if let t = wokenAt {
                    let remote = remoteSession()
                    switch trial(elapsed: now.timeIntervalSince(t), locked: sessionLocked(), remote: remote != nil) {
                    case .wait: break
                    case .over:
                        log("session unlocked — night mode over")
                        wokenAt = nil
                    case .nightAgain:
                        log(remote.map { "\($0) connected — night mode again" } ?? "still locked after 20 s — night mode again")
                        wokenAt = nil
                        NightMode.begin()
                    }
                }

                // The night key puts the screens to sleep itself after 4 s,
                // once the keyboard and the pad have gone dark.
                let enforce = displays && nightSince.map { now.timeIntervalSince($0) >= 6 } == true
                let awake = enforce || blackedOut ? anyDisplayAwake() : false
                if awake { awakeSince = awakeSince ?? now } else { awakeSince = nil }
                let remote = enforce ? remoteSession() : nil

                switch step(enforce: enforce, awakeFor: awakeSince.map { now.timeIntervalSince($0) },
                            remote: remote != nil, blackedOut: blackedOut) {
                case .none:
                    if blackedOut, enforce { blackOut(onlyIfLost: true) }
                case .wake:
                    log("woken on the desk — night mode off, back on in 20 s unless the session is unlocked")
                    wokenAt = now
                    awakeSince = nil
                    NightMode.end()
                case .blackOut:
                    remoteName = remote
                    log("\(remote ?? "?") keeps them awake — black until the night key")
                    blackOut(onlyIfLost: false)
                    blackedOut = true
                case .restore:
                    CGDisplayRestoreColorSyncSettings()
                    blackedOut = false
                    log("night mode off — colours restored")
                case .restoreAndSleep:
                    log("\(remoteName ?? "remote session") let go — back to sleep")
                    // Asleep first, then the colours back, so they never flash.
                    sleepDisplays(wait: true)
                    CGDisplayRestoreColorSyncSettings()
                    blackedOut = false
                }
            }
            Thread.sleep(forTimeInterval: nightSince == nil && !blackedOut && wokenAt == nil ? 1 : 0.5)
        }
    }

    // MARK: macOS

    /// The current boot, to tell a night begun before a restart.
    static func bootTime() -> Int? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return tv.tv_sec
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    /// The login session shows the lock screen.
    private static func sessionLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func anyDisplayAwake() -> Bool {
        onlineDisplays().contains { CGDisplayIsAsleep($0) == 0 }
    }

    /// A process other than macOS's own holding the screens awake: a remote
    /// session (RustDesk, Screen Sharing, TeamViewer…), or failing that
    /// anything else that wants them on, which is left alone too.
    static func remoteSession() -> String? {
        var byPID: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byPID) == kIOReturnSuccess,
              let all = byPID?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        let system: Set<String> = ["powerd", "WindowServer", "loginwindow", "coreaudiod"]
        for (_, list) in all {
            for a in list where (a[kIOPMAssertionTypeKey] as? String) == kIOPMAssertPreventUserIdleDisplaySleep
                && (a["AssertLevel"] as? Int ?? 0) > 0 {
                let name = a["Process Name"] as? String ?? "?"
                if !system.contains(name) { return name }
            }
        }
        return nil
    }

    private static func sleepDisplays(wait: Bool = false) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        if wait { p.waitUntilExit(); Thread.sleep(forTimeInterval: 2) }
    }

    /// Black gamma on every screen. `onlyIfLost`: only where something
    /// (a reconfiguration, Night Shift, a newly plugged screen) undid it.
    private static func blackOut(onlyIfLost: Bool) {
        let zero: [CGGammaValue] = [0, 0]
        for id in onlineDisplays() {
            if onlyIfLost {
                var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
                var n: UInt32 = 0
                if CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &n) == .success,
                   !(r.prefix(Int(n)) + g.prefix(Int(n)) + b.prefix(Int(n))).contains(where: { $0 > 0 }) { continue }
            }
            CGSetDisplayTransferByTable(id, 2, zero, zero, zero)
        }
    }
}
