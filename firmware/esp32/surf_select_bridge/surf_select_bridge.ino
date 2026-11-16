// Surf Select 3.0 CAN-to-BLE bridge for classic ESP32.
//
// Hardware:
//   - CAN 250 kbit/s (29-bit extended) on GPIO5 (TX) and GPIO4 (RX)
//   - Arduino BLE peripheral ("Surf Select") supporting up to 3 simultaneous centrals
//     (e.g. iPhone + Apple Watch connected concurrently)
//
// Proven Nautique Surf Select 3.0 CAN protocol (aligned with surf-select-s3.ino):
//   - 0x14EF4C11 (6 bytes, 4 Hz, LINC 0x11 -> Surf Select 0x4C): authoritative boat state
//   - 0x14EF114C (8 bytes, ~1 Hz, Surf Select 0x4C -> LINC 0x11): Surf Select commands & heartbeat
//   - 0x19FE0A05: stereo song title ASCII fragments (bytes[1..], 400 ms join window)

#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <driver/twai.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <string>

static const gpio_num_t CAN_TX_PIN = GPIO_NUM_5;
static const gpio_num_t CAN_RX_PIN = GPIO_NUM_4;
static const uint32_t CAN_BITRATE = 250000;

static const uint32_t SURF_STATUS_ID = 0x14EF4C11;
static const uint32_t SURF_CMD_ID = 0x14EF114C;
static const uint32_t TITLE_ID = 0x19FE0A05;

// Classic ESP32 Bluedroid stack allows up to 3 BLE centrals.
static const uint32_t MAX_CLIENTS = 3;

// Timing constants (ms)
static const int BURST_COUNT = 8;
static const uint32_t BURST_GAP_MS = 80;
static const int CMD_TRIES = 3;
static const uint32_t CMD_RETRY_GAP_MS = 280;
static const uint32_t PEER_POST_RX_GAP_MS = 45;
static const uint32_t PEER_WINDOW_MIN_MS = 850;
static const uint32_t PEER_WINDOW_MAX_MS = 1200;
static const uint32_t PEER_WAIT_TIMEOUT_MS = 250;
static const uint32_t PEER_OFFLINE_MS = 2500;
static const uint32_t POST_FLIP_IDLE_DELAY_MS = 450;
static const uint32_t STANDALONE_HB_MS = 1050;
static const uint32_t FORCE_NOTIFY_DELAY_MS = 800;
static const uint32_t SONG_JOIN_MS = 400;
static const uint32_t CAN_HEALTH_INTERVAL_MS = 500;

static const char *DEVICE_NAME = "Surf Select";
static const char *SERVICE_UUID = "7c4e0001-6f3b-4a1e-9c55-1b2d3e4f5061";
static const char *STATE_UUID = "7c4e0002-6f3b-4a1e-9c55-1b2d3e4f5061";
static const char *COMMAND_UUID = "7c4e0003-6f3b-4a1e-9c55-1b2d3e4f5061";
static const char *SONG_UUID = "7c4e0004-6f3b-4a1e-9c55-1b2d3e4f5061";

static portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;

// Authoritative boat state from 0x14EF4C11 (LINC -> Surf Select)
static uint8_t busFrame[6] = {0x45, 0x00, 0x79, 0x00, 0x07, 0x0A};
static bool haveBus = false;
static uint32_t firstBusMs = 0;

// Inline factory 200169 module tracking on 0x14EF114C (Surf Select -> LINC)
static uint8_t peerEcho[8] = {0x00, 0x00, 0x00, 0x04, 0x79, 0x00, 0x07, 0x1E};
static uint32_t lastPeerEchoMs = 0;
static bool havePeerEcho = false;

// Wave side switch state machine on 0x14EF114C (0x01 = Port, 0x03 = Starboard)
static uint8_t pendingSideCmd = 0;
static bool targetStarboard = false;
static int sideTriesLeft = 0;
static int sideSentCount = 0;
static uint32_t sideNextDueMs = 0;
static uint32_t sideExpireMs = 0;
static bool sideWaitingForPeer = false;
static uint32_t sidePeerWaitDeadlineMs = 0;

// Ballast shift state machine on 0x14EF114C (0x09 = Port, 0x0A = Starboard, 0x03 = Stop)
static uint8_t pendingShiftCmd = 0;
static int shiftTriesLeft = 0;
static uint32_t shiftNextDueMs = 0;
static bool shiftWaitingForPeer = false;
static uint32_t shiftPeerWaitDeadlineMs = 0;

// Immediate one-shot 0x14EF114C command (for Speed, Volume, Shape, Lights)
static bool oneShotCmdPending = false;
static uint8_t oneShotCmdFrame[8] = {0};

// Post-flip standalone clean idle 0x14EF114C frame
static bool idleCmdPending = false;
static uint32_t idleCmdDueMs = 0;

// Standalone 0x14EF114C ~1 Hz heartbeat schedule
static uint32_t nextStandaloneHbMs = 0;

