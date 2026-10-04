import Foundation

/// Languages the interface is translated into. To add one: add a case here,
/// a `Strings.<code>.swift` catalog next to the others, and run the tests —
/// `LocalizationTests` checks that every key of the English catalog is there.
enum Language: String, CaseIterable, Codable, Identifiable {
    // Covers the keyboard layouts Everest Max is sold with: US/UK (English),
    // French, German, Italian, Nordic (Norwegian, Swedish, Danish, Finnish),
    // Spanish, Portuguese, Hebrew and Korean.
    case en, fr, de, es, it, pt, nb, sv, da, fi, ko, he

    var id: String { rawValue }

    /// The language's name in itself — it is never translated, so a user who
    /// ended up in the wrong language can still find theirs.
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .nb: return "Norsk bokmål"
        case .sv: return "Svenska"
        case .da: return "Dansk"
        case .fi: return "Suomi"
        case .ko: return "한국어"
        case .he: return "עברית"
        }
    }

    /// Hebrew reads right to left: the whole window is mirrored.
    var isRightToLeft: Bool { self == .he }

    var catalog: [String: String] {
        switch self {
        case .en: return L10n.en
        case .fr: return L10n.fr
        case .de: return L10n.de
        case .es: return L10n.es
        case .it: return L10n.it
        case .pt: return L10n.pt
        case .nb: return L10n.nb
        case .sv: return L10n.sv
        case .da: return L10n.da
        case .fi: return L10n.fi
        case .ko: return L10n.ko
        case .he: return L10n.he
        }
    }
}

/// String catalogs and lookup. UI text is never written inline: it is looked
/// up by key with `tr("key", args…)`. A missing key falls back to English,
/// then to the key itself (so a gap is visible rather than blank).
///
/// Arguments are always substituted with positional `%1$@`, `%2$@`… — they
/// are converted to text first, so numbers use `%1$@` too — which lets a
/// translation reorder them.
enum L10n {
    static let fallback = Language.en

    /// The language in use. Written on the main thread only, when the user
    /// changes it; reads from other threads are harmless.
    private(set) static var current: Language = systemLanguage()

    /// First of the user's preferred languages we have a catalog for.
    static func systemLanguage(preferred: [String] = Locale.preferredLanguages) -> Language {
        for tag in preferred {
            var code = String(tag.prefix(2)).lowercased()
            // Norwegian comes as no / nb / nn: one Bokmål catalog serves them.
            if code == "no" || code == "nn" { code = "nb" }
            if code == "iw" { code = "he" }
            if let l = Language(rawValue: code) { return l }
        }
        return fallback
    }

    /// `nil` follows the system language.
    static func use(_ language: Language?) {
        current = language ?? systemLanguage()
    }

    static func string(_ key: String, in language: Language, _ args: [Any] = []) -> String {
        let format = language.catalog[key] ?? fallback.catalog[key] ?? key
        guard !args.isEmpty else { return format }
        let values = args.map { String(describing: $0) as CVarArg }
        return String(format: format, locale: nil, arguments: values)
    }

    /// Names the app itself gave to the default profile and to the factory
    /// D1–D4 keys are stored in the language that was active at the time;
    /// show them in the current one. Names the user typed are left alone.
    static func displayName(_ stored: String) -> String {
        let keys = ["profile.main", "factory.sleep", "factory.activityMonitor"]
        for key in keys where Language.allCases.contains(where: { $0.catalog[key] == stored }) {
            return tr(key)
        }
        return stored
    }

    /// Number of `%n$@` placeholders in a format string (for the tests).
    static func placeholders(in format: String) -> Set<Int> {
        var found = Set<Int>()
        let chars = Array(format)
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 1 < chars.count {
                var j = i + 1
                var digits = ""
                while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
                if !digits.isEmpty, j + 1 < chars.count, chars[j] == "$", chars[j + 1] == "@",
                   let n = Int(digits) {
                    found.insert(n)
                    i = j + 2
                    continue
                }
            }
            i += 1
        }
        return found
    }
}

/// Localised text for the current language.
func tr(_ key: String, _ args: Any...) -> String {
    L10n.string(key, in: L10n.current, args)
}
