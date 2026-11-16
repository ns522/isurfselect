# isurfselect

Apple Watch and iPhone control for a Nautique Surf Select 3.0 system (part `200169`).

The boat speaks CAN. The Waveshare ESP32-S3 on that bus is a Bluetooth LE peripheral named `iSurfSelect`. The Apple Watch and the iPhone both scan for that service and connect as centrals. Neither uses the other as a bridge.

## Bridge

Mount the ESP32-S3 in the starboard rear locker, next to the existing transom antenna. In the boat, the watch and the phone only have to reach the ESP32 over Bluetooth.

The board sketch is `firmware/isurfselect-s3/isurfselect-s3.ino`. It uses the ESP32 CAN controller (TWAI) and NimBLE. A classic ESP32 build of the same Bluetooth contract is `firmware/esp32/isurfselect_bridge/isurfselect_bridge.ino`.

The ESP32-S3 works both **inline alongside the factory `200169` Surf Select 3.0 module** and **standalone** with `200169` unplugged:

- **Inline with `200169`:** The bridge tracks `200169`'s ~1 Hz `0x14EF114C` frames and schedules wave-side and ballast commands outside the `850..1150 ms` heartbeat edge so the two nodes never collide.
- **Standalone:** If no external `0x14EF114C` frame arrives for more than `2.5 s`, the bridge emits its own ~1 Hz idle `0x14EF114C` heartbeat so LINC keeps Surf Select active without a `200169` on the bus.

CAN runs at 250 kbit/s (29-bit extended identifiers). That is SLCAN `S5`, the rate `tools/boat_can_gui.py` uses when it opens the CANable 2.

On the Waveshare ESP32-S3-RS485-CAN, TX is GPIO 15 and RX is GPIO 16 (with RS485 DE on GPIO 21 held low). The classic sketch uses GPIO 5 and GPIO 4. Use a 3.3 V CAN transceiver; `CANH` and `CANL` are the transceiver's bus pins.

### How the watch and the iPhone connect

The ESP32 is the only peripheral. The watch and the iPhone are both centrals.

Each one scans for the local name `iSurfSelect` and for this service:

`7c4e0001-6f3b-4a1e-9c55-1b2d3e4f5061`

Each one connects on its own. The watch reaches the ESP32 directly, and the iPhone reaches the ESP32 directly. After the first central connects, the ESP32 keeps advertising so the other one can connect too.

A connected central reads the 6-byte status frame, writes commands, and subscribes to status, song, and stereo zone notifications. The iPhone can also open the firmware service and push a new app image. The watch does not use that service.

### BLE characteristics

Service UUID: `7c4e0001-6f3b-4a1e-9c55-1b2d3e4f5061`

| Name | UUID | Access | What it carries |
| --- | --- | --- | --- |
| Status (`Frame`) | `7c4e0002-6f3b-4a1e-9c55-1b2d3e4f5061` | Read, Notify | 6-byte status payload directly from `0x14EF4C11` |
| Command | `7c4e0003-6f3b-4a1e-9c55-1b2d3e4f5061` | Write, Write Without Response | `0xA5` command packets (`2` to `4` bytes; also accepts legacy 5-byte and 6-byte writes) |
| Song | `7c4e0004-6f3b-4a1e-9c55-1b2d3e4f5061` | Read, Notify | Current song title reconstructed from `0x19FE0A05`, UTF-8 text |
| Zones | `7c4e0005-6f3b-4a1e-9c55-1b2d3e4f5061` | Read, Notify | Discovered NMEA 2000 stereo zones: `[0x01, count]` followed by `[zoneId, (muted << 7) \| volPct, nameLen, ...utf8Name]` per zone |

Firmware service: `7c4e0010-6f3b-4a1e-9c55-1b2d3e4f5061`

| Name | UUID | Access | What it carries |
| --- | --- | --- | --- |
| Info | `7c4e0011-6f3b-4a1e-9c55-1b2d3e4f5061` | Read, Notify | 44-byte updater status, including the running version |
| Control | `7c4e0012-6f3b-4a1e-9c55-1b2d3e4f5061` | Write | Begin, abort, commit, and reboot |
| Data | `7c4e0013-6f3b-4a1e-9c55-1b2d3e4f5061` | Write | `u32` offset plus the next slice of the app image |

