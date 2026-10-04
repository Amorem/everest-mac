import SwiftUI

/// Covers the whole window when the connected keyboard runs a firmware this
/// app was not tested with. Nothing is written to such a keyboard (see
/// `Keyboard.init`); the sidebar stays visible underneath so the language and
/// the quit/hide controls remain reachable.
struct FirmwareBlockView: View {
    @ObservedObject var model: EverestModel
    let block: FirmwareBlock

    private var tested: String { String(format: "%x", Keyboard.supportedFirmware) }

    var body: some View {
        ZStack {
            Theme.canvas.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.amber)

                VStack(spacing: 8) {
                    Text(title).font(.ui(24, .bold)).foregroundStyle(Theme.text)
                    Text(body(for: block))
                        .font(.ui(13.5)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    if case .unsupported(let v) = block {
                        Pill(text: tr("firmware.block.detected", v), icon: "cpu", tint: Theme.amber)
                    }
                    Pill(text: tr("firmware.block.tested", tested), icon: "checkmark.seal", tint: Theme.success)
                }

                if case .unsupported = block {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(tr("firmware.block.howTitle"), systemImage: "arrow.down.circle")
                            .font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                        Text(tr("firmware.block.how"))
                            .font(.ui(12.5)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Caption(tr("firmware.block.why"), icon: "info.circle")
                    }
                    .padding(16)
                    .frame(maxWidth: 520, alignment: .leading)
                    .background(SurfaceBackground(radius: 12, fill: Color.white.opacity(0.04)))
                }

                HStack(spacing: 12) {
                    Button { model.refreshDevice() } label: {
                        Label(tr("firmware.block.check"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.primary)
                    languageMenu
                }
            }
            .padding(40)
            .frame(maxWidth: 640)
        }
    }

    private var title: String {
        switch block {
        case .unsupported: return tr("firmware.block.title")
        case .unreadable: return tr("firmware.block.unreadableTitle")
        }
    }

    private func body(for block: FirmwareBlock) -> String {
        switch block {
        case .unsupported: return tr("firmware.block.body", tested)
        case .unreadable: return tr("firmware.block.unreadableBody")
        }
    }

    /// The language can be changed here too — someone who cannot read the
    /// message needs to be able to fix that first.
    private var languageMenu: some View {
        LanguagePicker(model: model).frame(width: 190)
    }
}

/// Menu with "Automatic" and every language under its own name.
struct LanguagePicker: View {
    @ObservedObject var model: EverestModel

    var body: some View {
        Picker("", selection: Binding(
            get: { model.language?.rawValue ?? "auto" },
            set: { model.setLanguage($0 == "auto" ? nil : Language(rawValue: $0)) })) {
            Text(tr("settings.language.automatic")).tag("auto")
            Divider()
            ForEach(Language.allCases) { l in Text(l.nativeName).tag(l.rawValue) }
        }
        .labelsHidden()
    }
}
