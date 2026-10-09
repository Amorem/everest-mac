import Foundation

/// Claude and Codex usage limits, read from CodexBar (github.com/steipete/CodexBar,
/// MIT) when it is installed. CodexBar already polls claude.ai and OpenAI with
/// the user's sign-in and writes a small JSON snapshot for its widgets; reading
/// that file costs nothing and sends nothing. It is CodexBar's internal widget
/// format (`WidgetSnapshot` in its sources), not a versioned API, so every field
/// is optional here: anything missing shows as "—" instead of failing.
enum CodexBarUsage {
    /// One limit window: the 5-hour session, or the week.
    struct Window: Equatable {
        var usedPercent: Double
        var windowMinutes: Int?
        var resetsAt: Date?
    }

    struct Provider: Equatable {
        var updatedAt: Date?
        /// Shortest window first (Claude: session, then week; Codex: week only).
        var windows: [Window]
    }

    static var file: URL {
        if let override = ProcessInfo.processInfo.environment["EVEREST_CODEXBAR_SNAPSHOT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/Y5PE65HELJ.com.steipete.codexbar/widget-snapshot.json")
    }

    /// Older than this, a value is shown as unknown (CodexBar quit or stuck).
    static let staleAfter: TimeInterval = 3 * 3600

    private static let lock = NSLock()
    private static var cached: (stamp: Date, providers: [String: Provider])?

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: file.path) }

    enum Span { case session, week }

    /// The 5-hour session (the shortest window under a day) or the week (the
    /// 7-day window, else the longest one of a day or more).
    static func window(_ span: Span, of id: String, now: Date = Date()) -> Window? {
        guard let p = provider(id, now: now) else { return nil }
        switch span {
        case .session:
            return p.windows.first { ($0.windowMinutes ?? .max) < 1440 }
        case .week:
            return p.windows.first { $0.windowMinutes == 10080 }
                ?? p.windows.last { ($0.windowMinutes ?? 0) >= 1440 }
        }
    }

    /// The provider's windows, re-read only when CodexBar rewrote the file.
    static func provider(_ id: String, now: Date = Date()) -> Provider? {
        lock.lock()
        defer { lock.unlock() }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard let stamp else { cached = nil; return nil }
        if cached?.stamp != stamp {
            cached = (stamp, (try? Data(contentsOf: file)).map(parse) ?? [:])
        }
        guard let p = cached?.providers[id] else { return nil }
        if let at = p.updatedAt, now.timeIntervalSince(at) > staleAfter { return nil }
        return p
    }

    /// Lenient parse of the widget snapshot: `entries[].provider`, `updatedAt`
    /// and the `primary` / `secondary` / `tertiary` windows.
    static func parse(_ data: Data) -> [String: Provider] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else { return [:] }
        let iso = ISO8601DateFormatter()
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) } }
        var out: [String: Provider] = [:]
        for e in entries {
            guard let id = e["provider"] as? String else { continue }
            var windows: [Window] = []
            for key in ["primary", "secondary", "tertiary"] {
                guard let w = e[key] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
                windows.append(Window(usedPercent: max(0, min(100, used)),
                                      windowMinutes: (w["windowMinutes"] as? NSNumber)?.intValue,
                                      resetsAt: date(w["resetsAt"])))
            }
            windows.sort { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
            out[id] = Provider(updatedAt: date(e["updatedAt"]), windows: windows)
        }
        return out
    }
}