#### `0xA5` command format (`0003`)

Primary writes from the watch and iPhone use `0xA5`-prefixed packets (`[0xA5, opcode, ...]`):

| Packet bytes | Opcode | Arguments | Action |
| --- | --- | --- | --- |
| `[0xA5, 0x01, side]` | `0x01` (Side) | `0x01` Port, `0x03` Starboard | Switches wave side on `0x14EF114C` Byte 0 |
| `[0xA5, 0x02, tenths]` | `0x02` (Speed) | Speed in `0.1 mph` (`121` = 12.1 mph) | Sends `0x14EF114C` (`Byte 1 = 0x40`) + 8×80 ms `0x14EF4C11` burst |
| `[0xA5, 0x03, vol]` | `0x03` (Master Volume) | Master volume (`0` through `40`) | Sends `0x14EF114C` (`Byte 1 = 0x40`) + 8×80 ms `0x14EF4C11` burst |
| `[0xA5, 0x04, shape]` | `0x04` (Shape) | Wave shape (`0` through `10`) | Sends `0x14EF114C` (`Byte 1 = 0x40`) + 8×80 ms `0x14EF4C11` burst |
| `[0xA5, 0x05, b2Code]` | `0x05` (Ballast Shift) | `b2Code = (steps << 2) \| dir` (`0x05/0x06` for `50 lbs` through `0x21/0x22` for `400 lbs`; also accepts `0x03` Stop) | Sends ballast shift command on `0x14EF114C` (`B0 = 0x00`, `B1 = 0x40`, `B2 = b2Code`) |
| `[0xA5, 0x06, zoneId, pct]` | `0x06` (Zone Volume `%`) | `zoneId` (`1..totalZones`), `pct` (`0` through `100`) | Sets stereo zone volume directly via `0x0DED054C` (`PGN 130582` `Field 02`) |
| `[0xA5, 0x07, zoneId, dir]` | `0x07` (Zone Step) | `zoneId` (`1..totalZones`), `0x00` Up / `0x01` Down | Steps stereo zone volume by `2%` via `0x0DED054C` (`PGN 130582` `Field 03`) |
| `[0xA5, 0x08, 0x00]` | `0x08` (Refresh Zones) | `0x00` (optional) | Re-queries `PGN 130574` zone names (`0x0DED054C`) and `PGN 130582` zone volumes (`0x18EA054C`) |
| `[0xA5, 0x09, 0x03]` | `0x09` (Stop Ballast) | `0x03` (optional; defaults to `0x03`) | Stops ballast pumps immediately on `0x14EF114C` (`B0 = 0x00`, `B1 = 0x40`, `B2 = 0x03`) |
| `[0xA5, 0x0A, cmd]` | `0x0A` (Track Skip) | `0x0B` Next, `0x0C` Previous | Skips stereo track via 2-frame Fast-Packet on `0x0DED0511` (`PGN 126208` → `PGN 130569` `Param 5`) |

`0005` (`Zones`) carries version `0x01` in Byte 0, the discovered zone count (`0..8`) in Byte 1, and for each zone `[zoneId, (muted << 7) | volPct, nameLen, ...utf8Name]`, where `volPct` is `0..100` (`%`) and bit 7 (`0x80`) indicates mute.

Legacy writes on `0003` remain supported:

- **5-byte packet:** `[shape, side, speed_tenths, volume, flags]` where `side` is `0` for Port and `1` for Starboard, `flags` bit 0 is shifting, and `flags` bit 1 is underwater lights.
- **6-byte packet:** Raw `0x14EF4C11`-layout bytes.

In all formats, any side change is routed to `0x14EF114C` (`0x01` Port / `0x03` Starboard), and shape/speed/volume bursts on `0x14EF4C11` always preserve LINC's live side bit. `0002` notifies whenever the 6-byte `0x14EF4C11` bus status changes and re-notifies after commands so centrals snap back to LINC's authoritative state if a change is rejected.