// 8x80ms burst on 0x14EF4C11 for Speed / Volume / Shape / Lights (NEVER wave side!)
static uint8_t burstFrame[6] = {0};
static int burstLeft = 0;
static uint32_t burstNextMs = 0;

// Post-command BLE state reconciliation (snaps phone/watch back if LINC rejects command)
static bool forceNotifyPending = false;
static uint32_t forceNotifyAtMs = 0;

// Song title assembly from 0x19FE0A05
static char song[181];
static uint8_t songParts[512];
static size_t songLen = 0;
static uint32_t songAt = 0;

static BLEServer *server = nullptr;
static BLECharacteristic *stateChar = nullptr;
static BLECharacteristic *songChar = nullptr;
static volatile uint32_t advertiseAt = 0;

static void publishState(bool force = false);
static void fillStateFrom(const uint8_t src[6], uint8_t out[5]);
static void applySideCommand(uint8_t sideCmd);
static void applySpeedCommand(uint8_t speedTenths);
static void applyVolumeCommand(uint8_t volume);
static void applyShapeCommand(uint8_t shape);
static void applyShiftCommand(uint8_t shiftCmd);
static void applyLightsCommand(bool lightsOn);
static void handleBlePayload(const uint8_t *cmd, size_t len);

static void scheduleAdvertising() {
  advertiseAt = millis() + 200;
}

static bool isPeerOnlineLocked(uint32_t now) {
  return havePeerEcho && ((uint32_t)(now - lastPeerEchoMs) <= PEER_OFFLINE_MS);
}

static void buildBaseCmdFrameLocked(uint8_t out[8], uint32_t now) {
  bool peerOnline = isPeerOnlineLocked(now);
  out[0] = 0x00;
  out[1] = peerOnline ? peerEcho[1] : 0x40;
  out[2] = 0x00;
  out[3] = ((busFrame[1] & 0x01) ? 0x10 : 0x00) | ((busFrame[0] >> 4) & 0x0F);
  out[4] = busFrame[2];
  out[5] = 0x00;
  out[6] = busFrame[4];
  out[7] = 0x1E;
}

// Inline 200169 collision avoidance for 0x14EF114C transmissions:
// - If < 45 ms since last 200169 RX: wait until lastPeerEchoMs + 45 ms.
// - If 850..1200 ms since last 200169 RX: 200169 is about to send its ~1.05 s heartbeat;
//   wait for RX (+ 45 ms gap) OR 250 ms max timeout.
static bool canTransmit114CLocked(uint32_t now, bool &waitingForPeer, uint32_t &peerWaitDeadlineMs) {
  if (!havePeerEcho) {
    waitingForPeer = false;
    return true;
  }
  uint32_t sincePeer = now - lastPeerEchoMs;
  if (sincePeer < PEER_POST_RX_GAP_MS) {
    waitingForPeer = false;
    return false;
  }
  if (sincePeer >= PEER_WINDOW_MIN_MS && sincePeer <= PEER_WINDOW_MAX_MS) {
    if (!waitingForPeer) {
      waitingForPeer = true;
      peerWaitDeadlineMs = now + PEER_WAIT_TIMEOUT_MS;
      return false;
    }
    if ((int32_t)(now - peerWaitDeadlineMs) < 0) {
      return false;
    }
    return true;
  }
  waitingForPeer = false;
  return true;
}

static void queueBurstLocked(const uint8_t next[6], int count) {
  int copies = count;
  if (burstLeft > copies) {
    copies = burstLeft;
  }
  memcpy(burstFrame, next, 6);
  // Always guarantee we preserve the boat's authoritative side/low-nibble bits on 0x14EF4C11.
  burstFrame[0] = (burstFrame[0] & 0xF0) | (busFrame[0] & 0x0F);
  burstLeft = copies;
  burstNextMs = 0;
}

static void scheduleForceNotify() {
  uint32_t now = millis();
  portENTER_CRITICAL(&mux);
  if (haveBus) {
    forceNotifyAtMs = now + FORCE_NOTIFY_DELAY_MS;
    forceNotifyPending = true;
  }
  portEXIT_CRITICAL(&mux);
}

static void applySideCommand(uint8_t sideCmd) {
  uint8_t normalized = (sideCmd == 0x03) ? 0x03 : 0x01;
  uint32_t now = millis();
  portENTER_CRITICAL(&mux);
  pendingSideCmd = normalized;
  targetStarboard = (normalized == 0x03);
  sideTriesLeft = CMD_TRIES;
  sideSentCount = 0;
  sideNextDueMs = now;
  sideExpireMs = now + 2000;
  sideWaitingForPeer = false;
  idleCmdPending = false;
  portEXIT_CRITICAL(&mux);
  Serial.printf("Cmd side -> %s (0x%02X on 0x14EF114C)\n",
                (normalized == 0x03) ? "starboard" : "port", normalized);
}

