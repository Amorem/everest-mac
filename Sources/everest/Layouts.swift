import Foundation

/// The keyboard layouts Base Camp knows for the Everest Max, read from the
/// firmware (`11 12` → byte 4, SDKDLL's GetFWLayout) and mapped to a layout
/// exactly like `CommonHelper.GetFWLayoutLanguage` does.
enum KeyboardLayout: String, CaseIterable, Codable, Identifiable {
    case us, uk, french, german, italian, nordic, spanish, portuguese, hebrew, korean

    var id: String { rawValue }

    /// Two physical shapes: ANSI (wide Enter, `\` at the end of the QWERTY
    /// row, no extra key beside Z) and ISO (tall Enter, `#`, extra key).
    enum Family { case ansi, iso }

    var family: Family {
        switch self {
        case .us, .hebrew, .korean: return .ansi
        default: return .iso
        }
    }

    var title: String {
        switch self {
        case .us: return tr("layout.us")
        case .uk: return tr("layout.uk")
        case .french: return tr("layout.french")
        case .german: return tr("layout.german")
        case .italian: return tr("layout.italian")
        case .nordic: return tr("layout.nordic")
        case .spanish: return tr("layout.spanish")
        case .portuguese: return tr("layout.portuguese")
        case .hebrew: return tr("layout.hebrew")
        case .korean: return tr("layout.korean")
        }
    }

    /// Firmware layout code → layout. Unknown codes fall back to US, like
    /// Base Camp.
    init(firmwareCode: Int) {
        switch firmwareCode {
        case 4: self = .uk
        case 5: self = .french
        case 3: self = .german
        case 8: self = .italian
        case 11: self = .nordic
        case 15: self = .spanish
        case 12: self = .portuguese
        case 13: self = .hebrew
        case 22: self = .korean
        default: self = .us
        }
    }

    /// macOS input sources that match the keycaps, best first (ids of
    /// `com.apple.keylayout.*`, or an input-method id).
    var macInputSources: [String] {
        switch self {
        case .us: return ["US", "ABC"]
        case .uk: return ["British-PC", "British"]
        case .french: return ["French-PC", "French"]
        case .german: return ["German"]
        case .italian: return ["Italian-Pro", "Italian"]
        case .nordic: return ["Norwegian", "Swedish-Pro", "Swedish", "Danish", "Finnish"]
        case .spanish: return ["Spanish-ISO", "Spanish"]
        case .portuguese: return ["Portuguese", "Brazilian-Pro"]
        case .hebrew: return ["Hebrew-PC", "Hebrew"]
        case .korean: return ["com.apple.inputmethod.Korean.2SetKorean"]
        }
    }
}