### CAN protocol

All frames use 29-bit extended identifiers at 250 kbit/s (`0x11` is LINC Panoray, `0x4C` is Surf Select 3.0, `0x05` is the JL Audio MediaMaster `MM105-HR` / `MM100s` head unit):

| ID | Direction & rate | Length | Role |
| --- | --- | --- | --- |
| `0x14EF4C11` | LINC `0x11` → Surf Select `0x4C` (4 Hz) | 6 bytes | Authoritative surf status broadcast; also accepts 8×80 ms bursts for shape, speed, and volume edits keeping the live side bit |
| `0x14EF114C` | Surf Select `0x4C` → LINC `0x11` (~1 Hz) | 8 bytes | Surf Select command and ~1 Hz heartbeat frame (wave side switch, `50–400 lb` ballast shift / stop pumps, and active edits) |
| `0x19FE0A05` | Stereo `0x05` → bus | Variable | Song title ASCII fragments in bytes `1..N` (`PGN 130570` / `0x1FE0A`) |
| `0x0DED0511` | LINC `0x11` → Stereo `0x05` | Fast-Packet (2 × 8 bytes) | NMEA 2000 `PGN 126208` Command Group Function (`PGN 130569` / `0x1FE09` `Param 5 = 0x0B` Next / `0x0C` Previous) for stereo track skip |
| `0x0DED054C` | Surf Select `0x4C` → Stereo `0x05` | Fast-Packet (2 × 8 bytes) | NMEA 2000 `PGN 126208` Request Group Function (`PGN 130574` zone discovery) and Command Group Function (`PGN 130582` per-zone volume set/step) |
| `0x18EA054C` | Surf Select `0x4C` → Stereo `0x05` | 3 bytes | NMEA 2000 ISO Request (`16 FE 01`) to read all current zone volumes (`PGN 130582`) |
| `0x19FE0E05` | Stereo `0x05` → bus | Fast-Packet | NMEA 2000 `PGN 130574` (`0x1FE0E`) Supported Zone Data (`totalZones` and `STRING_LAU` custom boat zone names) |
| `0x19FE1605` | Stereo `0x05` → bus | 4 bytes | NMEA 2000 `PGN 130582` (`0x1FE16`) Zone Volume status (`<zoneId> <volPct> F3 00`) |

#### `0x14EF4C11` status frame (6 bytes, LINC `0x11` → Surf Select `0x4C`, 4 Hz)

| Byte | Contents |
| --- | --- |
| 0 | High nibble (`bits 7..4`) is wave shape, `0` through `10`. Bit 3 (`0x08`) is wave side: `0` Port (low nibble `0x05`), `1` Starboard (low nibble `0x0D`). Keep the low 3 bits as LINC last sent them. |
| 1 | Bit 0 (`0x01`) is underwater lights (`1` on, `0` off). Keep the other bits as LINC last sent them. |
| 2 | Speed in tenths of a mph (`121` = `0x79` = 12.1 mph). |
| 3 | Reserved; keep as LINC last sent it (`0x00`). |
| 4 | Stereo volume (`0` through `40`). |
| 5 | Bit 0 (`0x01`) is ballast shifting (`1` running, `0` idle; same bit for both sides). Keep the other bits as LINC last sent them (`0x0A` idle). |

`45 00 79 00 07 0A` is a Port status frame: shape `4`, `12.1 mph`, volume `7`, underwater lights off, shift idle (`5D ...` for Starboard shape `5`). LINC owns `0x14EF4C11` and ignores wave-side bit flips transmitted on this ID.

#### `0x14EF114C` command / heartbeat frame (8 bytes, Surf Select `0x4C` → LINC `0x11`, ~1 Hz)