static void applySpeedCommand(uint8_t speedTenths) {
  uint32_t now = millis();
  uint8_t cmd114C[8];
  uint8_t next4C11[6];
  portENTER_CRITICAL(&mux);
  buildBaseCmdFrameLocked(cmd114C, now);
  cmd114C[1] = 0x40;
  cmd114C[4] = speedTenths;
  memcpy(oneShotCmdFrame, cmd114C, 8);
  oneShotCmdPending = true;

  memcpy(next4C11, busFrame, 6);
  next4C11[2] = speedTenths;
  queueBurstLocked(next4C11, BURST_COUNT);
  portEXIT_CRITICAL(&mux);
  Serial.printf("Cmd speed -> %u.%u mph\n", speedTenths / 10, speedTenths % 10);
}

static void applyVolumeCommand(uint8_t volume) {
  uint32_t now = millis();
  uint8_t cmd114C[8];
  uint8_t next4C11[6];
  portENTER_CRITICAL(&mux);
  buildBaseCmdFrameLocked(cmd114C, now);
  cmd114C[1] = 0x40;
  cmd114C[6] = volume;
  memcpy(oneShotCmdFrame, cmd114C, 8);
  oneShotCmdPending = true;

  memcpy(next4C11, busFrame, 6);
  next4C11[4] = volume;
  queueBurstLocked(next4C11, BURST_COUNT);
  portEXIT_CRITICAL(&mux);
  Serial.printf("Cmd volume -> %u\n", volume);
}

static void applyShapeCommand(uint8_t shape) {
  uint8_t nib = shape & 0x0F;
  uint32_t now = millis();
  uint8_t cmd114C[8];
  uint8_t next4C11[6];
  portENTER_CRITICAL(&mux);
  buildBaseCmdFrameLocked(cmd114C, now);
  cmd114C[1] = 0x40;
  cmd114C[3] = (cmd114C[3] & 0x10) | nib;
  memcpy(oneShotCmdFrame, cmd114C, 8);
  oneShotCmdPending = true;

  memcpy(next4C11, busFrame, 6);
  next4C11[0] = (nib << 4) | (busFrame[0] & 0x0F);
  queueBurstLocked(next4C11, BURST_COUNT);
  portEXIT_CRITICAL(&mux);
  Serial.printf("Cmd shape -> %u\n", nib);
}

static void applyLightsCommand(bool lightsOn) {
  uint32_t now = millis();
  uint8_t cmd114C[8];
  uint8_t next4C11[6];
  portENTER_CRITICAL(&mux);
  buildBaseCmdFrameLocked(cmd114C, now);
  cmd114C[1] = 0x40;
  cmd114C[3] = (lightsOn ? 0x10 : 0x00) | (cmd114C[3] & 0x0F);
  memcpy(oneShotCmdFrame, cmd114C, 8);
  oneShotCmdPending = true;

  memcpy(next4C11, busFrame, 6);
  if (lightsOn) {
    next4C11[1] |= 0x01;
  } else {
    next4C11[1] &= ~0x01;
  }
  queueBurstLocked(next4C11, BURST_COUNT);
  portEXIT_CRITICAL(&mux);
  Serial.printf("Cmd lights -> %s\n", lightsOn ? "on" : "off");
}

static void applyShiftCommand(uint8_t shiftCmd) {
  uint8_t normalized = (shiftCmd == 0x00) ? 0x03 : shiftCmd;
  uint32_t now = millis();
  portENTER_CRITICAL(&mux);
  pendingShiftCmd = normalized;
  shiftTriesLeft = CMD_TRIES;
  shiftNextDueMs = now;
  shiftWaitingForPeer = false;
  portEXIT_CRITICAL(&mux);
  Serial.printf("Cmd ballast shift -> 0x%02X\n", normalized);
}

