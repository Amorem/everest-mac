# Mountain DisplayPad

The DisplayPad (`3282:0009`) is a USB device of its own: twelve keys, each a
102 × 102 window on a single 800 × 240 panel, with its own firmware. Everest
drives it without a driver, root or libusb.

Sources: Mountain's **DisplayPad SDK** (NuGet `DisplayPad.SDK` 1.0.6, MIT
licence), whose native DLL was disassembled, and checks on a pad running
**firmware 8**. Community projects (mountain-displaypad, BaseCamp-Linux) were
read for comparison; none of their code is used.

## USB interfaces and macOS

| Interface | Collection | Use | On macOS |
|---|---|---|---|
| 0 | Generic desktop / keyboard | standard key reports | HID |
| 1 | 0xFF01 / 2, output only, 1024-byte reports | pixels | **no driver** (no IN endpoint): opened with IOUSBHost, interrupt OUT endpoint `0x02` |
| 3 | 0xFF00 / 1, 64-byte reports | commands, replies, key events | HID (IOHIDManager), like the keyboard |

IOUSBHost notes: transfers must use a buffer from `ioData(withCapacity:)`, and
an interrupt pipe needs `completionTimeout: 0` (anything else returns
`kIOReturnBadArgument`). Opening interface 1 is exclusive and needs no root
because no kernel driver claims it.

## Power and start-up

- The pad shows **nothing, not even its logo**, until the host switches it to
  host mode (`11 80 00 00 01`). A pad just plugged in can take several
  seconds, and an `ff aa`, before it echoes the command: keep resending every
  0.5 s.
- On at least one USB hub the pad enumerated and answered every command while
  its screen stayed black; plugged into the Mac directly, it lit up.
- Pictures are kept in RAM until power is lost, so the daemon sends all twelve
  again on every connection and after the Mac wakes.

## Firmware gate

The pad answers `11 00` whether or not it is in host mode, so the firmware is
read first and nothing else is sent unless it is the tested version (8). The
daemon then leaves an unsupported pad alone until it is plugged in again.

## Sharing the pad

The app, the daemon (`everest listen`), the CLI and the self-test may all have
the command interface open. Replies are matched by their echo, the pixel
interface is opened only while sending, and a process talking to the pad
directly leaves a marker (`.pad-busy.<pid>` in the config directory) that keeps
the daemon quiet. The daemon publishes what it found in `.pad-state` for the
app's status line.

Host mode off (`11 80 00 00 00`) clears the pictures without any USB event, so
the daemon cannot notice it; Everest never sends it, but another tool could.
Restarting the daemon redraws the keys.

## Commands (interface 3)

64-byte packets, unnumbered output reports. One request at a time: the reply
echoes bytes 0..n of the request, `ff aa` is an error, and a packet starting
with `01` is a key event (it can arrive while waiting for a reply).

| Function | Packet | Reply |
|---|---|---|
| Host mode on | `11 80 00 00 01` | echo |
| Firmware info | `11 00` | bytes 4–5 = version (LE, BCD): `08 00` = 8 |
| Backlight | `12 03 00 00 <0–100>` (the SDK offers 0/25/50/75/100) | echo |
| Read brightness | `12 00 00 01` | byte 5 |
| Read screen sleep | `22 00 00 01` | bytes 4–7 = on, h, m, s |
| Key picture (RAM) | `21 00 00 00 <key 0–11> 3d 00 00 65 65` | `21 00 00` ready, then pixels, then `21 00 ff ff` |

`3d` is the size in 512-byte blocks (61 × 512 ≥ 102 × 102 × 3) and `00 00 65 65`
the window inside the key (left, top, right, bottom).

**Brightness.** On firmware 8, in host mode, the backlight value is stored and
read back but has no visible effect except 0 (screen off): white keys drawn at
5 % and at 100 % looked identical. Everest sends 100 (or 0) and darkens the
pictures to the chosen percentage instead, redrawing all keys when it changes.

## Pixels (interface 1)

102 × 102 pixels, **BGR**, row by row from the top-left, **starting at byte
0**, padded with zeros to 31 chunks of 1024 bytes. The community drivers put
306 zero bytes first; on hardware that loses the bottom row, because the pad
reads only the 61 announced blocks.

## Key events

`01 …`, byte 42 bits `0x02`…`0x80` = keys 0–6, byte 47 bits `0x01`…`0x10` =
keys 7–11 (left to right, top row first). Release = the same packet with no bit
set. Verified for all twelve keys.

## Never sent

`PadProto.isAllowed` lets through only the packets above, so these can never
reach the pad: firmware update / reboot (`30 aa 55 …`, feature `aa 55 …`), sector
write and erase (`1a`, `1b`), profile/key/picture erase (`13 40`, `13 60`,
`13 61`), flash pictures (`21 01`, which wears the flash) and the boot logo
(`21 02`). The SDK also has on-device remaps, macros and five profiles
(`14 xx`, `15`); Everest keeps the pad in host mode and runs the actions on the
Mac instead.