| Byte | Contents |
| --- | --- |
| 0 | Wave side command: `0x01` Switch to Port, `0x03` Switch to Starboard, `0x00` idle |
| 1 | `0x40` watch active (`0x00` or `0x40` on idle `200169` heartbeats) |
| 2 | Ballast shift command: `B2 = (steps << 2) \| dir` for `50–400 lbs` (`0x05/0x06` through `0x21/0x22`), `0x03` Stop Ballast Pumps, `0x00` idle |
| 3 | `(lights << 4) \| shape` — bit 4 (`0x10`) is underwater lights, low nibble is shape (`0` through `10`) |
| 4 | Speed in tenths of a mph (`121` = `0x79` = 12.1 mph) |
| 5 | `0x00` |
| 6 | Stereo volume |
| 7 | `0x1E` |

`00 00 00 04 79 00 07 1E` is the idle `0x14EF114C` heartbeat matching `45 00 79 00 07 0A`.

##### `0x14EF114C` Byte 2 ballast shift encoding

Ballast shift transmits `B0 = 0x00`, `B1 = 0x40`, and `B2 = (steps << 2) | dir` where `steps = lbs / 50` (`1` through `8`) and `dir` is `1` (`0b01`) for Port or `2` (`0b10`) for Starboard, or `B2 = 0x03` to stop the ballast pumps. Frames are timed cleanly outside `200169`'s heartbeat edge and stop retrying once `0x14EF4C11` Byte 5 bit 0 flips to `1` (pumps started) or `0` (pumps stopped):

| Action / Weight | `steps` | Port (`dir = 1`) | Starboard (`dir = 2`) |
| --- | --- | --- | --- |
| `50 lbs` | `1` | `0x05` | `0x06` |
| `100 lbs` | `2` | `0x09` | `0x0A` |
| `150 lbs` | `3` | `0x0D` | `0x0E` |
| `200 lbs` | `4` | `0x11` | `0x12` |
| `250 lbs` | `5` | `0x15` | `0x16` |
| `300 lbs` | `6` | `0x19` | `0x1A` |
| `350 lbs` | `7` | `0x1D` | `0x1E` |
| `400 lbs` | `8` | `0x21` | `0x22` |
| Stop Ballast Pumps | — | `0x03` | `0x03` |
| Idle heartbeat | — | `0x00` | `0x00` |

Song fragments on `0x19FE0A05` that arrive within `0.4 s` belong to one title. The bridge keeps printable ASCII bytes `32` through `126`, collapses whitespace to single spaces, and notifies the UTF-8 string on `0004`.

#### NMEA 2000 stereo track skip & zones (`SA 0x05` — JL Audio MediaMaster `MM105-HR` / `MM100s`)

The JL Audio head unit at `SA 0x05` exposes transport track skip as well as dynamic zone discovery and independent `0..100%` per-zone volume over standard NMEA 2000 Entertainment PGNs:

- **Stereo track skip (`0x0DED0511`, `PGN 126208` Command Group Function → `PGN 130569` / `0x1FE09`):**
  `SA 0x05` accepts playback skip commands sent from LINC's source address `0x11` (`0x0DED0511`). Send an 8-byte `PGN 126208` Command Group Function (`0x01`) targeting `PGN 130569` (`09 FE 01`, `0x1FE09`), priority `0xF8`, `1` parameter pair (`0x01`), with `Param 5 = 0x0B` (Next) or `0x0C` (Previous) — payload `01 09 FE 01 F8 01 05 <0x0B|0x0C>` split into 2 Fast-Packet frames spaced `2 ms` apart:
  - Frame 0: `[(seq << 5) | 0x00, 0x08, 0x01, 0x09, 0xFE, 0x01, 0xF8, 0x01]`
  - Frame 1: `[(seq << 5) | 0x01, 0x05, 0x0B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]` (Next) or `[(seq << 5) | 0x01, 0x05, 0x0C, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]` (Previous)