static void handleBlePayload(const uint8_t *cmd, size_t len) {
  // 1) New 3-byte explicit BLE command packet: [0xA5, opcode, value]
  if (len == 3 && cmd[0] == 0xA5) {
    switch (cmd[1]) {
      case 0x01: // Side: 0x01 Port (or 0x00 -> 0x01), 0x03 Starboard
        applySideCommand((cmd[2] == 0x03) ? 0x03 : 0x01);
        scheduleForceNotify();
        return;
      case 0x02: // Speed in 0.1 mph
        applySpeedCommand(cmd[2]);
        scheduleForceNotify();
        return;
      case 0x03: // Volume
        applyVolumeCommand(cmd[2]);
        scheduleForceNotify();
        return;
      case 0x04: // Shape (0..10)
        applyShapeCommand(cmd[2] & 0x0F);
        scheduleForceNotify();
        return;
      case 0x05: // Ballast shift: 0x09 Port, 0x0A Starboard, 0x03 Stop
        applyShiftCommand(cmd[2]);
        scheduleForceNotify();
        return;
      default:
        Serial.printf("Unknown 0xA5 opcode 0x%02X\n", cmd[1]);
        return;
    }
  }

  // 2) Legacy 5-byte linkData: [shape, side(0/1), speedTenths, volume, flags]
  if (len == 5) {
    uint8_t cur[6];
    portENTER_CRITICAL(&mux);
    memcpy(cur, busFrame, 6);
    portEXIT_CRITICAL(&mux);

    bool wantStarboard = (cmd[1] != 0);
    bool curStarboard = (cur[0] & 0x08) != 0;
    bool sideDiffers = (wantStarboard != curStarboard);
    bool shapeDiffers = ((cmd[0] & 0x0F) != ((cur[0] >> 4) & 0x0F));
    bool speedDiffers = (cmd[2] != cur[2]);
    bool volumeDiffers = (cmd[3] != cur[4]);
    bool shiftDiffers = (((cmd[4] & 0x01) != 0) != ((cur[5] & 0x01) != 0));

    if (shiftDiffers) {
      uint8_t shiftCmd = (cmd[4] & 0x01) ? (wantStarboard ? 0x0A : 0x09) : 0x03;
      applyShiftCommand(shiftCmd);
    } else if (sideDiffers && !shapeDiffers && !speedDiffers && !volumeDiffers) {
      applySideCommand(wantStarboard ? 0x03 : 0x01);
    } else {
      uint32_t now = millis();
      uint8_t cmd114C[8];
      uint8_t next4C11[6];
      portENTER_CRITICAL(&mux);
      buildBaseCmdFrameLocked(cmd114C, now);
      cmd114C[1] = 0x40;
      cmd114C[3] = (cmd114C[3] & 0x10) | (cmd[0] & 0x0F);
      cmd114C[4] = cmd[2];
      cmd114C[6] = cmd[3];
      memcpy(oneShotCmdFrame, cmd114C, 8);
      oneShotCmdPending = true;

      memcpy(next4C11, busFrame, 6);
      next4C11[0] = ((cmd[0] & 0x0F) << 4) | (busFrame[0] & 0x0F);
      next4C11[2] = cmd[2];
      next4C11[4] = cmd[3];
      queueBurstLocked(next4C11, BURST_COUNT);
      portEXIT_CRITICAL(&mux);
    }
    scheduleForceNotify();
    return;
  }

  // 3) Legacy 6-byte raw frame
  if (len >= 6) {
    uint8_t cur[6];
    portENTER_CRITICAL(&mux);
    memcpy(cur, busFrame, 6);
    portEXIT_CRITICAL(&mux);

    bool wantStarboard = (cmd[0] & 0x08) != 0;
    bool curStarboard = (cur[0] & 0x08) != 0;
    bool sideDiffers = (wantStarboard != curStarboard);
    bool shiftDiffers = (((cmd[5] & 0x01) != 0) != ((cur[5] & 0x01) != 0));
    bool bodyDiffers = ((cmd[0] & 0xF0) != (cur[0] & 0xF0)) ||
                       ((cmd[1] & 0x01) != (cur[1] & 0x01)) ||
                       (cmd[2] != cur[2]) ||
                       (cmd[4] != cur[4]);

    if (sideDiffers) {
      applySideCommand(wantStarboard ? 0x03 : 0x01);
    }
    if (shiftDiffers) {
      applyShiftCommand((cmd[5] & 0x01) ? (wantStarboard ? 0x0A : 0x09) : 0x03);
    }
    if (bodyDiffers || (!sideDiffers && !shiftDiffers)) {
      uint32_t now = millis();
      uint8_t cmd114C[8];
      uint8_t next4C11[6];
      portENTER_CRITICAL(&mux);
      memcpy(next4C11, cmd, 6);
      // NEVER transmit wave-side changes on 0x14EF4C11; preserve authoritative low nibble & shift status.
      next4C11[0] = (cmd[0] & 0xF0) | (busFrame[0] & 0x0F);
      next4C11[5] = busFrame[5];

      buildBaseCmdFrameLocked(cmd114C, now);
      cmd114C[1] = 0x40;
      cmd114C[3] = ((next4C11[1] & 0x01) ? 0x10 : 0x00) | ((next4C11[0] >> 4) & 0x0F);
      cmd114C[4] = next4C11[2];
      cmd114C[6] = next4C11[4];
      memcpy(oneShotCmdFrame, cmd114C, 8);
      oneShotCmdPending = true;

      queueBurstLocked(next4C11, BURST_COUNT);
      portEXIT_CRITICAL(&mux);
    }
    scheduleForceNotify();
  }
}

static void fillStateFrom(const uint8_t src[6], uint8_t out[5]) {
  out[0] = src[0] >> 4;
  out[1] = (src[0] & 0x08) ? 1 : 0;
  out[2] = src[2];
  out[3] = src[4];
  out[4] = (src[5] & 0x01) | ((src[1] & 0x01) ? 0x02 : 0x00);
}

