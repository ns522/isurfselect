#!/usr/bin/env python3
"""Browser tester for the Nautique Surf Select 3.0 CAN protocol on the CANable 2.

The system Python only has Tk 8.5, which opens a blank window on this Mac.
This serves the controls at http://127.0.0.1:8765/
"""

import glob
import json
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import serial

HOST = "127.0.0.1"
PORT = 8765
BITRATE_CMD = b"S5\r"
STATUS_ID = "14EF4C11"
SURF_CMD_ID = "14EF114C"
COMMAND_ID = STATUS_ID
TITLE_ID = "19FE0A05"
BURST = 8
BURST_GAP = 0.08
SIDE_TRIES = 2
SIDE_GAP = 0.28
HEARTBEAT_EDGE_MIN = 0.85
HEARTBEAT_EDGE_MAX = 1.15
HEARTBEAT_POST_GAP = 0.04

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>isurfselect CAN tester</title>
<style>
  body { font: 16px -apple-system, sans-serif; margin: 24px auto; max-width: 540px; color: #111; background: #f6f6f4; }
  h1 { font-size: 22px; margin: 0 0 12px; }
  section { background: #fff; border: 1px solid #ddd; border-radius: 10px; padding: 14px 16px; margin: 12px 0; }
  label { display: block; margin: 10px 0; }
  .row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .inline-label { display: inline-flex; gap: 5px; align-items: center; margin: 0; }
  button, select, input { font: inherit; padding: 8px 10px; }
  button { background: #111; color: #fff; border: 0; border-radius: 8px; cursor: pointer; }
  button.secondary { background: #e7e7e4; color: #111; }
  code { font: 13px ui-monospace, monospace; background: #ecece8; padding: 1px 4px; border-radius: 4px; }
  #boat { font-size: 17px; line-height: 1.45; white-space: pre-line; }
  #song { color: #333; margin-top: 8px; }
  #log { white-space: pre-wrap; font: 13px ui-monospace, monospace; max-height: 180px; overflow: auto; }
  .hint { color: #444; font-size: 14px; line-height: 1.45; }
</style>
</head>
<body>
  <h1>isurfselect CAN tester</h1>
  <section class="row">
    <select id="port"></select>
    <button id="connect">Connect</button>
    <button id="disconnect" class="secondary">Disconnect</button>
  </section>
  <p id="status">Not connected</p>
  <section>
    <div id="boat">Waiting for the surf frame</div>
    <div id="song">Song: —</div>
  </section>
  <section>
    <div class="row" style="margin: 4px 0 12px;">
      <span>Side</span>
      <label class="inline-label"><input type="radio" name="side" value="Port" checked> Port</label>
      <label class="inline-label"><input type="radio" name="side" value="Starboard"> Starboard</label>
      <button id="side-port" type="button">Switch to Port</button>
      <button id="side-starboard" type="button">Switch to Starboard</button>
    </div>
    <label>Shape <input id="shape" type="number" min="0" max="10" step="1" value="4"></label>
    <label>Speed <input id="speed" type="number" min="5" max="25" step="0.1" value="12.1"> mph</label>
    <label>Volume <input id="volume" type="number" min="0" max="40" step="1" value="7"></label>
    <label><input id="lights" type="checkbox"> Underwater lights</label>
    <label><input id="shifting" type="checkbox"> Shift running <span class="hint">same bit for port and starboard</span></label>
    <div class="row">
      <button id="send">Send</button>
      <button id="vol-down">Volume −</button>
      <button id="vol-up">Volume +</button>
      <button id="copy" class="secondary">Use boat values</button>
    </div>
  </section>
  <p class="hint">Wave side (<code>0x01</code> Port / <code>0x03</code> Starboard on <code>0x14EF114C</code>), shape (<code>0–10</code>), speed, and volume are all proven on the boat. Side switches send up to 2 frames on <code>0x14EF114C</code> (280 ms apart, timed clear of the ~1 Hz heartbeat); shape, speed, and volume edits send <code>0x14EF114C</code> (<code>Byte 1 = 0x40</code>) plus an 8×80 ms <code>0x14EF4C11</code> burst keeping the live side bit.</p>
  <section id="log"></section>
<script>
const $ = (id) => document.getElementById(id);
let boat = null;
let seeded = false;
function form() {
  return {
    shape: Number($("shape").value),
    side: document.querySelector('input[name="side"]:checked').value,
    speed: Number($("speed").value),
    volume: Number($("volume").value),
    shifting: $("shifting").checked,
    lights: $("lights").checked
  };
}
function applyBoatToForm(b) {
  document.querySelector(`input[name="side"][value="${b.side}"]`).checked = true;
  $("shape").value = b.shape;
  $("speed").value = b.speed.toFixed(1);
  $("volume").value = b.volume;
  $("shifting").checked = b.shifting;
  $("lights").checked = b.lights;
}
async function send(body) {
  const res = await fetch("/send", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
  const data = await res.json();
  if (!res.ok) $("status").textContent = data.error || "Send failed";
}
async function switchSide(side) {
  document.querySelector(`input[name="side"][value="${side}"]`).checked = true;
  await send({ ...form(), side, force_side: true });
}
$("connect").onclick = () => fetch("/connect", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({port: $("port").value})});
$("disconnect").onclick = () => fetch("/disconnect", {method: "POST"});
$("side-port").onclick = () => switchSide("Port");
$("side-starboard").onclick = () => switchSide("Starboard");
$("send").onclick = () => send(form());
$("vol-down").onclick = () => {
  $("volume").value = Math.max(0, Number($("volume").value) - 1);
  const body = form();
  if (boat) body.side = boat.side;
  send(body);
};
$("vol-up").onclick = () => {
  $("volume").value = Math.min(40, Number($("volume").value) + 1);
  const body = form();
  if (boat) body.side = boat.side;
  send(body);
};
$("copy").onclick = () => {
  if (!boat) return;
  applyBoatToForm(boat);
};
async function poll() {
  const data = await fetch("/state").then(r => r.json());
  $("status").textContent = data.status;
  const sel = $("port");
  const current = sel.value;
  sel.innerHTML = data.ports.map(p => `<option>${p}</option>`).join("");
  if (data.ports.includes(current)) sel.value = current;
  else if (data.port) sel.value = data.port;
  if (data.boat) {
    boat = data.boat;
    if (data.has_status && !seeded) {
      seeded = true;
      applyBoatToForm(boat);
    }
    let text = `${boat.side}   shape ${boat.shape}   ${boat.speed.toFixed(1)} mph   volume ${boat.volume}\\nUnderwater lights ${boat.lights ? "on" : "off"}   Shift ${boat.shifting ? "running" : "idle"}   14EF4C11: ${boat.raw}`;
    if (data.echo) {
      text += `\\n14EF114C: ${data.echo}`;
    }
    $("boat").textContent = text;
  }
  $("song").textContent = data.song ? `Song: ${data.song}` : "Song: —";
  $("log").textContent = data.log.join("\\n");
}
setInterval(() => poll().catch(() => {}), 400);
poll();
</script>
</body>
</html>
"""


def list_ports():
    return sorted(glob.glob("/dev/cu.usbmodem*"))


def hex_bytes(payload):
    return " ".join(f"{b:02X}" for b in payload)


def parse_slcan(text):
    if not text or text[0] not in "tT":
        return None
    id_len = 8 if text[0] == "T" else 3
    if len(text) < 1 + id_len + 1:
        return None
    try:
        dlc = int(text[1 + id_len], 16)
    except ValueError:
        return None
    data = text[2 + id_len:2 + id_len + dlc * 2]
    if len(data) != dlc * 2:
        return None
    try:
        return text[1:1 + id_len].upper(), bytes.fromhex(data)
    except ValueError:
        return None


def decode(payload):
    if len(payload) < 6:
        return None
    return {
        "shape": payload[0] >> 4,
        "side": "Starboard" if payload[0] & 0x08 else "Port",
        "speed": payload[2] / 10,
        "volume": payload[4],
        "lights": bool(payload[1] & 0x01),
        "shifting": bool(payload[5] & 0x01),
        "raw": hex_bytes(payload[:6]),
    }


def patch(payload, shape, side, speed, volume, shifting, lights=False):
    frame = bytearray(payload if len(payload) >= 6 else bytes.fromhex("45007900070A"))
    shape_clamped = max(0, min(10, int(shape)))
    low = (frame[0] & 0x07) | (0x08 if side == "Starboard" else 0x00)
    frame[0] = ((shape_clamped & 0x0F) << 4) | low
    if lights:
        frame[1] |= 0x01
    else:
        frame[1] &= ~0x01
    frame[2] = max(0, min(255, int(round(float(speed) * 10))))
    frame[4] = max(0, min(255, int(volume)))
    if shifting:
        frame[5] |= 0x01
    else:
        frame[5] &= ~0x01
    return bytes(frame)


def build_side_cmd(side, echo_payload=b"", shape=4, speed=12.1, volume=7, lights=False):
    """Build an 8-byte 0x14EF114C wave-side switch frame (0x01 Port, 0x03 Starboard)."""
    side_byte = 0x03 if side == "Starboard" else 0x01
    if len(echo_payload) >= 8:
        return bytes([side_byte]) + bytes(echo_payload[1:8])
    shape_nibble = max(0, min(10, int(shape))) & 0x0F
    lights_bit = (int(bool(lights)) & 1) << 4
    speed_tenths = max(0, min(255, int(round(float(speed) * 10))))
    vol_byte = max(0, min(255, int(volume)))
    return bytes([
        side_byte,
        0x00,
        0x00,
        lights_bit | shape_nibble,
        speed_tenths,
        0x00,
        vol_byte,
        0x1E,
    ])


def build_edit_cmd(shape, speed, volume, lights=False):
    """Build an 8-byte 0x14EF114C edit frame (Byte 1 = 0x40) for shape/speed/volume."""
    shape_nibble = max(0, min(10, int(shape))) & 0x0F
    lights_bit = (int(bool(lights)) & 1) << 4
    speed_tenths = max(0, min(255, int(round(float(speed) * 10))))
    vol_byte = max(0, min(255, int(volume)))
    return bytes([
        0x00,
        0x40,
        0x00,
        lights_bit | shape_nibble,
        speed_tenths,
        0x00,
        vol_byte,
        0x1E,
    ])


def slcan_tx(ident, payload):
    return f"T{ident}{len(payload):X}{payload.hex().upper()}\r".encode()


class Bus:
    def __init__(self):
        self.lock = threading.Lock()
        self.status = "Not connected"
        self.port = ""
        self.payload = bytes.fromhex("45007900070A")
        self.has_status = False
        self.echo_payload = b""
        self.echo_at = 0.0
        self.song = ""
        self.log = []
        self.song_parts = []
        self.song_at = 0.0
        self._jobs = queue.Queue()
        self._ser = None
        self._stop = threading.Event()
        self._side_job = None
        self._edit_cmd = None
        self._burst_frame = b""
        self._burst_left = 0
        self._burst_next_at = 0.0
        threading.Thread(target=self._run, daemon=True).start()

    def note(self, text):
        with self.lock:
            self.status = text
            self.log.append(text)
            self.log = self.log[-12:]

    def snapshot(self):
        with self.lock:
            return {
                "status": self.status,
                "port": self.port,
                "ports": list_ports(),
                "boat": decode(self.payload),
                "has_status": self.has_status,
                "echo": hex_bytes(self.echo_payload) if len(self.echo_payload) >= 8 else "",
                "song": self.song,
                "log": list(self.log),
            }

    def connect(self, port):
        self._jobs.put(("connect", port))

    def disconnect(self):
        self._jobs.put(("disconnect", None))

    def burst(self, fields):
        with self.lock:
            live = decode(self.payload) or {
                "shape": 4,
                "side": "Port",
                "speed": 12.1,
                "volume": 7,
                "lights": False,
                "shifting": False,
            }
            live_side = live["side"]
            req_side = fields.get("side", live_side)
            if req_side not in ("Port", "Starboard"):
                raise ValueError("side must be Port or Starboard")
            shape = int(fields.get("shape", live["shape"]))
            if not 0 <= shape <= 10:
                raise ValueError("shape must be 0..10")
            speed = float(fields.get("speed", live["speed"]))
            volume = int(fields.get("volume", live["volume"]))
            shifting = bool(fields.get("shifting", live["shifting"]))
            lights = bool(fields.get("lights", live["lights"]))
            force_side = bool(fields.get("force_side", False))

            if force_side or req_side != live_side:
                job = ("side", {
                    "side": req_side,
                    "shape": shape,
                    "speed": speed,
                    "volume": volume,
                    "lights": lights,
                })
            else:
                status_payload = patch(
                    self.payload,
                    shape,
                    live_side,
                    speed,
                    volume,
                    shifting,
                    lights,
                )
                cmd_payload = build_edit_cmd(shape, speed, volume, lights)
                job = ("edit", (cmd_payload, status_payload))
        self._jobs.put(job)

    def _in_heartbeat_edge(self, now):
        with self.lock:
            echo_at = self.echo_at
        if echo_at <= 0.0:
            return False
        age = now - echo_at
        if 0.0 <= age < HEARTBEAT_POST_GAP:
            return True
        if HEARTBEAT_EDGE_MIN <= age <= HEARTBEAT_EDGE_MAX:
            return True
        return False

    def _tx(self, ident, payload):
        if not self._ser:
            return False
        try:
            self._ser.write(slcan_tx(ident, payload))
            self._ser.flush()
            return True
        except serial.SerialException as exc:
            self.note(f"Serial error: {exc}")
            self._close()
            return False

    def _step_tx(self):
        if not self._ser:
            return
        now = time.time()

        if self._side_job is not None:
            job = self._side_job
            if now >= job["next_at"] and not self._in_heartbeat_edge(now):
                with self.lock:
                    echo = self.echo_payload
                cmd = build_side_cmd(
                    job["side"],
                    echo_payload=echo,
                    shape=job["shape"],
                    speed=job["speed"],
                    volume=job["volume"],
                    lights=job["lights"],
                )
                if not self._tx(SURF_CMD_ID, cmd):
                    return
                job["sent"] += 1
                job["left"] -= 1
                job["next_at"] = time.time() + SIDE_GAP
                self.note(
                    f"Side {job['side']} ({job['sent']}/{SIDE_TRIES}): "
                    f"14EF114C {hex_bytes(cmd)}"
                )
                if job["left"] <= 0:
                    self._side_job = None

        if self._edit_cmd is not None and not self._in_heartbeat_edge(now):
            cmd_frame = self._edit_cmd
            self._edit_cmd = None
            if not self._tx(SURF_CMD_ID, cmd_frame):
                return
            self.note(
                f"Sent 14EF114C {hex_bytes(cmd_frame)} + "
                f"14EF4C11 {hex_bytes(self._burst_frame)} x{BURST}"
            )

        if self._burst_left > 0 and time.time() >= self._burst_next_at:
            if not self._tx(STATUS_ID, self._burst_frame):
                return
            self._burst_left -= 1
            self._burst_next_at = time.time() + BURST_GAP

    def _run(self):
        buf = b""
        while not self._stop.is_set():
            try:
                while True:
                    kind, value = self._jobs.get_nowait()
                    if kind == "connect":
                        buf = b""
                        self._open(value)
                    elif kind == "disconnect":
                        buf = b""
                        self._close()
                    elif kind == "side":
                        if not self._ser:
                            self.note("Not connected")
                        else:
                            self._side_job = {
                                "side": value["side"],
                                "left": SIDE_TRIES,
                                "sent": 0,
                                "next_at": 0.0,
                                "shape": value["shape"],
                                "speed": value["speed"],
                                "volume": value["volume"],
                                "lights": value["lights"],
                            }
                    elif kind == "edit":
                        if not self._ser:
                            self.note("Not connected")
                        else:
                            cmd_payload, status_payload = value
                            self._edit_cmd = cmd_payload
                            self._burst_frame = status_payload
                            self._burst_left = BURST
                            self._burst_next_at = 0.0
            except queue.Empty:
                pass

            if not self._ser:
                time.sleep(0.05)
                continue

            try:
                chunk = self._ser.read(4096)
            except serial.SerialException as exc:
                self.note(f"Serial error: {exc}")
                self._close()
                continue

            if chunk:
                buf += chunk
                while b"\r" in buf:
                    line, buf = buf.split(b"\r", 1)
                    parsed = parse_slcan(line.decode("ascii", "replace").strip())
                    if parsed:
                        self._frame(*parsed)

            self._step_tx()

    def _frame(self, ident, payload):
        now = time.time()
        if ident == STATUS_ID and len(payload) >= 6:
            with self.lock:
                self.payload = payload[:6]
                self.has_status = True
            if self._side_job is not None and self._side_job["sent"] >= 1:
                live = decode(payload[:6])
                if live and live["side"] == self._side_job["side"]:
                    self._side_job = None
        elif ident == SURF_CMD_ID and len(payload) >= 8:
            with self.lock:
                self.echo_payload = payload[:8]
                self.echo_at = now
        elif ident == TITLE_ID and len(payload) > 1:
            with self.lock:
                if now - self.song_at > 0.4:
                    self.song_parts = []
                self.song_at = now
                self.song_parts.append(payload[1:])
                text = bytearray()
                for part in self.song_parts:
                    text.extend(b for b in part if 32 <= b < 127)
                cleaned = " ".join(text.decode("ascii", "ignore").split())
                if cleaned:
                    self.song = cleaned

    def _reset_tx(self):
        self._side_job = None
        self._edit_cmd = None
        self._burst_frame = b""
        self._burst_left = 0
        self._burst_next_at = 0.0

    def _open(self, port):
        self._close()
        try:
            ser = serial.Serial(port, 115200, timeout=0.01)
            time.sleep(0.1)
            ser.reset_input_buffer()
            for item in (b"C\r", BITRATE_CMD, b"M0\r", b"O\r"):
                ser.write(item)
                ser.flush()
                time.sleep(0.02)
            self._ser = ser
            with self.lock:
                self.port = port
                self.has_status = False
                self.echo_payload = b""
                self.echo_at = 0.0
            self.note(f"Connected {port}")
        except serial.SerialException as exc:
            self.note(f"Could not open {port}: {exc}")

    def _close(self):
        self._reset_tx()
        if self._ser:
            try:
                self._ser.write(b"C\r")
                self._ser.close()
            except serial.SerialException:
                pass
        self._ser = None
        with self.lock:
            self.has_status = False
            self.echo_payload = b""
            self.echo_at = 0.0


BUS = Bus()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read(self):
        length = int(self.headers.get("Content-Length", 0))
        if not length:
            return {}
        return json.loads(self.rfile.read(length))

    def do_GET(self):
        if self.path == "/state":
            self._json(200, BUS.snapshot())
            return
        if self.path in ("/", "/index.html"):
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        try:
            data = self._read()
        except json.JSONDecodeError:
            self._json(400, {"error": "Bad JSON"})
            return
        if self.path == "/connect":
            port = data.get("port") or (list_ports()[:1] or [""])[0]
            if not port:
                self._json(400, {"error": "No CANable found"})
                return
            BUS.connect(port)
            self._json(200, {"ok": True})
            return
        if self.path == "/disconnect":
            BUS.disconnect()
            self._json(200, {"ok": True})
            return
        if self.path == "/side":
            try:
                BUS.burst({"side": data["side"], "force_side": True})
            except (KeyError, TypeError, ValueError) as exc:
                self._json(400, {"error": str(exc)})
                return
            self._json(200, {"ok": True})
            return
        if self.path == "/send":
            try:
                BUS.burst(data)
            except (KeyError, TypeError, ValueError) as exc:
                self._json(400, {"error": str(exc)})
                return
            self._json(200, {"ok": True})
            return
        self.send_error(404)


def main():
    assert patch(bytes.fromhex("45007900080A"), 4, "Port", 12.1, 7, False) == bytes.fromhex("45007900070A")
    assert patch(bytes.fromhex("45007900080A"), 0, "Port", 12.1, 7, False) == bytes.fromhex("05007900070A")
    assert patch(bytes.fromhex("45007900080A"), 4, "Port", 12.1, 7, False, True)[1] == 1
    assert patch(bytes.fromhex("45007900080A"), 5, "Starboard", 12.2, 5, False) == bytes.fromhex("5D007A00050A")
    assert build_side_cmd("Port", echo_payload=bytes.fromhex("000000047900071E")) == bytes.fromhex("010000047900071E")
    assert build_side_cmd("Starboard", shape=0, speed=12.1, volume=7, lights=True) == bytes.fromhex("030000107900071E")
    assert build_edit_cmd(0, 12.1, 7, False) == bytes.fromhex("004000007900071E")
    found = list_ports()
    if found:
        BUS.connect(found[0])
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"http://{HOST}:{PORT}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
