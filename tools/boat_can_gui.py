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
TRACK_GROUP_FN_ID = "0DED0511"
ZONE_GROUP_FN_ID = "0DED054C"
ZONE_ISO_REQ_ID = "18EA054C"
ZONE_NAMES_ID = "19FE0E05"
ZONE_VOL_ID = "19FE1605"
ZONE_DISCOVER_PAYLOAD = bytes.fromhex("000EFE01FFFFFFFFFFFF010100")
ZONE_VOL_REQ_PAYLOAD = bytes.fromhex("16FE01")
BALLAST_WEIGHTS = (50, 100, 150, 200, 250, 300, 350, 400)
BALLAST_STOP_CODE = 0x03
TRACK_NEXT_CODE = 0x0B
TRACK_PREV_CODE = 0x0C
BURST = 8
BURST_GAP = 0.08
SIDE_TRIES = 2
SIDE_GAP = 0.28
BALLAST_TRIES = 3
BALLAST_GAP = 0.28
HEARTBEAT_EDGE_MIN = 0.85
HEARTBEAT_EDGE_MAX = 1.20
HEARTBEAT_POST_GAP = 0.04

PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>isurfselect CAN tester</title>
<style>
  body { font: 16px -apple-system, sans-serif; margin: 24px auto; max-width: 540px; color: #111; background: #f6f6f4; }
  h1 { font-size: 22px; margin: 0 0 12px; }
  h2 { font-size: 17px; margin: 0; }
  section { background: #fff; border: 1px solid #ddd; border-radius: 10px; padding: 14px 16px; margin: 12px 0; }
  label { display: block; margin: 10px 0; }
  .row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  .inline-label { display: inline-flex; gap: 5px; align-items: center; margin: 0; }
  button, select, input { font: inherit; padding: 8px 10px; }
  input[type="range"] { padding: 0; }
  button { background: #111; color: #fff; border: 0; border-radius: 8px; cursor: pointer; }
  button.secondary { background: #e7e7e4; color: #111; }
  button.stop-btn { background: #b42318; color: #fff; }
  code { font: 13px ui-monospace, monospace; background: #ecece8; padding: 1px 4px; border-radius: 4px; }
  #boat { font-size: 17px; line-height: 1.45; white-space: pre-line; }
  .song-row { display: flex; justify-content: space-between; align-items: center; gap: 10px; margin-top: 10px; flex-wrap: wrap; }
  #song { color: #333; margin: 0; flex: 1; min-width: 180px; }
  .song-controls { display: flex; gap: 6px; align-items: center; }
  .song-controls button { padding: 6px 10px; white-space: nowrap; }
  #log { white-space: pre-wrap; font: 13px ui-monospace, monospace; max-height: 180px; overflow: auto; }
  .hint { color: #444; font-size: 14px; line-height: 1.45; }
  .zone-head { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .zone-row { border-top: 1px solid #eee; padding-top: 10px; margin-top: 10px; }
  .zone-top { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 6px; }
  .zone-id { color: #666; font-size: 13px; margin-left: 6px; }
  .zone-pct { font-variant-numeric: tabular-nums; font-weight: 600; }
  .zone-controls { display: flex; gap: 8px; align-items: center; }
  .zone-controls button { min-width: 38px; padding: 6px 10px; }
  .zone-controls input[type="range"] { flex: 1; }
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
    <div class="song-row">
      <div id="song">Song: —</div>
      <div class="song-controls">
        <button id="track-prev" class="secondary" type="button">⏮ Prev</button>
        <button id="track-next" class="secondary" type="button">Next ⏭</button>
      </div>
    </div>
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
  <section id="ballast-card">
    <div class="zone-head">
      <h2>Ballast Shift</h2>
      <span id="ballast-state" class="hint">Idle</span>
    </div>
    <div class="row" style="margin-top: 10px;">
      <label class="inline-label">Weight
        <select id="ballast-lbs">
          <option value="50">50 lbs</option>
          <option value="100" selected>100 lbs</option>
          <option value="150">150 lbs</option>
          <option value="200">200 lbs</option>
          <option value="250">250 lbs</option>
          <option value="300">300 lbs</option>
          <option value="350">350 lbs</option>
          <option value="400">400 lbs</option>
        </select>
      </label>
      <button id="ballast-port" type="button">Shift Port</button>
      <button id="ballast-starboard" type="button">Shift Starboard</button>
      <button id="ballast-stop" class="stop-btn" type="button">Stop Pumps</button>
    </div>
  </section>
  <section id="zones-card">
    <div class="zone-head">
      <h2>Stereo Zones</h2>
      <button id="refresh-zones" class="secondary" type="button">Refresh Zones</button>
    </div>
    <div id="zones-empty" class="hint" style="margin-top: 10px;">Waiting for stereo zones (<code>0x19FE0E05</code>)…</div>
    <div id="zones-list"></div>
  </section>
  <p class="hint">Wave side (<code>0x01</code> Port / <code>0x03</code> Starboard on <code>0x14EF114C</code>), ballast shift (<code>50–400 lbs</code> + <code>0x03</code> Stop on <code>0x14EF114C</code>), shape (<code>0–10</code>), speed, master volume, stereo track skip (<code>0x0DED0511</code>), and NMEA 2000 per-zone stereo volume (<code>0x19FE0E05</code> / <code>0x19FE1605</code> / <code>0x0DED054C</code>) are all proven on the boat.</p>
  <section id="log"></section>
<script>
const $ = (id) => document.getElementById(id);
let boat = null;
let seeded = false;
let renderedZonesSig = "";
let activeZoneSlider = null;
const zoneHoldUntil = {};
const zoneTimers = {};
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
async function postZone(body) {
  const res = await fetch("/zone", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
  const data = await res.json();
  if (!res.ok) $("status").textContent = data.error || "Zone command failed";
}
async function postBallast(body) {
  const res = await fetch("/ballast", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
  const data = await res.json();
  if (!res.ok) $("status").textContent = data.error || "Ballast command failed";
}
async function postTrack(action) {
  const res = await fetch("/track", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({action})});
  const data = await res.json();
  if (!res.ok) $("status").textContent = data.error || "Track command failed";
}
function renderZones(zones) {
  const list = $("zones-list");
  const empty = $("zones-empty");
  if (!zones || zones.length === 0) {
    empty.style.display = "block";
    if (renderedZonesSig !== "") {
      list.innerHTML = "";
      renderedZonesSig = "";
    }
    return;
  }
  empty.style.display = "none";
  const sig = zones.map(z => `${z.id}:${z.name}`).join("|");
  if (sig !== renderedZonesSig) {
    renderedZonesSig = sig;
    list.innerHTML = "";
    for (const z of zones) {
      const row = document.createElement("div");
      row.className = "zone-row";

      const top = document.createElement("div");
      top.className = "zone-top";
      const labelWrap = document.createElement("span");
      const title = document.createElement("strong");
      title.textContent = z.name;
      const badge = document.createElement("span");
      badge.className = "zone-id";
      badge.textContent = `Zone ${z.id}`;
      labelWrap.appendChild(title);
      labelWrap.appendChild(badge);

      const pct = document.createElement("span");
      pct.className = "zone-pct";
      pct.id = `zone-pct-${z.id}`;
      top.appendChild(labelWrap);
      top.appendChild(pct);

      const controls = document.createElement("div");
      controls.className = "zone-controls";

      const downBtn = document.createElement("button");
      downBtn.type = "button";
      downBtn.className = "secondary";
      downBtn.textContent = "−";
      downBtn.onclick = () => {
        zoneHoldUntil[z.id] = 0;
        postZone({zone: z.id, step: "down"});
      };

      const slider = document.createElement("input");
      slider.type = "range";
      slider.min = "0";
      slider.max = "100";
      slider.step = "1";
      slider.value = typeof z.volume === "number" ? String(z.volume) : "0";
      slider.id = `zone-slider-${z.id}`;
      const startDrag = () => { activeZoneSlider = z.id; };
      const endDrag = () => { if (activeZoneSlider === z.id) activeZoneSlider = null; };
      slider.addEventListener("pointerdown", startDrag);
      slider.addEventListener("pointerup", endDrag);
      slider.addEventListener("pointercancel", endDrag);
      slider.addEventListener("blur", endDrag);
      slider.oninput = () => {
        const val = Number(slider.value);
        pct.textContent = `${val}%`;
        zoneHoldUntil[z.id] = Date.now() + 900;
        if (!zoneTimers[z.id]) {
          zoneTimers[z.id] = setTimeout(() => {
            zoneTimers[z.id] = null;
            postZone({zone: z.id, volume: Number(slider.value)});
          }, 120);
        }
      };
      slider.onchange = () => {
        if (zoneTimers[z.id]) {
          clearTimeout(zoneTimers[z.id]);
          zoneTimers[z.id] = null;
        }
        endDrag();
        const val = Number(slider.value);
        pct.textContent = `${val}%`;
        zoneHoldUntil[z.id] = Date.now() + 900;
        postZone({zone: z.id, volume: val});
      };

      const upBtn = document.createElement("button");
      upBtn.type = "button";
      upBtn.className = "secondary";
      upBtn.textContent = "+";
      upBtn.onclick = () => {
        zoneHoldUntil[z.id] = 0;
        postZone({zone: z.id, step: "up"});
      };

      controls.appendChild(downBtn);
      controls.appendChild(slider);
      controls.appendChild(upBtn);
      row.appendChild(top);
      row.appendChild(controls);
      list.appendChild(row);
    }
  }
  const now = Date.now();
  for (const z of zones) {
    const pctEl = $(`zone-pct-${z.id}`);
    const sliderEl = $(`zone-slider-${z.id}`);
    if (!pctEl || !sliderEl) continue;
    const held = activeZoneSlider === z.id || (zoneHoldUntil[z.id] && now < zoneHoldUntil[z.id]);
    if (!held) {
      const hasVol = typeof z.volume === "number";
      pctEl.textContent = hasVol ? `${z.volume}%${z.muted ? " (Muted)" : ""}` : "—%";
      if (hasVol) sliderEl.value = String(z.volume);
    }
  }
}
async function switchSide(side) {
  document.querySelector(`input[name="side"][value="${side}"]`).checked = true;
  await send({ ...form(), side, force_side: true });
}
$("connect").onclick = () => fetch("/connect", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({port: $("port").value})});
$("disconnect").onclick = () => fetch("/disconnect", {method: "POST"});
$("refresh-zones").onclick = async () => {
  const res = await fetch("/zones", {method: "POST"});
  const data = await res.json();
  if (!res.ok) $("status").textContent = data.error || "Zone refresh failed";
};
$("side-port").onclick = () => switchSide("Port");
$("side-starboard").onclick = () => switchSide("Starboard");
$("ballast-port").onclick = () => postBallast({side: "Port", lbs: Number($("ballast-lbs").value)});
$("ballast-starboard").onclick = () => postBallast({side: "Starboard", lbs: Number($("ballast-lbs").value)});
$("ballast-stop").onclick = () => postBallast({action: "stop"});
$("track-prev").onclick = () => postTrack("prev");
$("track-next").onclick = () => postTrack("next");
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
    $("ballast-state").textContent = boat.shifting ? "Pumps running" : "Idle";
  }
  $("song").textContent = data.song ? `Song: ${data.song}` : "Song: —";
  renderZones(data.zones || []);
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


def encode_ballast_code(side, lbs=100):
    """Encode 0x14EF114C Byte 2 for ballast shift: (steps << 2) | (1 Port / 2 Starboard), or 0x03 Stop."""
    if side in ("Stop", "stop"):
        return BALLAST_STOP_CODE
    if side not in ("Port", "Starboard"):
        raise ValueError("side must be Port, Starboard, or Stop")
    weight = int(lbs)
    if weight not in BALLAST_WEIGHTS:
        raise ValueError("lbs must be 50..400 in 50 lb steps")
    steps = weight // 50
    direction = 1 if side == "Port" else 2
    return (steps << 2) | direction


def build_ballast_cmd(b2_code, echo_payload=b"", shape=4, speed=12.1, volume=7, lights=False):
    """Build an 8-byte 0x14EF114C ballast shift/stop frame (B0=0x00, B1=0x40, B2=b2_code)."""
    b2 = int(b2_code) & 0xFF
    if len(echo_payload) >= 8:
        return bytes([0x00, 0x40, b2]) + bytes(echo_payload[3:8])
    shape_nibble = max(0, min(10, int(shape))) & 0x0F
    lights_bit = (int(bool(lights)) & 1) << 4
    speed_tenths = max(0, min(255, int(round(float(speed) * 10))))
    vol_byte = max(0, min(255, int(volume)))
    return bytes([
        0x00,
        0x40,
        b2,
        lights_bit | shape_nibble,
        speed_tenths,
        0x00,
        vol_byte,
        0x1E,
    ])


def build_track_skip_cmd(next_track):
    """Build 8-byte PGN 126208 Command Group Function targeting PGN 130569 Param 5 (0x0B Next, 0x0C Prev)."""
    return bytes([
        0x01,
        0x09,
        0xFE,
        0x01,
        0xF8,
        0x01,
        0x05,
        TRACK_NEXT_CODE if next_track else TRACK_PREV_CODE,
    ])


def build_fast_packet(payload, seq=0):
    """Split an NMEA 2000 Fast-Packet payload into 8-byte CAN frames."""
    if not payload or len(payload) > 223:
        raise ValueError("Fast-Packet payload must be 1..223 bytes")
    seq_bits = (int(seq) & 0x07) << 5
    frames = []
    first = payload[:6]
    frames.append(
        bytes([seq_bits | 0x00, len(payload)]) + first + (b"\xFF" * (6 - len(first)))
    )
    offset = 6
    idx = 1
    while offset < len(payload):
        chunk = payload[offset:offset + 7]
        frames.append(
            bytes([seq_bits | (idx & 0x1F)]) + chunk + (b"\xFF" * (7 - len(chunk)))
        )
        offset += 7
        idx += 1
    return frames


def build_zone_set_cmd(zone_id, pct):
    """Build PGN 126208 Command Group Function targeting PGN 130582 Field 02 (0..100%)."""
    zid = int(zone_id)
    vol = max(0, min(100, int(round(float(pct)))))
    if not 1 <= zid <= 252:
        raise ValueError("zone must be 1..252")
    return bytes([0x01, 0x16, 0xFE, 0x01, 0xF8, 0x02, 0x01, zid, 0x02, vol])


def build_zone_step_cmd(zone_id, up):
    """Build PGN 126208 Command Group Function targeting PGN 130582 Field 03 (0x00 Up, 0x01 Down)."""
    zid = int(zone_id)
    if not 1 <= zid <= 252:
        raise ValueError("zone must be 1..252")
    return bytes([0x01, 0x16, 0xFE, 0x01, 0xF8, 0x02, 0x01, zid, 0x03, 0x00 if up else 0x01])


def parse_supported_zones(payload):
    """Decode reassembled PGN 130574 (0x1FE0E) Supported Zone Data into (total_zones, [(id, name)])."""
    if len(payload) < 3:
        return None
    zone_count = payload[1]
    total_zones = payload[2]
    if total_zones == 0 or total_zones >= 0xFC:
        return None
    zones = []
    pos = 3
    for _ in range(min(zone_count, 32)):
        if pos >= len(payload):
            break
        zone_id = payload[pos]
        pos += 1
        if pos >= len(payload):
            break
        str_len = payload[pos]
        if str_len == 0 or str_len == 0xFF:
            break
        end = min(len(payload), pos + str_len)
        name = ""
        if str_len >= 2 and pos + 2 <= end:
            enc = payload[pos + 1]
            raw = payload[pos + 2:end]
            if enc == 0x00:
                decoded = raw.decode("utf-16-le", "ignore")
            else:
                trimmed = raw.rstrip(b"\x00\xff")
                try:
                    decoded = trimmed.decode("utf-8")
                except UnicodeDecodeError:
                    decoded = trimmed.decode("latin-1", "ignore")
            name = " ".join(decoded.replace("\x00", "").replace("\ufffd", "").split())
        pos = end
        if 1 <= zone_id <= total_zones:
            zones.append((zone_id, name or f"Zone {zone_id}"))
    return total_zones, zones


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
        self.total_zones = 0
        self.zone_names = {}
        self.zone_volumes = {}
        self.zone_muted = {}
        self._fp_tx_seq = 0
        self._fp_rx_seq = -1
        self._fp_rx_total = 0
        self._fp_rx_next = 0
        self._fp_rx_buf = bytearray()
        self._fp_rx_at = 0.0
        self._jobs = queue.Queue()
        self._ser = None
        self._stop = threading.Event()
        self._side_job = None
        self._ballast_job = None
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

    def _zones_snapshot_locked(self):
        if self.total_zones > 0:
            ids = range(1, self.total_zones + 1)
        else:
            ids = sorted(zid for zid in self.zone_volumes if 1 <= zid <= 8)
        return [
            {
                "id": zid,
                "name": self.zone_names.get(zid, f"Zone {zid}"),
                "volume": self.zone_volumes.get(zid),
                "muted": self.zone_muted.get(zid, False),
            }
            for zid in ids
        ]

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
                "total_zones": self.total_zones,
                "zones": self._zones_snapshot_locked(),
                "log": list(self.log),
            }

    def connect(self, port):
        self._jobs.put(("connect", port))

    def disconnect(self):
        self._jobs.put(("disconnect", None))

    def refresh_zones(self):
        self._jobs.put(("zones", None))

    def zone_set(self, zone_id, pct):
        zid = int(zone_id)
        vol = int(round(float(pct)))
        with self.lock:
            max_zone = self.total_zones if self.total_zones > 0 else 16
        if not 1 <= zid <= max_zone:
            raise ValueError(f"zone must be 1..{max_zone}")
        if not 0 <= vol <= 100:
            raise ValueError("volume must be 0..100")
        self._jobs.put(("zone_set", (zid, vol)))

    def zone_step(self, zone_id, up):
        zid = int(zone_id)
        with self.lock:
            max_zone = self.total_zones if self.total_zones > 0 else 16
        if not 1 <= zid <= max_zone:
            raise ValueError(f"zone must be 1..{max_zone}")
        self._jobs.put(("zone_step", (zid, bool(up))))

    def ballast_shift(self, side, lbs=100):
        code = encode_ballast_code(side, lbs)
        weight = int(lbs)
        self._jobs.put((
            "ballast",
            {
                "code": code,
                "want_shifting": True,
                "label": f"Ballast {side} {weight} lbs (0x{code:02X})",
            },
        ))

    def ballast_stop(self):
        self._jobs.put((
            "ballast",
            {
                "code": BALLAST_STOP_CODE,
                "want_shifting": False,
                "label": "Stop ballast pumps (0x03)",
            },
        ))

    def ballast_code(self, code):
        b2 = int(code)
        if b2 == BALLAST_STOP_CODE:
            self.ballast_stop()
            return
        direction = b2 & 0x03
        steps = b2 >> 2
        if direction not in (1, 2) or not 1 <= steps <= 8:
            raise ValueError("ballast code must be 0x03 or (steps << 2) | (1..2) for 50..400 lbs")
        side = "Port" if direction == 1 else "Starboard"
        self.ballast_shift(side, steps * 50)

    def track_skip(self, next_track):
        self._jobs.put(("track", bool(next_track)))

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

    def _tx_fast_packet(self, ident, payload):
        seq = self._fp_tx_seq
        self._fp_tx_seq = (self._fp_tx_seq + 1) & 0x07
        frames = build_fast_packet(payload, seq=seq)
        for idx, frame in enumerate(frames):
            if idx > 0:
                time.sleep(0.002)
            if not self._tx(ident, frame):
                return None
        return frames

    def _query_zones(self, announce=False):
        if self._tx_fast_packet(ZONE_GROUP_FN_ID, ZONE_DISCOVER_PAYLOAD) is None:
            return False
        time.sleep(0.02)
        if not self._tx(ZONE_ISO_REQ_ID, ZONE_VOL_REQ_PAYLOAD):
            return False
        if announce:
            self.note("Queried stereo zones (0DED054C PGN 130574 + 18EA054C PGN 130582)")
        return True

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

        elif self._ballast_job is not None:
            job = self._ballast_job
            if now >= job["next_at"] and not self._in_heartbeat_edge(now):
                with self.lock:
                    echo = (
                        self.echo_payload
                        if (self.echo_at > 0.0 and (now - self.echo_at) <= 2.5)
                        else b""
                    )
                    live = decode(self.payload) or {
                        "shape": 4,
                        "speed": 12.1,
                        "volume": 7,
                        "lights": False,
                    }
                cmd = build_ballast_cmd(
                    job["code"],
                    echo_payload=echo,
                    shape=live["shape"],
                    speed=live["speed"],
                    volume=live["volume"],
                    lights=live["lights"],
                )
                if not self._tx(SURF_CMD_ID, cmd):
                    return
                job["sent"] += 1
                job["left"] -= 1
                job["next_at"] = time.time() + BALLAST_GAP
                self.note(
                    f"{job['label']} ({job['sent']}/{BALLAST_TRIES}): "
                    f"14EF114C {hex_bytes(cmd)}"
                )
                if job["left"] <= 0:
                    self._ballast_job = None

        elif self._edit_cmd is not None and not self._in_heartbeat_edge(now):
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
                    elif kind == "zones":
                        if not self._ser:
                            self.note("Not connected")
                        else:
                            self._query_zones(announce=True)
                    elif kind == "zone_set":
                        if not self._ser:
                            self.note("Not connected")
                        else:
                            zid, pct = value
                            frames = self._tx_fast_packet(
                                ZONE_GROUP_FN_ID, build_zone_set_cmd(zid, pct)
                            )
                            if frames:
                                with self.lock:
                                    label = self.zone_names.get(zid, f"Zone {zid}")
                                self.note(
                                    f"{label} -> {pct}%: 0DED054C "
                                    f"{hex_bytes(frames[0])} | {hex_bytes(frames[1])}"
                                )
                    elif kind == "zone_step":
                        if not self._ser:
                            self.note("Not connected")
                        else:
                            zid, up = value
                            frames = self._tx_fast_packet(
                                ZONE_GROUP_FN_ID, build_zone_step_cmd(zid, up)
                            )
                            if frames:
                                with self.lock:
                                    label = self.zone_names.get(zid, f"Zone {zid}")
                                self.note(
                                    f"{label} {'+' if up else '−'}: 0DED054C "
                                    f"{hex_bytes(frames[0])} | {hex_bytes(frames[1])}"
                                )
                    elif kind == "track":
                        if not self._ser:
                            self.note("Not connected")
                        else:
                            next_track = value
                            frames = self._tx_fast_packet(
                                TRACK_GROUP_FN_ID, build_track_skip_cmd(next_track)
                            )
                            if frames:
                                self.note(
                                    f"Track {'Next ⏭' if next_track else '⏮ Prev'}: 0DED0511 "
                                    f"{hex_bytes(frames[0])} | {hex_bytes(frames[1])}"
                                )
                    elif kind == "ballast":
                        if not self._ser:
                            self.note("Not connected")
                        else:
                            self._ballast_job = {
                                "code": value["code"],
                                "want_shifting": value["want_shifting"],
                                "label": value["label"],
                                "left": BALLAST_TRIES,
                                "sent": 0,
                                "next_at": 0.0,
                            }
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
            live = decode(payload[:6])
            if self._side_job is not None and self._side_job["sent"] >= 1:
                if live and live["side"] == self._side_job["side"]:
                    self._side_job = None
            if self._ballast_job is not None and self._ballast_job["sent"] >= 1:
                if live and live["shifting"] == self._ballast_job["want_shifting"]:
                    self._ballast_job = None
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
        elif ident == ZONE_NAMES_ID and len(payload) >= 1:
            seq = (payload[0] >> 5) & 0x07
            idx = payload[0] & 0x1F
            msg = None
            if idx == 0:
                if len(payload) >= 2:
                    self._fp_rx_seq = seq
                    self._fp_rx_total = payload[1]
                    self._fp_rx_next = 1
                    self._fp_rx_buf = bytearray(payload[2:])
                    self._fp_rx_at = now
                    if self._fp_rx_total > 0 and len(self._fp_rx_buf) >= self._fp_rx_total:
                        msg = bytes(self._fp_rx_buf[:self._fp_rx_total])
                        self._fp_rx_seq = -1
            elif (
                seq == self._fp_rx_seq
                and idx == self._fp_rx_next
                and (now - self._fp_rx_at) <= 0.5
            ):
                self._fp_rx_buf.extend(payload[1:])
                self._fp_rx_next += 1
                self._fp_rx_at = now
                if len(self._fp_rx_buf) >= self._fp_rx_total:
                    msg = bytes(self._fp_rx_buf[:self._fp_rx_total])
                    self._fp_rx_seq = -1

            if msg is not None:
                parsed = parse_supported_zones(msg)
                if parsed is not None:
                    total_zones, entries = parsed
                    with self.lock:
                        self.total_zones = total_zones
                        for zid, name in entries:
                            self.zone_names[zid] = name
                        for store in (self.zone_names, self.zone_volumes, self.zone_muted):
                            for k in [k for k in store if k < 1 or k > total_zones]:
                                del store[k]
                        summary = ", ".join(
                            f"{zid}: {self.zone_names.get(zid, f'Zone {zid}')}"
                            for zid in range(1, total_zones + 1)
                        )
                    self.note(f"Stereo zones ({total_zones}): {summary}")
        elif ident == ZONE_VOL_ID and len(payload) >= 2:
            zone_id = payload[0]
            vol_pct = payload[1]
            muted = (((payload[2] >> 2) & 0x03) == 0x01) if len(payload) >= 3 else False
            if zone_id >= 1 and vol_pct <= 100:
                with self.lock:
                    limit = self.total_zones if self.total_zones > 0 else 8
                    if 1 <= zone_id <= limit:
                        self.zone_volumes[zone_id] = vol_pct
                        self.zone_muted[zone_id] = muted

    def _reset_tx(self):
        self._side_job = None
        self._ballast_job = None
        self._edit_cmd = None
        self._burst_frame = b""
        self._burst_left = 0
        self._burst_next_at = 0.0
        self._fp_rx_seq = -1
        self._fp_rx_total = 0
        self._fp_rx_next = 0
        self._fp_rx_buf = bytearray()
        self._fp_rx_at = 0.0

    def _reset_zones_locked(self):
        self.total_zones = 0
        self.zone_names = {}
        self.zone_volumes = {}
        self.zone_muted = {}

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
                self._reset_zones_locked()
            self.note(f"Connected {port}")
            self._query_zones(announce=True)
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
            self._reset_zones_locked()


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

    def _handle_zone_cmd(self, data):
        zid = data["zone"]
        if "step" in data:
            step = data["step"]
            if step in ("up", "+", 1, True):
                up = True
            elif step in ("down", "-", "−", -1, False):
                up = False
            else:
                raise ValueError("step must be up or down")
            BUS.zone_step(zid, up)
        elif "volume" in data or "pct" in data:
            pct = data["volume"] if "volume" in data else data["pct"]
            BUS.zone_set(zid, pct)
        else:
            raise ValueError("zone command requires volume or step")

    def _handle_ballast_cmd(self, data):
        action = str(data.get("action", "")).strip().lower()
        raw_side = str(data.get("side") or data.get("direction") or data.get("dir") or "").strip()
        if data.get("stop") is True or action == "stop" or raw_side.lower() == "stop":
            BUS.ballast_stop()
            return
        if "code" in data or "b2" in data:
            code = data["code"] if "code" in data else data["b2"]
            BUS.ballast_code(code)
            return
        side_lower = raw_side.lower()
        if side_lower == "port":
            side = "Port"
        elif side_lower in ("starboard", "stbd"):
            side = "Starboard"
        else:
            raise ValueError("side must be Port, Starboard, or Stop")
        lbs = data["lbs"] if "lbs" in data else data.get("weight", 100)
        BUS.ballast_shift(side, lbs)

    def _handle_track_cmd(self, data):
        raw = (
            data.get("action")
            if "action" in data
            else data.get("direction", data.get("dir", data.get("track", data.get("cmd"))))
        )
        if isinstance(raw, str):
            norm = raw.strip().lower()
            if norm in ("next", "fwd", "forward", "+"):
                BUS.track_skip(True)
                return
            if norm in ("prev", "previous", "back", "-", "−"):
                BUS.track_skip(False)
                return
        elif raw is True or raw in (1, TRACK_NEXT_CODE):
            BUS.track_skip(True)
            return
        elif raw is False or raw in (-1, TRACK_PREV_CODE):
            BUS.track_skip(False)
            return
        raise ValueError("track action must be next or prev")

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
        if self.path == "/zones":
            if "zone" in data:
                try:
                    self._handle_zone_cmd(data)
                except (KeyError, TypeError, ValueError) as exc:
                    self._json(400, {"error": str(exc)})
                    return
            else:
                BUS.refresh_zones()
            self._json(200, {"ok": True})
            return
        if self.path == "/zone":
            try:
                self._handle_zone_cmd(data)
            except (KeyError, TypeError, ValueError) as exc:
                self._json(400, {"error": str(exc)})
                return
            self._json(200, {"ok": True})
            return
        if self.path == "/ballast":
            try:
                self._handle_ballast_cmd(data)
            except (KeyError, TypeError, ValueError) as exc:
                self._json(400, {"error": str(exc)})
                return
            self._json(200, {"ok": True})
            return
        if self.path == "/track":
            try:
                self._handle_track_cmd(data)
            except (KeyError, TypeError, ValueError) as exc:
                self._json(400, {"error": str(exc)})
                return
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
    assert [encode_ballast_code("Port", w) for w in BALLAST_WEIGHTS] == [
        0x05, 0x09, 0x0D, 0x11, 0x15, 0x19, 0x1D, 0x21,
    ]
    assert [encode_ballast_code("Starboard", w) for w in BALLAST_WEIGHTS] == [
        0x06, 0x0A, 0x0E, 0x12, 0x16, 0x1A, 0x1E, 0x22,
    ]
    assert encode_ballast_code("Stop") == 0x03
    assert build_ballast_cmd(0x09, echo_payload=bytes.fromhex("000000047900071E")) == bytes.fromhex("004009047900071E")
    assert build_ballast_cmd(0x22, shape=4, speed=12.1, volume=7, lights=False) == bytes.fromhex("004022047900071E")
    assert build_ballast_cmd(BALLAST_STOP_CODE, echo_payload=bytes.fromhex("000000047900071E")) == bytes.fromhex("004003047900071E")
    assert build_fast_packet(build_track_skip_cmd(True), seq=4) == [
        bytes.fromhex("80080109FE01F801"),
        bytes.fromhex("81050BFFFFFFFFFF"),
    ]
    assert build_fast_packet(build_track_skip_cmd(False), seq=5) == [
        bytes.fromhex("A0080109FE01F801"),
        bytes.fromhex("A1050CFFFFFFFFFF"),
    ]
    assert slcan_tx(ZONE_ISO_REQ_ID, ZONE_VOL_REQ_PAYLOAD) == b"T18EA054C316FE01\r"
    assert build_fast_packet(ZONE_DISCOVER_PAYLOAD, seq=0) == [
        bytes.fromhex("000D000EFE01FFFF"),
        bytes.fromhex("01FFFFFFFF010100"),
    ]
    assert build_fast_packet(build_zone_step_cmd(1, True), seq=1) == [
        bytes.fromhex("200A0116FE01F802"),
        bytes.fromhex("2101010300FFFFFF"),
    ]
    assert build_fast_packet(build_zone_step_cmd(4, False), seq=2) == [
        bytes.fromhex("400A0116FE01F802"),
        bytes.fromhex("4101040301FFFFFF"),
    ]
    assert build_fast_packet(build_zone_set_cmd(4, 35), seq=3) == [
        bytes.fromhex("600A0116FE01F802"),
        bytes.fromhex("6101040223FFFFFF"),
    ]
    sample_130574 = (
        bytes([0x01, 0x04, 0x04])
        + bytes([0x01, 0x05, 0x01]) + b"Bow"
        + bytes([0x02, 0x06, 0x01]) + b"Dash"
        + bytes([0x03, 0x09, 0x01]) + b"Cockpit"
        + bytes([0x04, 0x06, 0x01]) + b"Wake"
    )
    assert parse_supported_zones(sample_130574) == (
        4,
        [(1, "Bow"), (2, "Dash"), (3, "Cockpit"), (4, "Wake")],
    )
    found = list_ports()
    if found:
        BUS.connect(found[0])
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"http://{HOST}:{PORT}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