static void publishState(bool force) {
  uint8_t raw[6];
  portENTER_CRITICAL(&mux);
  memcpy(raw, busFrame, 6);
  portEXIT_CRITICAL(&mux);

  static uint8_t lastRaw[6] = {0};
  static bool haveLast = false;
  if (!force && haveLast && memcmp(lastRaw, raw, 6) == 0) {
    return;
  }
  memcpy(lastRaw, raw, 6);
  haveLast = true;

  uint8_t stateBytes[5];
  fillStateFrom(raw, stateBytes);
  if (stateChar != nullptr) {
    stateChar->setValue(raw, 6);
    stateChar->notify();
  }
  Serial.printf(
      "Boat %02X %02X %02X %02X %02X %02X  %s shape %u  %u.%u mph  volume %u%s\n",
      raw[0], raw[1], raw[2], raw[3], raw[4], raw[5],
      stateBytes[1] ? "starboard" : "port",
      stateBytes[0],
      stateBytes[2] / 10, stateBytes[2] % 10,
      stateBytes[3],
      force ? " (sync)" : "");
}

static void publishSong() {
  char text[181];
  size_t n = 0;
  for (size_t i = 0; i < songLen && n + 1 < sizeof(text); i++) {
    uint8_t b = songParts[i];
    if (b >= 32 && b < 127) {
      text[n++] = (char)b;
    } else if (n && text[n - 1] != ' ') {
      text[n++] = ' ';
    }
  }
  text[n] = 0;
  while (n && text[n - 1] == ' ') {
    text[--n] = 0;
  }
  if (text[0] == 0 || strcmp(text, song) == 0) {
    return;
  }
  strncpy(song, text, sizeof(song) - 1);
  song[sizeof(song) - 1] = 0;
  if (songChar != nullptr) {
    songChar->setValue((uint8_t *)song, strlen(song));
    songChar->notify();
  }
  Serial.printf("Song %s\n", song);
}

static void onCan(const twai_message_t &msg) {
  if (!msg.extd || msg.rtr) {
    return;
  }
  uint32_t now = millis();
  uint8_t dlc = msg.data_length_code > 8 ? 8 : msg.data_length_code;

  if (msg.identifier == SURF_STATUS_ID && dlc >= 6) {
    bool busStarboard = (msg.data[0] & 0x08) != 0;
    bool flippedStop = false;
    portENTER_CRITICAL(&mux);
    if (!haveBus) {
      haveBus = true;
      firstBusMs = now;
      if (nextStandaloneHbMs == 0) {
        nextStandaloneHbMs = now + PEER_OFFLINE_MS;
      }
    }
    memcpy(busFrame, msg.data, 6);
    if (burstLeft > 0) {
      burstFrame[0] = (burstFrame[0] & 0xF0) | (msg.data[0] & 0x0F);
    }
    // Immediate stop on wave-side flip once at least 1 side frame was transmitted.
    if (pendingSideCmd != 0 && sideSentCount >= 1 && busStarboard == targetStarboard) {
      pendingSideCmd = 0;
      sideTriesLeft = 0;
      sideWaitingForPeer = false;
      flippedStop = true;
      if (!isPeerOnlineLocked(now)) {
        idleCmdPending = true;
        idleCmdDueMs = now + POST_FLIP_IDLE_DELAY_MS;
      }
    }
    portEXIT_CRITICAL(&mux);

    if (flippedStop) {
      Serial.printf("Wave flipped to %s, stopped side retries\n",
                    busStarboard ? "starboard" : "port");
    }
    publishState(false);
  } else if (msg.identifier == SURF_CMD_ID && dlc >= 8) {
    portENTER_CRITICAL(&mux);
    memcpy(peerEcho, msg.data, 8);
    lastPeerEchoMs = now;
    havePeerEcho = true;
    sideWaitingForPeer = false;
    shiftWaitingForPeer = false;
    idleCmdPending = false;
    portEXIT_CRITICAL(&mux);
  } else if (msg.identifier == TITLE_ID && dlc > 1) {
    if ((uint32_t)(now - songAt) > SONG_JOIN_MS) {
      songLen = 0;
    }
    songAt = now;
    for (uint8_t i = 1; i < dlc && songLen < sizeof(songParts); i++) {
      songParts[songLen++] = msg.data[i];
    }
    publishSong();
  }
}

static void noteCanTxError() {
  static uint32_t lastErrMs = 0;
  uint32_t now = millis();
  if ((uint32_t)(now - lastErrMs) > 1000) {
    lastErrMs = now;
    Serial.println("CAN transmit failed");
  }
}

static bool sendCanExtended(uint32_t id, const uint8_t *data, uint8_t dlc) {
  twai_message_t msg = {};
  msg.identifier = id;
  msg.extd = 1;
  msg.data_length_code = dlc;
  memcpy(msg.data, data, dlc);
  if (twai_transmit(&msg, pdMS_TO_TICKS(20)) != ESP_OK) {
    noteCanTxError();
    return false;
  }
  return true;
}

static bool sendCmd114C(const uint8_t data[8]) {
  if (!sendCanExtended(SURF_CMD_ID, data, 8)) {
    return false;
  }
  uint32_t txNow = millis();
  portENTER_CRITICAL(&mux);
  nextStandaloneHbMs = txNow + STANDALONE_HB_MS;
  portEXIT_CRITICAL(&mux);
  return true;
}

