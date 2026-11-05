import Foundation

/// The app's version. `number` is the only place it is written: make-app.sh
/// reads it for Info.plist and stamps the build (the commit count, `+` when
/// built from uncommitted changes), so the window shows which build is running.
enum AppVersion {
    static let number = "0.2.1"
    static let bundleIdentifier = "com.mrrcalendar.everest"
    /// The identifier before 0.2.0: still found in saved D1 actions.
    static let legacyBundleIdentifier = "local.everest-mac"
    static let repositoryURL = URL(string: "https://github.com/Avalonia-SaaS/everest-mac")!
    /// The project this one started from.
    static let originalRepositoryURL = URL(string: "https://github.com/alouisy/everest-mac")!

    /// How to connect MRR Calendar, from System › MRRCalendar.
    static let mrrCalendarGuideURL = URL(string: "https://mrrcalendar.com/guides/show-mrr-sales-commits-on-displaypad-stream-deck?ref=everest-app")!

    /// Sent to MRR Calendar, whose admin shows which version a token uses.
    static var userAgent: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "everest-mac/\(number) (macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion))"
    }

    /// Build stamp of the running app bundle, nil for a plain `swift build`.
    static var build: String? {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// "0.1.0 (42)", or "0.1.0 (dev)" outside an app bundle.
    static var display: String { "\(number) (\(build ?? "dev"))" }
}
