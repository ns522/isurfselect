# Surf Select

Apple Watch and iPhone control for a Nautique Surf Select 3.0 system (part `200169`).

The boat speaks CAN. The Waveshare ESP32-S3 on that bus is a Bluetooth LE peripheral named `Surf Select`. The Apple Watch and the iPhone both scan for that service and connect as centrals. Neither uses the other as a bridge.

## Bridge

Mount the ESP32-S3 in the starboard rear locker, next to the existing transom antenna. In the boat, the watch and the phone only have to reach the ESP32 over Bluetooth.

The board sketch is `firmware/surf-select-s3/surf-select-s3.ino`. It uses the ESP32 CAN controller (TWAI) and NimBLE. A classic ESP32 build of the same Bluetooth contract is `firmware/esp32/surf_select_bridge/surf_select_bridge.ino`.

The ESP32-S3 works both **inline alongside the factory `200169` Surf Select 3.0 module** and **standalone** with `200169` unplugged:

- **Inline with `200169`:** The bridge tracks `200169`'s ~1 Hz `0x14EF114C` frames and schedules wave-side and ballast commands outside the `850..1150 ms` heartbeat edge so the two nodes never collide.
- **Standalone:** If no external `0x14EF114C` frame arrives for more than `2.5 s`, the bridge emits its own ~1 Hz idle `0x14EF114C` heartbeat so LINC keeps Surf Select active without a `200169` on the bus.

CAN runs at 250 kbit/s (29-bit extended identifiers). That is SLCAN `S5`, the rate `tools/boat_can_gui.py` uses when it opens the CANable 2.

On the Waveshare ESP32-S3-RS485-CAN, TX is GPIO 15 and RX is GPIO 16 (with RS485 DE on GPIO 21 held low). The classic sketch uses GPIO 5 and GPIO 4. Use a 3.3 V CAN transceiver; `CANH` and `CANL` are the transceiver's bus pins.

### How the watch and the iPhone connect

The ESP32 is the only peripheral. The watch and the iPhone are both centrals.

Each one scans for the local name `Surf Select` and for this service:

`7c4e0001-6f3b-4a1e-9c55-1b2d3e4f5061`

Each one connects on its own. The watch reaches the ESP32 directly, and the iPhone reaches the ESP32 directly. After the first central connects, the ESP32 keeps advertising so the other one can connect too.

A connected central reads the 6-byte status frame, writes commands, and subscribes to status and song notifications.

### BLE characteristics

Service UUID: `7c4e0001-6f3b-4a1e-9c55-1b2d3e4f5061`

| Name | UUID | Access | What it carries |
| --- | --- | --- | --- |
| Status (`Frame`) | `7c4e0002-6f3b-4a1e-9c55-1b2d3e4f5061` | Read, Notify | 6-byte status payload directly from `0x14EF4C11` |
| Command | `7c4e0003-6f3b-4a1e-9c55-1b2d3e4f5061` | Write, Write Without Response | 3-byte `[0xA5, opcode, value]` command packet (also accepts legacy 5-byte and 6-byte writes) |
| Song | `7c4e0004-6f3b-4a1e-9c55-1b2d3e4f5061` | Read, Notify | Current song title reconstructed from `0x19FE0A05`, UTF-8 text |

#### 3-byte command format (`0003`)

Primary writes from the watch and iPhone use `[0xA5, opcode, value]`:

| Byte 0 | Byte 1 (`opcode`) | Byte 2 (`value`) | Action |
| --- | --- | --- | --- |
| `0xA5` | `0x01` (Side) | `0x01` Port, `0x03` Starboard | Switches wave side on `0x14EF114C` Byte 0 |
| `0xA5` | `0x02` (Speed) | Speed in `0.1 mph` (`121` = 12.1 mph) | Sends `0x14EF114C` (`Byte 1 = 0x40`) + 8×80 ms `0x14EF4C11` burst |
| `0xA5` | `0x03` (Volume) | Volume (`0` through `40`) | Sends `0x14EF114C` (`Byte 1 = 0x40`) + 8×80 ms `0x14EF4C11` burst |
| `0xA5` | `0x04` (Shape) | Wave shape (`0` through `10`) | Sends `0x14EF114C` (`Byte 1 = 0x40`) + 8×80 ms `0x14EF4C11` burst |
| `0xA5` | `0x05` (Ballast) | `0x09` Port, `0x0A` Starboard, `0x03` Stop | Sends ballast shift command on `0x14EF114C` Byte 2 |

