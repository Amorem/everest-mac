# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Unofficial macOS companion for the **Mountain Everest Max** keyboard and the **Mountain DisplayPad** (Swift 5.9, SwiftPM, macOS 13+, no dependencies). One executable target `everest` is both the CLI and the SwiftUI/menu-bar app. The UI is translated (en, fr, de, es, it, pt, nb, sv, da, fi, ko, he) through keys: never write user-facing text inline, use `tr("key", args…)` and add the key to all `Sources/everest/Strings/Strings.<lang>.swift` catalogs (`LocalizationTests` enforces completeness; values read at draw time must not be cached in `static let`). Code, docs and commit messages are English. Protocol details live in `docs/PROTOCOL.md`, user docs in `README.md`.

## Commands

```sh
swift build                          # debug build -> .build/debug/everest
swift test                           # unit tests, no keyboard needed
swift test --filter LayoutTests/testKeySetsAndGeometry   # single test
./make-app.sh [--install | --zip]    # builds + signs Everest.app (use this, not swift build, for the app)
.build/debug/everest selftest [--lighting] [--upload N]  # talks to the REAL keyboard
.build/debug/everest selftest --pad [--draw]             # the REAL DisplayPad (--draw: RAM-only test pattern)
```

There is no linter. `selftest --upload N` writes the keyboard's flash; `--lighting` switches the lighting slot and restores it. Run plain `selftest` after touching anything in `Keyboard.swift`, `Transport.swift`, `Daemon.swift` or `Firmware.swift`, and `selftest --pad` after touching the DisplayPad files or `Transport.swift`.

Dev aids (not user features): `EVEREST_SNAPSHOT=<dir> Everest.app/Contents/MacOS/everest gui` renders every page to PNG and quits; `everest effect-sheet|icon-sheet|layout-sheet|menubar-sheet <out.png>` render contact sheets; `everest rgb ... --dry-run` prints packets without sending; `EVEREST_DEBUG=1` logs raw HID traffic; `EVEREST_CONFIG_DIR` overrides `~/.config/everest-mac` (tests rely on it so they never touch the real config).

## Architecture

**Transport → Keyboard → features.** `Transport.swift` wraps one IOKit HID handle (vendor usage page 0xFF00, 64-byte packets as output reports, plus HID *feature* reports for picture transfers). `Keyboard.swift` is the synchronous high-level API (`wake`, `state`, `uploadIcon`, `neutraliseKeyActions`...). `Protocol.swift` / `Firmware.swift` build packets as pure functions; those are what the unit tests pin byte-for-byte.

**Several processes share the device.** The GUI process (`EverestModel` in `GuiModel.swift`, serial `device` queue for short sessions), a child `everest listen` daemon (`Daemon.swift`, spawned and supervised by the model, logs to `~/.config/everest-mac/daemon.log`), the `LedPlayer` thread (`Led.swift`, streams Mac-rendered frames at ~30 fps) and the CLI may all have the HID device open at once. Consequences that bit before:
- The keyboard delivers every reply to every open session, so **match replies by command** (`Keyboard.waitReply(cmd)`), never "the next packet".
- It has a single command buffer: send one query, wait for its answer.
- During picture uploads the `FlashBusy` marker file (`Daemon.swift`) tells the daemon, LED player and GUI polling to stay off the channel. Anything new that polls the device must honour `FlashBusy.active`.
- Daemon and LED player drop and reopen their HID session when a write fails (unplug/replug); each session must re-run its startup steps.

**Firmware gate.** `Keyboard.init` only opens a keyboard whose `11 00` reply reports firmware `0x57` (`Keyboard.supportedFirmware`); anything else, or an unreadable version, throws `Keyboard.OpenError` and nothing is written. Only read-only callers (`info`, `sniff`, the GUI status polling) pass `allowUnsupported: true` — never write through such a keyboard. Do not add a firmware-update feature.

