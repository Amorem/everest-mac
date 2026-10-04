import XCTest
@testable import everest

/// The translations: every language must have every key, with the same
/// placeholders, so a missing string is caught here and not by a user.
final class LocalizationTests: XCTestCase {
    private var english: [String: String] { Language.en.catalog }

    override func tearDown() {
        L10n.use(nil)
    }

    func testEveryLanguageHasEveryKey() {
        for lang in Language.allCases {
            let missing = Set(english.keys).subtracting(lang.catalog.keys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(lang.rawValue) is missing: \(missing.prefix(10))")
            let extra = Set(lang.catalog.keys).subtracting(english.keys).sorted()
            XCTAssertTrue(extra.isEmpty, "\(lang.rawValue) has keys English lacks: \(extra.prefix(10))")
        }
    }

    func testNoEmptyTranslations() {
        for lang in Language.allCases {
            for (key, value) in lang.catalog {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(lang.rawValue).\(key) is empty")
            }
        }
    }

    func testPlaceholdersMatchEnglish() {
        for lang in Language.allCases {
            for (key, value) in lang.catalog {
                let expected = L10n.placeholders(in: english[key] ?? "")
                XCTAssertEqual(L10n.placeholders(in: value), expected, "\(lang.rawValue).\(key): placeholders differ from English")
                // Untranslated positional leftovers such as a bare %@ would print garbage.
                XCTAssertFalse(value.replacingOccurrences(of: "%%", with: "").contains("%@"),
                               "\(lang.rawValue).\(key): use positional %1$@")
            }
        }
    }

    func testFormattingSubstitutesEveryArgument() {
        for lang in Language.allCases {
            XCTAssertEqual(L10n.string("firmware.block.detected", in: lang, ["56"]).contains("56"), true, lang.rawValue)
            let s = L10n.string("status.iconSent", in: lang, [2, 21])
            XCTAssertTrue(s.contains("D2") && s.contains("21"), "\(lang.rawValue): \(s)")
        }
    }

    func testMissingKeyFallsBackToTheKey() {
        XCTAssertEqual(L10n.string("no.such.key", in: .fr), "no.such.key")
    }

    func testSystemLanguageDetection() {
        XCTAssertEqual(L10n.systemLanguage(preferred: ["fr-FR", "en"]), .fr)
        XCTAssertEqual(L10n.systemLanguage(preferred: ["pt-BR"]), .pt)
        XCTAssertEqual(L10n.systemLanguage(preferred: ["es-419"]), .es)
        XCTAssertEqual(L10n.systemLanguage(preferred: ["ja-JP", "es-ES"]), .es, "first language we have")
        XCTAssertEqual(L10n.systemLanguage(preferred: ["nb-NO"]), .nb)
        XCTAssertEqual(L10n.systemLanguage(preferred: ["no"]), .nb)
        XCTAssertEqual(L10n.systemLanguage(preferred: ["nn-NO"]), .nb)
        XCTAssertEqual(L10n.systemLanguage(preferred: ["de-AT"]), .de)
        XCTAssertEqual(L10n.systemLanguage(preferred: ["ko-KR"]), .ko)
        XCTAssertEqual(L10n.systemLanguage(preferred: ["he-IL"]), .he)
        XCTAssertEqual(L10n.systemLanguage(preferred: ["ja-JP", "zh-Hans"]), .en, "English is the fallback")
        XCTAssertEqual(L10n.systemLanguage(preferred: []), .en)
    }

    func testSwitchingLanguageChangesTheTitles() {
        L10n.use(.fr)
        XCTAssertEqual(Section.lighting.title, "Éclairage")
        L10n.use(.en)
        XCTAssertEqual(Section.lighting.title, "Lighting")
        L10n.use(.es)
        XCTAssertEqual(Section.lighting.title, "Iluminación")
        L10n.use(.pt)
        XCTAssertEqual(Section.lighting.title, "Iluminação")
    }

    func testFactoryNamesFollowTheLanguage() {
        // A config written by the French build keeps working in any language.
        L10n.use(.en)
        XCTAssertEqual(L10n.displayName("Veille"), "Sleep")
        XCTAssertEqual(L10n.displayName("Principal"), "Main")
        XCTAssertEqual(L10n.displayName("My own name"), "My own name")
        L10n.use(.pt)
        XCTAssertEqual(L10n.displayName("Sleep"), "Repouso")
    }

    func testLanguageIsSavedInTheConfig() throws {
        var cfg = Config()
        XCTAssertNil(cfg.language)
        cfg.language = "es"
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back.language, "es")
        // Old files have no language key at all.
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertNil(old.language)
    }

    func testEveryKeyboardLayoutHasALanguage() {
        // Everest Max ships with these layouts; each one's language is offered.
        let offered = Set(Language.allCases.map(\.rawValue))
        for code in ["en", "fr", "de", "it", "es", "pt", "nb", "sv", "da", "fi", "he", "ko"] {
            XCTAssertTrue(offered.contains(code), code)
        }
    }

    func testOnlyHebrewIsRightToLeft() {
        XCTAssertEqual(Language.allCases.filter(\.isRightToLeft), [.he])
    }

    func testMostStringsAreReallyTranslated() {
        // A catalog that is mostly English means a copy that was never translated.
        for lang in Language.allCases where lang != .en {
            let same = english.filter { lang.catalog[$0.key] == $0.value }.count
            XCTAssertLessThan(Double(same) / Double(english.count), 0.15, "\(lang.rawValue): \(same) strings identical to English")
        }
    }

    func testEveryLanguageIsNamedInItself() {
        XCTAssertEqual(Set(Language.allCases.map(\.nativeName)).count, Language.allCases.count)
    }
}

/// The firmware gate: the app must never write to a keyboard it was not
/// tested with.
final class FirmwareGateTests: XCTestCase {
    func testOnlyTheTestedFirmwareIsSupported() {
        XCTAssertEqual(Keyboard.supportedFirmware, 0x57)
        XCTAssertTrue(Keyboard.isSupported(firmware: 0x57))
        for v in [UInt8(0x00), 0x39, 0x56, 0x58, 0x60, 0xFF] {
            XCTAssertFalse(Keyboard.isSupported(firmware: v), String(format: "%x", v))
        }
    }

    func testBlockReasons() {
        XCTAssertNil(FirmwareBlock(version: 0x57))
        XCTAssertEqual(FirmwareBlock(version: 0x39), .unsupported("39"))
        XCTAssertEqual(FirmwareBlock(version: 0x58), .unsupported("58"))
        XCTAssertEqual(FirmwareBlock(version: nil), .unreadable, "an unreadable version is not trusted")
    }

    func testErrorsExplainWhatToDo() {
        let old = Keyboard.OpenError.unsupportedFirmware(0x39).description
        XCTAssertTrue(old.contains("39") && old.contains("57") && old.contains("Windows"), old)
        XCTAssertFalse(Keyboard.OpenError.firmwareUnreadable.description.isEmpty)
    }
}