- **Dynamic zone discovery (`0x0DED054C` → `0x19FE0E05`, `PGN 130574` / `0x1FE0E`):**
  Send a 13-byte NMEA 2000 Request Group Function (`PGN 126208`, function `0x00`) on `0x0DED054C` targeting `PGN 130574` (`0E FE 01`) with `Field 01` (`First Zone ID`) = `0x00`:
  `00 0E FE 01 FF FF FF FF FF FF 01 01 00` (2 Fast-Packet frames: `<seq|0> 0D 00 0E FE 01 FF FF` and `<seq|1> FF FF FF FF 01 01 00`).
  `SA 0x05` replies on `0x19FE0E05` with Fast-Packet `[firstZoneId, zoneCount, totalZones]` followed by repeating `[zoneId, STRING_LAU]` entries (`STRING_LAU` = `[len, encoding, ...bytes]`, where `len` includes the length and encoding bytes and `0x01` is UTF-8/ASCII). On a Nautique Paragon, `SA 0x05` reports `totalZones = 4` with custom boat zone names `1 = Bow`, `2 = Dash`, `3 = Cockpit`, `4 = Wake`.
- **Live zone volume read & status (`0x18EA054C` → `0x19FE1605`, `PGN 130582` / `0x1FE16`):**
  Send an ISO Request on `0x18EA054C` with 3-byte payload `16 FE 01` (`T18EA054C316FE01\r` in SLCAN). `SA 0x05` emits one 4-byte frame per zone on `0x19FE1605` (and broadcasts live updates whenever any zone changes): `<zoneId> <volPct> F3 00` (for example `01 14 F3 00` = Zone 1 at `20%`; bit 2 of byte 2 indicates mute, e.g. `F7`). Zone IDs are capped to `1..totalZones` (`0x00` is All Zones; `0x19FE1611` frames from LINC `0x11` are ignored).
- **Per-zone volume control (`0x0DED054C`, `PGN 126208` Command Group Function → `PGN 130582`):**
  Send a 10-byte Command Group Function (`0x01`) targeting `PGN 130582` (`16 FE 01`), priority `0xF8`, `2` parameter pairs, as 2 Fast-Packet frames (`<seq|0> 0A 01 16 FE 01 F8 02` and `<seq|1> 01 <zoneId> <field> <value> FF FF FF`):
  - **Direct `0..100%` set (`Field 02`):** `01 <zoneId> 02 <pct>` (`pct` = `0x00..0x64`).
  - **`2%` step Up / Down (`Field 03`):** `01 <zoneId> 03 00` (Up `+2%`) or `01 <zoneId> 03 01` (Down `−2%`).
  `SA 0x05` acknowledges on `0x0DED4C05` and broadcasts the new `<zoneId> <volPct> F3 00` frame on `0x19FE1605`.

### Flashing

1. Install the Arduino IDE and Espressif's ESP32 board package (Boards Manager, `esp32` by Espressif Systems).
2. Open `firmware/isurfselect-s3/isurfselect-s3.ino` for the Waveshare board, or `firmware/esp32/isurfselect_bridge/isurfselect_bridge.ino` for a classic ESP32.
3. For the S3, set Partition Scheme to **Default 4MB with spiffs (1.2MB APP/1.5MB SPIFFS)**. Phone updates need the two app slots in that layout. "No OTA" and "Huge APP" cannot take an update from the phone.
4. Select the board's serial port and upload over USB.

That USB upload is required once, so the bridge knows how to receive later updates. After it is running, use the iPhone.

### Phone updates

The iPhone pushes an app image over the firmware service. The bridge writes it to the inactive OTA slot, checks it, and reboots into it. The bridge does not join Wi-Fi. A hosted update is the same transfer: the phone downloads the `.bin`, then pushes it.

On the phone, open **Update** at the bottom of the boat screen.

- **Choose a .bin** installs a file from Files. AirDrop the Arduino export onto the phone. Use `isurfselect-s3.ino.bin`, the app image. The phone rejects the bootloader and partition bins.
- **Check for update** downloads a manifest, then the image it points at. Paste the manifest URL into Update server. Leave it empty until the files are hosted.

Bump `FIRMWARE_VERSION` in `firmware/isurfselect-s3/firmware_ota.cpp` for each release. The bridge reports that string. The manifest version should match it, or the phone will keep offering an update the bridge does not claim to be running.