**Picture upload (D1–D4, dial) mirrors SDKDLL's `StartPicUpdate`**: select target (`aa 55 21 04`, `22 00`), re-send the descriptor on every `fb` until `fa`, then 64-byte chunks. The keyboard erases the old picture itself. Never add host-side "erase sector" commands (`aa 55 21 xx` only selects a target; earlier code misusing it was slow and failed on D3/D4). Key index in the descriptor is 0-based. This path is the firmware-update mechanism: do not experiment with its arguments.

**DisplayPad** (`3282:0009`, `docs/DISPLAYPAD.md`): `PadProtocol.swift` (pure packets, allow-list `PadProto.isAllowed` that every send goes through — never widen it to flash, firmware or erase commands), `DisplayPad.swift` (commands over `Transport(productID:)` on interface 3, pixels over IOUSBHost on interface 1, which macOS leaves driverless; the open is exclusive so hold it only while sending), `PadDaemon.swift` (thread inside `everest listen`, independent of the keyboard; follows `ActiveProfile`; redraws all keys on connect, wake or profile change, and changed keys within a second of a config change; honours `PadBusy`). Pictures live in the pad's RAM only (`21 00`); flash pictures (`21 01`), the boot logo (`21 02`) and firmware commands stay out. Firmware gate: `PadProto.supportedFirmware` (8). The GUI edits D1–D4 and pad keys through `KeyTarget` (`ButtonEditorCard`, `KeyAppearanceSheet`); pad keys are `ProfileConfig.pad` (optional for old files). The pad stays black until the host enables it, and on some hubs regardless.

**Lighting has two sources** (`LightingConfig.Source`): `.firmware` (built-in effects, `FirmwareLighting`, applied as SwitchProfile → effect packet → SaveFlash, runs without the Mac) and `.mac` (`LedEffect` rendered per key by `LedRenderer`, streamed through custom slot 6 by `FrameStream`; needs the app running). `LedRenderer` also simulates firmware effects for previews.

**Profiles** map 1:1 to the keyboard's five hardware profiles. `Config.swift` holds `ProfileConfig` (D1–D4 buttons, lighting, dial mode, linked apps); `Config.buttons`/`lighting` are computed shortcuts onto the *selected* profile, and the decoder migrates the old single-profile file. `AutoSwitcher` (`Profiles.swift`) decides front-app switching and is shared by app and daemon. The daemon hot-reloads `config.json` (mtime check each second).

**Layouts** (`Layouts.swift`, `LedLayout.swift`, generated `LayoutLegends.swift`): the layout code comes from the reply to `11 12` (byte 4). `LedLayout` is a global switchable set of derived tables (`LedLayout.use(_:)`, then `keys`, `positionTable`, `columns`...). LED index = column×9+row regardless of language; only ANSI vs ISO shape and keycap text change. Only UK-ISO has been verified on hardware. `LayoutLegends.swift` is generated from Base Camp's tables with Mountain's index errors corrected (see its header); regenerate rather than hand-edit.

**App lifecycle** (`Gui.swift`, `MenuBar.swift`): closing the window drops to `.accessory` activation policy and keeps running in the menu bar; the window reopens via the status item or `applicationShouldHandleReopen`. Login item uses `SMAppService` (`LoginItem.swift`).

## Gotchas

- **Signing**: `make-app.sh` signs the bundle with the explicit requirement `identifier "local.everest-mac"` so the Accessibility grant survives rebuilds. A plain ad-hoc signature pins a `cdhash` and silently invalidates the permission on every build (symptom: entry ticked, D1–D4 key combos do nothing). The bundle executable is the binary itself; with no arguments inside a `.app` it opens the GUI (`main.swift`).
- The keyboard stores its own Windows-style shortcut per D key and a picture reset restores it (⌘1… types digits/opens apps on a Mac). App and daemon overwrite them with a no-op via `neutraliseKeyActions()`; call it after any `13 42` reset.
- `FactoryIcons.swift`, `MountainMark.swift` and `assets/AppIcon.icns` embed Mountain's pictures/logo; `tools/make-icon.swift` regenerates the icon and the embedded mark.
- `.gitignore` deliberately excludes `extracted/`, `reference/`, the MSI, `venv/`, `tools/*.py` and the personal photo; keep them out of any commit.