static void serviceOneShotCmd() {
  uint8_t frameToSend[8];
  bool due = false;
  portENTER_CRITICAL(&mux);
  if (oneShotCmdPending) {
    memcpy(frameToSend, oneShotCmdFrame, 8);
    oneShotCmdPending = false;
    due = true;
  }
  portEXIT_CRITICAL(&mux);
  if (due) {
    sendCmd114C(frameToSend);
  }
}

static void serviceSideSwitch(uint32_t now) {
  uint8_t frameToSend[8];
  bool shouldSend = false;

  portENTER_CRITICAL(&mux);
  if (pendingSideCmd != 0) {
    if (sideTriesLeft <= 0) {
      if ((int32_t)(now - sideExpireMs) >= 0) {
        pendingSideCmd = 0;
        if (!isPeerOnlineLocked(now)) {
          idleCmdPending = true;
          idleCmdDueMs = now + POST_FLIP_IDLE_DELAY_MS;
        }
      }
    } else if ((int32_t)(now - sideNextDueMs) >= 0 &&
               canTransmit114CLocked(now, sideWaitingForPeer, sidePeerWaitDeadlineMs)) {
      buildBaseCmdFrameLocked(frameToSend, now);
      frameToSend[0] = pendingSideCmd;
      shouldSend = true;
    }
  }
  portEXIT_CRITICAL(&mux);

  if (!shouldSend) {
    return;
  }
  bool ok = sendCmd114C(frameToSend);
  uint32_t afterTx = millis();
  portENTER_CRITICAL(&mux);
  if (pendingSideCmd != 0 && sideTriesLeft > 0) {
    if (ok) {
      sideSentCount++;
      sideTriesLeft--;
      sideWaitingForPeer = false;
      if (sideTriesLeft > 0) {
        sideNextDueMs = afterTx + CMD_RETRY_GAP_MS;
      } else {
        sideExpireMs = afterTx + 500;
      }
    } else if ((int32_t)(afterTx - sideExpireMs) >= 0) {
      pendingSideCmd = 0;
      sideTriesLeft = 0;
      sideWaitingForPeer = false;
    } else {
      sideNextDueMs = afterTx + 40;
    }
  }
  portEXIT_CRITICAL(&mux);
}

static void serviceShiftCmd(uint32_t now) {
  uint8_t frameToSend[8];
  bool shouldSend = false;

  portENTER_CRITICAL(&mux);
  if (shiftTriesLeft > 0 && (int32_t)(now - shiftNextDueMs) >= 0 &&
      canTransmit114CLocked(now, shiftWaitingForPeer, shiftPeerWaitDeadlineMs)) {
    buildBaseCmdFrameLocked(frameToSend, now);
    frameToSend[0] = 0x00;
    frameToSend[1] = 0x40;
    frameToSend[2] = pendingShiftCmd;
    shouldSend = true;
  }
  portEXIT_CRITICAL(&mux);

  if (!shouldSend) {
    return;
  }
  sendCmd114C(frameToSend);
  uint32_t afterTx = millis();
  portENTER_CRITICAL(&mux);
  if (shiftTriesLeft > 0) {
    shiftTriesLeft--;
    shiftWaitingForPeer = false;
    if (shiftTriesLeft > 0) {
      shiftNextDueMs = afterTx + CMD_RETRY_GAP_MS;
    } else {
      pendingShiftCmd = 0;
    }
  }
  portEXIT_CRITICAL(&mux);
}

static void serviceIdleCmd(uint32_t now) {
  uint8_t frameToSend[8];
  bool shouldSend = false;

  portENTER_CRITICAL(&mux);
  if (idleCmdPending && (int32_t)(now - idleCmdDueMs) >= 0) {
    idleCmdPending = false;
    if (!isPeerOnlineLocked(now) && pendingSideCmd == 0 && shiftTriesLeft == 0) {
      buildBaseCmdFrameLocked(frameToSend, now);
      frameToSend[0] = 0x00;
      shouldSend = true;
    }
  }
  portEXIT_CRITICAL(&mux);

  if (shouldSend) {
    sendCmd114C(frameToSend);
  }
}

static void serviceBurst4C11(uint32_t now) {
  uint8_t payload[6];
  bool shouldSend = false;

  portENTER_CRITICAL(&mux);
  if (burstLeft > 0 && (burstNextMs == 0 || (int32_t)(now - burstNextMs) >= 0)) {
    burstFrame[0] = (burstFrame[0] & 0xF0) | (busFrame[0] & 0x0F);
    memcpy(payload, burstFrame, 6);
    shouldSend = true;
  }
  portEXIT_CRITICAL(&mux);

  if (!shouldSend) {
    return;
  }
  sendCanExtended(SURF_STATUS_ID, payload, 6);
  uint32_t afterTx = millis();
  portENTER_CRITICAL(&mux);
  if (burstLeft > 0) {
    burstLeft--;
    burstNextMs = (burstLeft > 0) ? (afterTx + BURST_GAP_MS) : 0;
  }
  portEXIT_CRITICAL(&mux);
}