Legacy writes on `0003` remain supported:

- **5-byte packet:** `[shape, side, speed_tenths, volume, flags]` where `side` is `0` for Port and `1` for Starboard, `flags` bit 0 is shifting, and `flags` bit 1 is underwater lights.
- **6-byte packet:** Raw `0x14EF4C11`-layout bytes.

In all formats, any side change is routed to `0x14EF114C` (`0x01` Port / `0x03` Starboard), and shape/speed/volume bursts on `0x14EF4C11` always preserve LINC's live side bit. `0002` notifies whenever the 6-byte `0x14EF4C11` bus status changes and re-notifies after commands so centrals snap back to LINC's authoritative state if a change is rejected.

### CAN protocol

All frames use 29-bit extended identifiers at 250 kbit/s (`0x11` is LINC Panoray, `0x4C` is Surf Select 3.0):

| ID | Direction & rate | Length | Role |
| --- | --- | --- | --- |
| `0x14EF4C11` | LINC `0x11` → Surf Select `0x4C` (4 Hz) | 6 bytes | Authoritative surf status broadcast; also accepts 8×80 ms bursts for shape, speed, and volume edits keeping the live side bit |
| `0x14EF114C` | Surf Select `0x4C` → LINC `0x11` (~1 Hz) | 8 bytes | Surf Select command and ~1 Hz heartbeat frame (wave side switch, ballast shift, and active edits) |
| `0x19FE0A05` | Stereo → bus | Variable | Song title ASCII fragments in bytes `1..N` |

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
| 2 | Ballast shift command: `0x09` Port, `0x0A` Starboard, `0x03` Stop, `0x00` idle |
| 3 | `(lights << 4) \| shape` — bit 4 (`0x10`) is underwater lights, low nibble is shape (`0` through `10`) |
| 4 | Speed in tenths of a mph (`121` = `0x79` = 12.1 mph) |
| 5 | `0x00` |
| 6 | Stereo volume |
| 7 | `0x1E` |

`00 00 00 04 79 00 07 1E` is the idle `0x14EF114C` heartbeat matching `45 00 79 00 07 0A`.

Song fragments on `0x19FE0A05` that arrive within `0.4 s` belong to one title. The bridge keeps printable ASCII bytes `32` through `126`, collapses whitespace to single spaces, and notifies the UTF-8 string on `0004`.

### Flashing

1. Install the Arduino IDE and Espressif's ESP32 board package (Boards Manager, `esp32` by Espressif Systems).
2. Open `firmware/surf-select-s3/surf-select-s3.ino` for the Waveshare board, or `firmware/esp32/surf_select_bridge/surf_select_bridge.ino` for a classic ESP32.
3. Select the matching board and its serial port.
4. Upload.

`tools/boat_can_gui.py` is the Mac CAN tester for the CANable 2 at 250 kbit/s (`http://127.0.0.1:8765/`). It decodes both `0x14EF4C11` and `0x14EF114C`, switches wave side via `0x14EF114C` (`0x01` Port / `0x03` Starboard), and sends shape (`0` through `10`), speed, and volume edits.

## Watch controls

Water Lock stays on while surfing, so the screen is dead. watchOS keeps the side button and the crown click. The app only gets crown turns, and only while a workout session holds the app in front.

1. Turn the crown through Side, Speed, Volume, Ballast. One click, one row.
2. Rest about a second. The row arms.
3. The next turn changes that function. Side sends on the first armed click. Speed and ballast show the pending change and send on a second click in the same direction.
4. Rest a second and it returns to the list.

Small crown motion is ignored. A crown press starts Water Lock unlock and sends nothing.

## Reference files

The fēnix app copy is on the Desktop at `garmin-fenix6-apps` (`C6SK1207.PRG` plus its data files).

The crown behavior lives in `Sources/SurfSelectCore` and is covered by `swift test`. Open `SurfSelect.xcodeproj` to run the watch app. On the boat the screen is touch controls, with Settings at the bottom. Water controls in Settings switches to the crown, and Done on that list returns to the touchscreen. The watch also switches to the crown when Water Lock turns on. A watch with a depth sensor locks itself when it submerges.
