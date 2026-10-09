import Foundation

/// The app's version. `number` is the only place it is written: make-app.sh
/// reads it for Info.plist and stamps the build (the commit count, `+` when
/// built from uncommitted changes), so the window shows which build is running.
enum AppVersion {
    static let number = "0.1.0"

    /// Build stamp of the running app bundle, nil for a plain `swift build`.
    static var build: String? {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// "0.1.0 (42)", or "0.1.0 (dev)" outside an app bundle.
    static var display: String { "\(number) (\(build ?? "dev"))" }
}