static void serviceStandaloneHeartbeat(uint32_t now) {
  uint8_t frameToSend[8];
  bool shouldSend = false;

  portENTER_CRITICAL(&mux);
  if (haveBus && !isPeerOnlineLocked(now) &&
      (havePeerEcho || (uint32_t)(now - firstBusMs) > PEER_OFFLINE_MS) &&
      pendingSideCmd == 0 && shiftTriesLeft == 0 && !idleCmdPending &&
      (nextStandaloneHbMs == 0 || (int32_t)(now - nextStandaloneHbMs) >= 0)) {
    buildBaseCmdFrameLocked(frameToSend, now);
    shouldSend = true;
  }
  portEXIT_CRITICAL(&mux);

  if (shouldSend) {
    sendCmd114C(frameToSend);
  }
}

static void serviceForceNotify(uint32_t now) {
  bool shouldNotify = false;
  portENTER_CRITICAL(&mux);
  if (forceNotifyPending && (int32_t)(now - forceNotifyAtMs) >= 0) {
    forceNotifyPending = false;
    shouldNotify = haveBus;
  }
  portEXIT_CRITICAL(&mux);

  if (shouldNotify) {
    publishState(true);
  }
}

static void serviceCanHealth(uint32_t now) {
  static uint32_t nextCheckMs = 0;
  if (nextCheckMs != 0 && (int32_t)(now - nextCheckMs) < 0) {
    return;
  }
  nextCheckMs = now + CAN_HEALTH_INTERVAL_MS;

  twai_status_info_t st;
  if (twai_get_status_info(&st) != ESP_OK) {
    return;
  }
  if (st.state == TWAI_STATE_BUS_OFF) {
    if (twai_initiate_recovery() == ESP_OK) {
      Serial.println("CAN bus-off, initiating recovery");
    }
  } else if (st.state == TWAI_STATE_STOPPED) {
    if (twai_start() == ESP_OK) {
      Serial.println("CAN restarted after recovery");
    }
  }
}

static void canTask(void *) {
  twai_general_config_t general = TWAI_GENERAL_CONFIG_DEFAULT(CAN_TX_PIN, CAN_RX_PIN, TWAI_MODE_NORMAL);
  general.rx_queue_len = 64;
  general.tx_queue_len = 16;
  twai_timing_config_t timing = TWAI_TIMING_CONFIG_250KBITS();
  twai_filter_config_t filter = TWAI_FILTER_CONFIG_ACCEPT_ALL();
  if (twai_driver_install(&general, &timing, &filter) != ESP_OK || twai_start() != ESP_OK) {
    Serial.println("CAN failed to start");
    vTaskDelete(nullptr);
    return;
  }
  Serial.printf("CAN %u kbit/s  TX GPIO %d  RX GPIO %d\n",
                (unsigned)(CAN_BITRATE / 1000), (int)CAN_TX_PIN, (int)CAN_RX_PIN);

  for (;;) {
    twai_message_t rx;
    if (twai_receive(&rx, pdMS_TO_TICKS(10)) == ESP_OK) {
      onCan(rx);
      while (twai_receive(&rx, 0) == ESP_OK) {
        onCan(rx);
      }
    }
    uint32_t now = millis();
    serviceCanHealth(now);
    serviceOneShotCmd();
    serviceSideSwitch(now);
    serviceShiftCmd(now);
    serviceIdleCmd(now);
    serviceBurst4C11(now);
    serviceStandaloneHeartbeat(now);
    serviceForceNotify(now);
  }
}

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *srv, esp_ble_gatts_cb_param_t *param) override {
    // 24..40 units of 1.25 ms is 30..50 ms. Apple accepts that range.
    srv->updateConnParams(param->connect.remote_bda, 24, 40, 0, 400);
    if (srv->getConnectedCount() + 1 < MAX_CLIENTS) {
      BLEDevice::startAdvertising();
    }
    scheduleAdvertising();
    Serial.println("BLE central connected");
  }

  void onDisconnect(BLEServer *srv) override {
    (void)srv;
    scheduleAdvertising();
    Serial.println("BLE central disconnected");
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic, esp_ble_gatts_cb_param_t *param) override {
    (void)param;
    std::string value = characteristic->getValue();
    if (value.empty()) {
      return;
    }
    handleBlePayload((const uint8_t *)value.data(), value.size());
  }
};

