# How the Everest Max is driven

Technical notes behind the app. Everything here comes from disassembling and
decompiling Base Camp 1.9.10 (`SDKDLL.dll`, `BaseCamp.UI.dll`,
`BaseCamp.Service.exe`) for interoperability, cross-checked against the
community [BaseCamp-Linux](https://github.com/ramisotti13-eng/BaseCamp-Linux)
protocol notes and verified on a real Everest Max (UK-ISO, firmware 57).

> **Warning.** The commands that send pictures use the same mechanism as the
> firmware update. Do not experiment with their arguments: a wrong sector or
> target can ruin a keyboard. The flows below are the ones Base Camp itself
> uses. For the same reason the app only opens a keyboard that reports
> firmware 57 (`11 00` reply, byte 4 = `0x57`) — see `Keyboard.init`.

## Transport

- Vendor HID interface (usage page `0xFF00`, USB interface 3), 64-byte packets.
- Commands and events travel as unnumbered output/input reports on the
  interrupt pair: first byte `0x11` for queries and display settings,
  `0x12`/`0x13`/`0x14`/`0x17` for flash, picture-reset, RGB and action writes,
  `0x01` for key and display-key events.
- Pictures travel as HID **feature reports** (`aa 55 …`), one 64-byte report
  per step, each answered by a `GET_REPORT`.
- Useful queries: `11 00` (firmware info: byte 4 = version, byte 10 = active
  profile), `11 12` (byte 4 = layout code), `11 14` (state: display mode, what
  is attached).
- D1–D4 presses: byte 42 of a `01` report (`0x02`, `0x04`, `0x08`, `0x10`).
- The keyboard sends every answer to **every program that has the HID device
  open** (the daemon's keep-alives included), so the next packet received is
  not necessarily the answer to your query: match it on `11 <command>`.
- It has a single command buffer: queries sent back to back are answered only
  for the last one. Send one, wait for its answer, then the next.

## Lighting

### Built-in effects

Static, Wave, Tornado, Breathing, Reactive, Matrix, Yeti and Off run in the
keyboard's firmware. `BaseCamp.UI.dll` builds an `EffData` / `BlockData`
struct and `SDKDLL.dll` normalises it and sends `14 2C` + the struct.

- Each effect has its own slot in the active profile, so applying one is
  `SwitchProfile(profile, slot)` (`14 00 00 00 <profile> <slot>`) → effect
  packet → `SaveFlash(slot)` (`13 55 00 00 <slot>`).
  Slots: Static 0, Wave 1, Tornado 2, Breathing 3, Reactive 4, Matrix 5,
  Custom 6, Yeti 7, Off 8. Effect ids: 0x00, 0x04, 0x07, 0x01, 0x03, 0x09, 0x0A,
  0x06, 0x0C.
- Speed is one of five hardware steps per effect (UI thresholds ≤12, ≤37, ≤62,
  ≤87, above): wave/tornado 10→6, breathing/reactive 5→0, matrix 20→0, yeti
  10→0 (smaller = faster).
- A dual-colour wave is sent as four gradient stops (c1 c2 c1 c2 at
  25/50/75/100 %); the firmware also accepts four arbitrary stops.
- Tornado direction: 9 clockwise, 10 anticlockwise. Wave direction: 0 right,
  2 down, 4 left, 6 up.

### Custom ("Mac-rendered") mode

`SwitchProfile(profile, 6)` then `14 2C 0A …` enables the custom slot. Colours
go as 8 packets of 19 keys (`14 2C 00 01 <ix> …`, 126 used of 152 slots) and 3
packets of side-strip LEDs (`14 2D 0A …`, 45 LEDs), then every key is bound to
the static slot (`14 A0 <0–2> 01`). The app streams only the packets that
changed, ~21 fps. `13 55 00 00 06` saves the current picture into the custom
slot.

### LED map

Key LED index = `column × 9 + row`. The side strips are matrix ids 126–170 in
Base Camp (side index = id − 126): main board top 13 14 15 7 6 5 4 3 2 1 0,
bottom 20…30 12, left 16–19, right 9 8 10 11; numpad top 44 43 42, bottom
35 36 37, left 31–34, right 41 40 39 38.

## Layouts

The firmware reports the layout in the reply to `11 12` (byte 4, SDKDLL's
`GetFWLayout`). Base Camp maps 4 → UK, 5 → French, 3 → German, 8 → Italian,
11 → Nordic, 15 → Spanish, 12 → Portuguese, 13 → Hebrew, 22 → Korean, 17 or
anything else → US.

Two physical shapes: ANSI (US, Hebrew, Korean) and ISO (the rest). LED indices
do not change with the language, only the shape: ANSI has `\` (LED 119) at the
end of the QWERTY row and a wide Enter (120); ISO has the tall Enter (120), `#`
(111) and the extra key beside Z (13). Keycap text comes from Base Camp's
`GetEverestKeys_*` tables (`Sources/everest/LayoutLegends.swift`). Those tables
index three keys on the F1/F11/F12 LEDs in the German, Italian, Nordic and
Spanish cases; they are moved to the LEDs of the keys they print (1, 100, 109).

Only the UK layout has been verified on hardware.

## Profiles

Base Camp's Everest profiles map 1:1 onto the five hardware profiles
(`Profile.Id` = `FWInfo.currentlyProfileIndex`). Lighting, key remaps and the
D1–D4 pictures are stored per profile in the keyboard; Base Camp can link a
profile to a program (`LaunchPadExe`). The app adds, per profile: D1–D4
actions, a dial mode, and linked apps (switching when the front app changes).
Pictures are addressed `… 02 <profile> <key 0–3>`; reset is `13 42 00 00`
followed by one key bitmap per profile.

## Display keys (D1–D4) and the dial: pictures

Pictures are RGB565 little-endian: 72×72 for a key (10,368 bytes), 240×204 for
the dial (97,920 bytes). The sequence is SDKDLL's `StartPicUpdate`, checked in
the disassembly:

1. `aa 55 21 04` (select the display keys; `03` = dial), answered `aa 55 21 fa`;
2. `aa 55 22 00`, answered `aa 55 22 fa`;
3. the descriptor
   `aa 55 10 <size:3 LE> <checksum:2 LE> 00 00 02 <profile> <key 0–3>`,
   **re-sent on every `aa 55 10 fb` ("busy") answer** until the keyboard
   answers `aa 55 10 fa` — it erases the old picture itself meanwhile (`fe`
   means the request was rejected);
4. 64-byte chunks, each answered `aa 55 10 fa <bytes received so far:3 LE>`;
   the last answer carries `fe` at offset 9. On `fb` the same chunk is re-sent.

On firmware 57 a key picture takes about 20 s. There is **no host-side erase**:
`aa 55 21 xx` only selects a target. (An earlier version of this tool issued
`21 01…08` "erase sessions" copied from an old capture; they were slow, and
the keyboard rejected targets 5 and above.) Firmware older than 57 writes one
chunk per ~10 s, which makes a picture take half an hour — update the firmware
first (Mountain's `Mountain_Everest_57.24.20` package).

The keyboard also stores a Windows-style shortcut per D key in flash (`Win+1…`
becomes ⌘1… on a Mac). A picture reset brings the factory ones back, so the app
overwrites them with a no-op action (`12 08 00 <key+1>` then
`17 AA <len> 00 04 :`), which also arms the key events.

## If the flash gets wedged

An interrupted picture transfer leaves the keyboard expecting more data: every
later feature report is eaten as a chunk and the normal channel answers
`ff aa`. `everest recover` (SDK device reset `aa 55 7f` + picture resets)
clears most cases. Otherwise unplug and replug the keyboard — nothing is lost,
the previous pictures and settings stay in flash.

The upload commands run a transfer they started to the end, or fail before
the first chunk is accepted, which leaves the keyboard untouched.

## Dial display

`11 14` with the write flag switches the dial menu (it must echo the device's
own bytes 7–9 of the state report): image 0x01, clock 0x11, volume 0x71, CPU
0x91, GPU 0xA1, disk 0xB1, network 0xC1, RAM 0xD1, APM 0xE1. Metrics are
`11 81 <index> 00 <value>` (0 CPU, 1 GPU, 2 disk, 3 network MB/s, 4 RAM) and
`11 83 00 00 <level>` for the volume. The clock is `11 80 00 00 01`,
`11 84 00 00`, then `11 84 00 01 00 00 MM DD HH MM SS style`. The dial's *Custom*
menu entry (bit 7 of the menu mask) makes the media-dock buttons run functions
assigned in Base Camp instead of the media keys; this app does not use it.