Host the app bin next to a JSON manifest (`firmware/isurfselect-s3/manifest.example.json`):

```json
{
  "hardware": "esp32s3",
  "version": "1.1.0",
  "size": 546288,
  "crc32": "0123abcd",
  "sha256": "",
  "url": "https://example.com/isurfselect-s3.bin",
  "notes": "What changed."
}
```

`crc32` is the zlib CRC-32 of the file as 8 hex digits. An empty `sha256` skips that check. Fill both from the exported bin:

```bash
python3 -c "import hashlib,pathlib,zlib; d=pathlib.Path('isurfselect-s3.ino.bin').read_bytes(); print(len(d), format(zlib.crc32(d) & 0xffffffff, '08x'), hashlib.sha256(d).hexdigest())"
```

Each app slot is 1.2 MB. The current image is about 540 KB. The phone keeps the screen awake and stays connected in the background while the transfer runs. The first trials should be at the dock, with a USB cable nearby: the stock Arduino bootloader does not always roll a crashing image back to the previous one.

The classic ESP32 sketch does not accept phone updates. The update service is open to a connected phone, the same as the command characteristic.

`tools/boat_can_gui.py` is the Mac CAN tester for the CANable 2 at 250 kbit/s (`http://127.0.0.1:8765/`). It decodes `0x14EF4C11` and `0x14EF114C`, switches wave side via `0x14EF114C` (`0x01` Port / `0x03` Starboard), shifts ballast (`50–400 lbs` in `50 lb` steps) and stops ballast pumps (`0x03`) on `0x14EF114C`, sends shape (`0` through `10`), speed, and master volume edits, skips stereo tracks (`0x0DED0511`), and dynamically discovers and controls NMEA 2000 stereo zones (`0x19FE0E05`, `0x19FE1605`, and `0x0DED054C`).

## Watch controls

Water Lock stays on while surfing, so the screen is dead. watchOS keeps the side button and the crown click. The app only gets crown turns, and only while a workout session holds the app in front.

The Water Mode crown menu walks through `Side`, `Speed`, `Volume`, the dynamic `Wake`/`Tower` stereo zone (when discovered over `PGN 130574`), `Track`, `Ballast`, and `Done` (when entered manually from the boat screen):

1. Turn the crown to step through `Side`, `Speed`, `Volume`, `Wake`/`Tower`, `Track`, `Ballast`, and `Done`.
2. Rest briefly so the selected row arms.
3. Turn the crown to act on that row:
   - `Volume` uses the LINC `0–40` master scale. The `Wake`/`Tower` zone uses the LINC `0–50` scale. Both send immediately on each armed click. A zone level is still percent on the bus (`level × 2`).
   - `Track` skips to `Next` (`0x0B`, turn up) or `Previous` (`0x0C`, turn down).
   - `Side` and `Speed` preview the pending target and send on a second click in the same direction (or action button press).
   - `Ballast` previews and confirms a `Port` or `Starboard` shift using the configured pound step (`50–400 lbs` in `50 lb` increments). While ballast pumps are actively running (`0x14EF4C11` Byte 5 bit 0 = `1`), `Ballast` displays `STOP` and sends `0x03` (Stop Ballast Pumps) immediately on the first armed turn without a second confirmation click.
   - `Done` leaves manual Water Mode and returns to the touch controls.
4. Rest again and it returns to browsing (returning home to `Side` after idle quiet time).

Small crown motion is ignored. A crown press starts Water Lock unlock and sends nothing.

## Reference files

The fēnix app copy is on the Desktop at `garmin-fenix6-apps` (`C6SK1207.PRG` plus its data files).

The crown behavior lives in `Sources/ISurfSelectCore` and is covered by `swift test`. Open `ISurfSelect.xcodeproj` to run the watch app. On the boat the screen is touch controls, with Settings at the bottom. Water controls in Settings switches to the crown, and Done on that list returns to the touchscreen. The watch also switches to the crown when Water Lock turns on. A watch with a depth sensor locks itself when it submerges.