static void startBle() {
  BLEDevice::init(DEVICE_NAME);
  BLEDevice::setMTU(185);
  BLEDevice::setPower(ESP_PWR_LVL_P9);

  server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);

  stateChar = service->createCharacteristic(
      STATE_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  stateChar->addDescriptor(new BLE2902());
  stateChar->setValue(busFrame, 6);

  BLECharacteristic *command = service->createCharacteristic(
      COMMAND_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  command->setCallbacks(new CommandCallbacks());

  songChar = service->createCharacteristic(
      SONG_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  songChar->addDescriptor(new BLE2902());

  service->start();

  // The 128-bit service UUID fills the advertising packet; local name is in scan response.
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->start();
  Serial.println("BLE advertising as Surf Select");
}

static void handleLine(char *line) {
  while (*line == ' ') {
    line++;
  }
  char *arg = strchr(line, ' ');
  if (arg) {
    *arg++ = 0;
    while (*arg == ' ') {
      arg++;
    }
  }

  uint32_t now = millis();
  uint8_t curBus[6];
  uint8_t curPeer[8];
  bool busOk;
  bool peerOk;
  uint32_t peerAgeMs;
  portENTER_CRITICAL(&mux);
  memcpy(curBus, busFrame, 6);
  memcpy(curPeer, peerEcho, 8);
  busOk = haveBus;
  peerOk = isPeerOnlineLocked(now);
  peerAgeMs = havePeerEcho ? (now - lastPeerEchoMs) : 0;
  portEXIT_CRITICAL(&mux);

  uint8_t state[5];
  fillStateFrom(curBus, state);

  if (!strcmp(line, "status")) {
    Serial.printf(
        "status %s shape %u %u.%u mph volume %u lights %u shift %u bus %s peer200169 %s (%lu ms) clients %u/%u\n",
        state[1] ? "starboard" : "port",
        state[0], state[2] / 10, state[2] % 10, state[3],
        (state[4] >> 1) & 1, state[4] & 1,
        busOk ? "live" : "waiting",
        peerOk ? "inline" : "standalone",
        (unsigned long)peerAgeMs,
        server ? (unsigned)server->getConnectedCount() : 0U,
        (unsigned)MAX_CLIENTS);
    Serial.printf("  0x14EF4C11: %02X %02X %02X %02X %02X %02X\n",
                  curBus[0], curBus[1], curBus[2], curBus[3], curBus[4], curBus[5]);
    Serial.printf("  0x14EF114C: %02X %02X %02X %02X %02X %02X %02X %02X\n",
                  curPeer[0], curPeer[1], curPeer[2], curPeer[3],
                  curPeer[4], curPeer[5], curPeer[6], curPeer[7]);
    return;
  }

  if (!arg || !*arg) {
    return;
  }

  if (!strcmp(line, "side")) {
    bool stbd = (arg[0] == 's' || arg[0] == 'S' || arg[0] == '1' || arg[0] == '3');
    applySideCommand(stbd ? 0x03 : 0x01);
  } else if (!strcmp(line, "shape")) {
    uint8_t shape = (uint8_t)constrain(atoi(arg), 0, 15);
    applyShapeCommand(shape);
  } else if (!strcmp(line, "speed")) {
    double val = atof(arg);
    int tenths = (strchr(arg, '.') != nullptr || val <= 25.5)
                     ? (int)lround(val * 10.0)
                     : atoi(arg);
    applySpeedCommand((uint8_t)constrain(tenths, 0, 255));
  } else if (!strcmp(line, "vol") || !strcmp(line, "volume")) {
    applyVolumeCommand((uint8_t)constrain(atoi(arg), 0, 255));
  } else if (!strcmp(line, "lights")) {
    applyLightsCommand(atoi(arg) != 0 || arg[0] == 'o' || arg[0] == 'O');
  } else if (!strcmp(line, "shift")) {
    uint8_t shiftCmd = 0x03;
    if (arg[0] == 'p' || arg[0] == 'P') {
      shiftCmd = 0x09;
    } else if (!strncmp(arg, "stbd", 4) || !strncmp(arg, "star", 4)) {
      shiftCmd = 0x0A;
    } else if (!strncmp(arg, "stop", 4) || !strncmp(arg, "off", 3)) {
      shiftCmd = 0x03;
    } else if (arg[0] == 's' || arg[0] == 'S') {
      shiftCmd = 0x0A;
    } else {
      int n = (int)strtol(arg, nullptr, 0);
      if (n == 9) {
        shiftCmd = 0x09;
      } else if (n == 10) {
        shiftCmd = 0x0A;
      } else if (n == 1) {
        shiftCmd = state[1] ? 0x0A : 0x09;
      } else {
        shiftCmd = 0x03;
      }
    }
    applyShiftCommand(shiftCmd);
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("Surf Select 3.0 Bridge (ESP32)");
  startBle();
  xTaskCreatePinnedToCore(canTask, "can", 8192, nullptr, 5, nullptr, 0);
}

void loop() {
  uint32_t due = advertiseAt;
  if (due != 0 && (int32_t)(millis() - due) >= 0) {
    if (advertiseAt == due) {
      advertiseAt = 0;
    }
    if (server != nullptr && server->getConnectedCount() < MAX_CLIENTS) {
      BLEDevice::startAdvertising();
    }
  }

  static char line[64];
  static size_t len = 0;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\r' || c == '\n') {
      if (len) {
        line[len] = 0;
        handleLine(line);
        len = 0;
      }
    } else if (len + 1 < sizeof(line)) {
      line[len++] = c;
    }
  }
  delay(10);
}
