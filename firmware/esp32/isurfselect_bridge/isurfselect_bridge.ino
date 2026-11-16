// isurfselect CAN-to-BLE bridge for classic ESP32.
//
// Hardware:
//   - CAN 250 kbit/s (29-bit extended) on GPIO5 (TX) and GPIO4 (RX)
//   - Arduino BLE peripheral ("iSurfSelect") supporting up to 3 simultaneous centrals
//     (e.g. iPhone + Apple Watch connected concurrently)
//
// Proven Nautique Surf Select 3.0 CAN protocol (aligned with isurfselect-s3.ino):
//   - 0x14EF4C11 (6 bytes, 4 Hz, LINC 0x11 -> Surf Select 0x4C): authoritative boat state
//   - 0x14EF114C (8 bytes, ~1 Hz, Surf Select 0x4C -> LINC 0x11): Surf Select commands & heartbeat
//   - 0x19FE0A05: stereo song title ASCII fragments (bytes[1..], 400 ms join window)
//   - PGN 130569 (0x1FE09): NMEA 2000 stereo status & track skip (0x0B Next / 0x0C Prev via 0x0DED0511)
//   - PGN 130574 (0x1FE0E): NMEA 2000 stereo zone count & custom boat zone names (Fast-Packet)
//   - PGN 130582 (0x1FE16): NMEA 2000 live per-zone volume & mute state
//   - PGN 126208 (0x1ED00): NMEA 2000 Request / Command Group Function for zone & track control

#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <driver/twai.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <string>

static const gpio_num_t CAN_TX_PIN = GPIO_NUM_5;
static const gpio_num_t CAN_RX_PIN = GPIO_NUM_4;
static const uint32_t CAN_BITRATE = 250000;

static const uint32_t SURF_STATUS_ID = 0x14EF4C11;
static const uint32_t SURF_CMD_ID = 0x14EF114C;
static const uint32_t TITLE_ID = 0x19FE0A05;

// NMEA 2000 Stereo Zone Discovery & Control constants
static const uint8_t DEFAULT_STEREO_SA = 0x05; // JL Audio MediaMaster MM105-HR / MM100s
static const uint8_t LINC_SA = 0x11;
static const uint8_t BRIDGE_SA = 0x4C;
static const uint32_t PGN_STEREO_PROP_FF02 = 0x0FF02; // 0x18FF0205
static const uint32_t PGN_STEREO_STATUS = 0x1FE09;    // 0x19FE0905
static const uint32_t PGN_STEREO_TITLE = 0x1FE0A;     // 0x19FE0A05
static const uint32_t PGN_ZONE_CONFIG = 0x1FE0E;      // 130574 (0x19FE0E05)
static const uint32_t PGN_ZONE_VOLUME = 0x1FE16;      // 130582 (0x19FE1605)

static const uint8_t MAX_ZONES = 8;
static const uint8_t DEFAULT_FALLBACK_ZONES = 4;
static const size_t MAX_ZONE_NAME_LEN = 24;
static const uint32_t ZONE_DISCOVERY_INITIAL_DELAY_MS = 600;
static const uint32_t ZONE_DISCOVERY_RETRY_MS = 5000;
static const uint8_t ZONE_DISCOVERY_MAX_TRIES = 6;
static const uint8_t N2K_FP_INTERFRAME_MS = 3;
static const uint8_t N2K_INTERPACKET_MS = 4;
static const size_t N2K_TX_QUEUE_CAP = 32;

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

static const char *DEVICE_NAME = "iSurfSelect";
static const char *SERVICE_UUID = "7c4e0001-6f3b-4a1e-9c55-1b2d3e4f5061";
static const char *STATE_UUID = "7c4e0002-6f3b-4a1e-9c55-1b2d3e4f5061";
static const char *COMMAND_UUID = "7c4e0003-6f3b-4a1e-9c55-1b2d3e4f5061";
static const char *SONG_UUID = "7c4e0004-6f3b-4a1e-9c55-1b2d3e4f5061";
static const char *ZONES_UUID = "7c4e0005-6f3b-4a1e-9c55-1b2d3e4f5061";

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

// Ballast shift state machine on 0x14EF114C ((steps << 2) | dir: 0x05..0x22, 0x03 = Stop)
static uint8_t pendingShiftCmd = 0;
static int shiftTriesLeft = 0;
static int shiftSentCount = 0;
static uint32_t shiftSeq = 0;
static uint32_t shiftNextDueMs = 0;
static uint32_t shiftExpireMs = 0;
static bool shiftWaitingForPeer = false;
static uint32_t shiftPeerWaitDeadlineMs = 0;

// Immediate one-shot 0x14EF114C command (for Speed, Volume, Shape, Lights)
static bool oneShotCmdPending = false;
static uint8_t oneShotCmdFrame[8] = {0};
static bool oneShotWaitingForPeer = false;
static uint32_t oneShotPeerWaitDeadlineMs = 0;

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

// Dynamic NMEA 2000 stereo zone discovery, tracking & Fast-Packet TX queue
struct StereoZoneEntry {
  uint8_t zoneId;
  uint8_t volumePct;
  bool muted;
  bool present;
  bool hasVolume;
  char name[MAX_ZONE_NAME_LEN + 1];
};

struct N2kTxFrame {
  uint32_t id;
  uint8_t data[8];
  uint8_t dlc;
  uint8_t gapAfterMs;
};

static uint8_t stereoSa = DEFAULT_STEREO_SA;
static StereoZoneEntry stereoZones[MAX_ZONES] = {};
static uint8_t configuredZoneCount = DEFAULT_FALLBACK_ZONES;
static bool haveZoneNames = false;
static bool haveZoneVolumes = false;
static bool zonesDirty = false;
static bool zonesForceNotifyPending = false;
static bool stateForceNotifyImmediate = false;

static bool stereoDiscoveryArmed = false;
static bool seenDirectStereoTraffic = false;
static uint32_t zoneDiscoveryNextMs = 0;
static uint8_t zoneDiscoveryTries = 0;

static uint8_t fp130574Buf[224];
static uint8_t fp130574TotalLen = 0;
static uint8_t fp130574AssembledLen = 0;
static uint8_t fp130574Seq = 0xFF;
static uint8_t fp130574NextIdx = 0;
static uint8_t fp130574Sa = 0;
static uint32_t fp130574StartMs = 0;

static N2kTxFrame n2kTxQueue[N2K_TX_QUEUE_CAP];
static size_t n2kTxHead = 0;
static size_t n2kTxCount = 0;
static uint32_t n2kNextTxMs = 0;
static uint8_t n2kSeq = 0;

static BLEServer *server = nullptr;
static BLECharacteristic *stateChar = nullptr;
static BLECharacteristic *songChar = nullptr;
static BLECharacteristic *zonesChar = nullptr;
static volatile uint32_t advertiseAt = 0;

static void publishState(bool force = false);
static void publishZones(bool force = false);
static void fillStateFrom(const uint8_t src[6], uint8_t out[5]);
static void applySideCommand(uint8_t sideCmd);
static void applySpeedCommand(uint8_t speedTenths);
static void applyVolumeCommand(uint8_t volume);
static void applyShapeCommand(uint8_t shape);
static void applyShiftCommand(uint8_t shiftCmd);
static void applyLightsCommand(bool lightsOn);
static void applyZoneVolumeCommand(uint8_t zoneId, uint8_t pct);
static void applyZoneStepCommand(uint8_t zoneId, bool stepUp);
static void applyZoneRefreshCommand();
static void applyTrackSkipCommand(bool nextTrack);
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
  shiftSeq++;
  pendingShiftCmd = normalized;
  shiftTriesLeft = CMD_TRIES;
  shiftSentCount = 0;
  shiftNextDueMs = now;
  shiftExpireMs = now + 2000;
  shiftWaitingForPeer = false;
  idleCmdPending = false;
  portEXIT_CRITICAL(&mux);

  if (normalized == 0x03) {
    Serial.println("Cmd ballast shift -> stop (0x03 on 0x14EF114C)");
  } else if (((normalized & 0x03) == 0x01 || (normalized & 0x03) == 0x02) &&
             (normalized >> 2) >= 1 && (normalized >> 2) <= 8) {
    const char *dir = ((normalized & 0x03) == 0x02) ? "starboard" : "port";
    unsigned lbs = (unsigned)(normalized >> 2) * 50U;
    Serial.printf("Cmd ballast shift -> %s %u lbs (0x%02X on 0x14EF114C)\n",
                  dir, lbs, (unsigned)normalized);
  } else {
    Serial.printf("Cmd ballast shift -> 0x%02X (on 0x14EF114C)\n", (unsigned)normalized);
  }
}

static uint32_t n2kGroupFuncId(uint8_t destSa) {
  return 0x0DED0000U | ((uint32_t)destSa << 8) | BRIDGE_SA;
}

static uint32_t n2kLincGroupFuncId(uint8_t destSa) {
  return 0x0DED0011U | ((uint32_t)destSa << 8);
}

static uint32_t n2kIsoReqId(uint8_t destSa) {
  return 0x18EA0000U | ((uint32_t)destSa << 8) | BRIDGE_SA;
}

static bool enqueueN2kSingleLocked(uint32_t id, const uint8_t *data, uint8_t dlc, uint8_t gapAfterMs) {
  if (n2kTxCount >= N2K_TX_QUEUE_CAP || dlc > 8) {
    return false;
  }
  size_t idx = (n2kTxHead + n2kTxCount) % N2K_TX_QUEUE_CAP;
  n2kTxQueue[idx].id = id;
  memset(n2kTxQueue[idx].data, 0, 8);
  memcpy(n2kTxQueue[idx].data, data, dlc);
  n2kTxQueue[idx].dlc = dlc;
  n2kTxQueue[idx].gapAfterMs = gapAfterMs;
  n2kTxCount++;
  return true;
}

static bool enqueueN2kFastPacket2Locked(uint32_t id, const uint8_t *payload, uint8_t payloadLen) {
  if (payloadLen < 7 || payloadLen > 13 || (n2kTxCount + 2) > N2K_TX_QUEUE_CAP) {
    return false;
  }
  n2kSeq = (uint8_t)((n2kSeq + 1) & 0x07);
  uint8_t seq = n2kSeq;

  uint8_t f0[8];
  f0[0] = (uint8_t)((seq << 5) | 0x00);
  f0[1] = payloadLen;
  memcpy(&f0[2], payload, 6);

  uint8_t f1[8];
  memset(f1, 0xFF, sizeof(f1));
  f1[0] = (uint8_t)((seq << 5) | 0x01);
  memcpy(&f1[1], &payload[6], payloadLen - 6);

  enqueueN2kSingleLocked(id, f0, 8, N2K_FP_INTERFRAME_MS);
  enqueueN2kSingleLocked(id, f1, 8, N2K_INTERPACKET_MS);
  return true;
}

static bool requestZoneNamesLocked() {
  const uint8_t req130574[13] = {
      0x00, 0x0E, 0xFE, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x01, 0x00};
  return enqueueN2kFastPacket2Locked(n2kGroupFuncId(stereoSa), req130574, sizeof(req130574));
}

static bool requestZoneVolumesLocked() {
  const uint8_t isoReq130582[3] = {0x16, 0xFE, 0x01};
  return enqueueN2kSingleLocked(
      n2kIsoReqId(stereoSa), isoReq130582, sizeof(isoReq130582), N2K_INTERPACKET_MS);
}

static void armZoneDiscoveryLocked(uint32_t now, bool directStereoFrame) {
  if (!stereoDiscoveryArmed) {
    stereoDiscoveryArmed = true;
    zoneDiscoveryTries = 0;
    zoneDiscoveryNextMs = now + ZONE_DISCOVERY_INITIAL_DELAY_MS;
  }
  if (directStereoFrame && !seenDirectStereoTraffic) {
    seenDirectStereoTraffic = true;
    if (!(haveZoneNames && haveZoneVolumes) && zoneDiscoveryTries > 0) {
      zoneDiscoveryTries = 0;
      zoneDiscoveryNextMs = now + ZONE_DISCOVERY_INITIAL_DELAY_MS;
    }
  }
}

static void applyZoneVolumeCommand(uint8_t zoneId, uint8_t pct) {
  if (zoneId == 0 || zoneId > MAX_ZONES) {
    Serial.printf("Ignored invalid zone id %u\n", (unsigned)zoneId);
    return;
  }
  uint8_t clampedPct = (pct > 100) ? 100 : pct;
  uint8_t sa;
  bool queued;
  portENTER_CRITICAL(&mux);
  sa = stereoSa;
  const uint8_t payload[10] = {
      0x01, 0x16, 0xFE, 0x01, 0xF8, 0x02, 0x01, zoneId, 0x02, clampedPct};
  queued = enqueueN2kFastPacket2Locked(n2kGroupFuncId(sa), payload, sizeof(payload));
  portEXIT_CRITICAL(&mux);
  Serial.printf("Cmd zone %u volume -> %u%% (SA 0x%02X%s)\n",
                (unsigned)zoneId,
                (unsigned)clampedPct,
                (unsigned)sa,
                queued ? "" : ", tx queue full");
}

static void applyZoneStepCommand(uint8_t zoneId, bool stepUp) {
  if (zoneId == 0 || zoneId > MAX_ZONES) {
    Serial.printf("Ignored invalid zone id %u\n", (unsigned)zoneId);
    return;
  }
  uint8_t dir = stepUp ? 0x00 : 0x01;
  uint8_t sa;
  bool queued;
  portENTER_CRITICAL(&mux);
  sa = stereoSa;
  const uint8_t payload[10] = {
      0x01, 0x16, 0xFE, 0x01, 0xF8, 0x02, 0x01, zoneId, 0x03, dir};
  queued = enqueueN2kFastPacket2Locked(n2kGroupFuncId(sa), payload, sizeof(payload));
  portEXIT_CRITICAL(&mux);
  Serial.printf("Cmd zone %u step -> %s (SA 0x%02X%s)\n",
                (unsigned)zoneId,
                stepUp ? "up" : "down",
                (unsigned)sa,
                queued ? "" : ", tx queue full");
}

static void applyZoneRefreshCommand() {
  uint8_t sa;
  portENTER_CRITICAL(&mux);
  sa = stereoSa;
  requestZoneNamesLocked();
  requestZoneVolumesLocked();
  zonesForceNotifyPending = true;
  stateForceNotifyImmediate = true;
  portEXIT_CRITICAL(&mux);
  Serial.printf("Cmd zones refresh (SA 0x%02X)\n", (unsigned)sa);
}

static void applyTrackSkipCommand(bool nextTrack) {
  uint8_t resolvedCmd = nextTrack ? 0x0B : 0x0C;
  uint8_t sa;
  uint32_t canId;
  bool queued;
  portENTER_CRITICAL(&mux);
  sa = stereoSa;
  canId = n2kLincGroupFuncId(sa);
  const uint8_t payload[8] = {
      0x01, 0x09, 0xFE, 0x01, 0xF8, 0x01, 0x05, resolvedCmd};
  queued = enqueueN2kFastPacket2Locked(canId, payload, sizeof(payload));
  portEXIT_CRITICAL(&mux);
  Serial.printf("Cmd stereo track -> %s (0x%02X on 0x%08lX%s)\n",
                nextTrack ? "next" : "prev",
                (unsigned)resolvedCmd,
                (unsigned long)canId,
                queued ? "" : ", tx queue full");
}

static void handleBlePayload(const uint8_t *cmd, size_t len) {
  // 1) Explicit 0xA5 BLE command packets (2..4 bytes; 6-byte raw frames with shape=10 fall through)
  if (len >= 2 && len <= 4 && cmd[0] == 0xA5) {
    switch (cmd[1]) {
      case 0x01: // Wave Side: 0x01 (or 0x00) -> Port (0x01), 0x03 -> Starboard (0x03)
        if (len >= 3) {
          applySideCommand((cmd[2] == 0x03) ? 0x03 : 0x01);
          scheduleForceNotify();
        }
        return;
      case 0x02: // Speed in 0.1 mph
        if (len >= 3) {
          applySpeedCommand(cmd[2]);
          scheduleForceNotify();
        }
        return;
      case 0x03: // Master Volume (0..40)
        if (len >= 3) {
          applyVolumeCommand((cmd[2] > 40) ? 40 : cmd[2]);
          scheduleForceNotify();
        }
        return;
      case 0x04: // Wave Shape (0..10)
        if (len >= 3) {
          applyShapeCommand((cmd[2] > 10) ? 10 : cmd[2]);
          scheduleForceNotify();
        }
        return;
      case 0x05: // Ballast Shift (50..400 lbs: (steps << 2) | dir, or [dir, steps], or 0x03 Stop)
        if (len == 3) {
          applyShiftCommand(cmd[2]);
          scheduleForceNotify();
        } else if (len >= 4) {
          uint8_t steps = (uint8_t)constrain((int)cmd[3], 1, 8);
          uint8_t b2Code = (uint8_t)((steps << 2) | (cmd[2] ? 0x02 : 0x01));
          applyShiftCommand(b2Code);
          scheduleForceNotify();
        }
        return;
      case 0x06: // Stereo Zone Direct Volume % ([0xA5, 0x06, zoneId, pct]) or 3-byte 0x03 Stop fallback
        if (len >= 4) {
          applyZoneVolumeCommand(cmd[2], (cmd[3] > 100) ? 100 : cmd[3]);
        } else if (len == 3 && (cmd[2] == 0x03 || cmd[2] == 0x00)) {
          applyShiftCommand(0x03);
          scheduleForceNotify();
        }
        return;
      case 0x07: // Stereo Zone Step ([0xA5, 0x07, zoneId, dir]: 0x00 Up, 0x01 Down)
        if (len >= 4) {
          applyZoneStepCommand(cmd[2], cmd[3] == 0x00);
        }
        return;
      case 0x08: // Refresh Stereo Zones (PGN 130574 + PGN 130582)
        applyZoneRefreshCommand();
        return;
      case 0x09: // Stop Ballast Pumps ([0xA5, 0x09, 0x03])
        applyShiftCommand(0x03);
        scheduleForceNotify();
        return;
      case 0x0A: // Stereo Track Skip ([0xA5, 0x0A, trackCmd]: 0x0B/0x01 Next, 0x0C/0x00 Prev)
        if (len >= 3) {
          if (cmd[2] == 0x0B || cmd[2] == 0x01) {
            applyTrackSkipCommand(true);
          } else if (cmd[2] == 0x0C || cmd[2] == 0x00) {
            applyTrackSkipCommand(false);
          } else {
            Serial.printf("Unknown track skip cmd 0x%02X\n", (unsigned)cmd[2]);
          }
        }
        return;
      default:
        Serial.printf("Unknown 0xA5 opcode 0x%02X\n", (unsigned)cmd[1]);
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

static size_t buildZonesPayloadLocked(uint8_t *buf, size_t cap) {
  if (cap < 2) {
    return 0;
  }
  buf[0] = 0x01;
  uint8_t count = 0;
  size_t pos = 2;
  uint8_t maxAllowed = haveZoneNames ? configuredZoneCount : DEFAULT_FALLBACK_ZONES;
  if (maxAllowed > MAX_ZONES) {
    maxAllowed = MAX_ZONES;
  }
  for (uint8_t i = 0; i < maxAllowed; i++) {
    const StereoZoneEntry &z = stereoZones[i];
    if (!z.present) {
      continue;
    }
    size_t nameLen = strnlen(z.name, MAX_ZONE_NAME_LEN);
    if (pos + 3 + nameLen > cap) {
      break;
    }
    uint8_t volPct = (z.volumePct > 100) ? 100 : z.volumePct;
    buf[pos++] = z.zoneId;
    buf[pos++] = (uint8_t)((z.muted ? 0x80 : 0x00) | (volPct & 0x7F));
    buf[pos++] = (uint8_t)nameLen;
    if (nameLen > 0) {
      memcpy(&buf[pos], z.name, nameLen);
      pos += nameLen;
    }
    count++;
  }
  buf[1] = count;
  return pos;
}

static void publishZones(bool force) {
  uint8_t payload[256];
  size_t payloadLen = 0;
  StereoZoneEntry snap[MAX_ZONES];
  uint8_t maxAllowed = 0;

  portENTER_CRITICAL(&mux);
  payloadLen = buildZonesPayloadLocked(payload, sizeof(payload));
  memcpy(snap, stereoZones, sizeof(snap));
  maxAllowed = haveZoneNames ? configuredZoneCount : DEFAULT_FALLBACK_ZONES;
  if (maxAllowed > MAX_ZONES) {
    maxAllowed = MAX_ZONES;
  }
  zonesDirty = false;
  portEXIT_CRITICAL(&mux);

  if (payloadLen < 2) {
    return;
  }

  static uint8_t lastPayload[256] = {0};
  static size_t lastPayloadLen = 0;
  if (!force && lastPayloadLen == payloadLen && memcmp(lastPayload, payload, payloadLen) == 0) {
    return;
  }
  memcpy(lastPayload, payload, payloadLen);
  lastPayloadLen = payloadLen;

  if (zonesChar != nullptr) {
    zonesChar->setValue(payload, payloadLen);
    zonesChar->notify();
  }

  Serial.printf("Zones (%u):", (unsigned)payload[1]);
  if (payload[1] == 0) {
    Serial.print(" none");
  } else {
    for (uint8_t i = 0; i < maxAllowed; i++) {
      if (snap[i].present) {
        Serial.printf(" %u[%s]=%u%%%s",
                      (unsigned)snap[i].zoneId,
                      snap[i].name,
                      (unsigned)snap[i].volumePct,
                      snap[i].muted ? "(M)" : "");
      }
    }
  }
  Serial.printf("%s\n", force ? " (sync)" : "");
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

static void parseZoneConfig130574(const uint8_t *body, size_t totalLen, uint8_t sa) {
  if (totalLen < 3) {
    return;
  }
  uint8_t firstZone = body[0];
  uint8_t zoneCount = body[1];
  uint8_t totalZones = body[2];
  (void)firstZone;

  if (totalZones == 0xFF) {
    totalZones = zoneCount;
  }
  if (totalZones > MAX_ZONES) {
    totalZones = MAX_ZONES;
  }

  bool changed = false;
  bool needVolumeRefresh = false;

  portENTER_CRITICAL(&mux);
  if (sa != BRIDGE_SA && sa != LINC_SA && stereoSa != sa) {
    stereoSa = sa;
  }
  if (!haveZoneNames || configuredZoneCount != totalZones) {
    configuredZoneCount = totalZones;
    haveZoneNames = true;
    changed = true;
  }
  for (uint8_t i = totalZones; i < MAX_ZONES; i++) {
    if (stereoZones[i].present) {
      stereoZones[i].present = false;
      changed = true;
    }
  }

  size_t pos = 3;
  for (uint8_t entry = 0; entry < zoneCount; entry++) {
    if (pos + 2 > totalLen) {
      break;
    }
    uint8_t zid = body[pos];
    uint8_t lauLen = body[pos + 1];
    if (lauLen < 2 || (pos + 1 + (size_t)lauLen) > totalLen) {
      break;
    }
    uint8_t enc = body[pos + 2];
    size_t strLen = (size_t)(lauLen - 2);
    const uint8_t *strBytes = &body[pos + 3];

    if (zid >= 1 && zid <= totalZones && zid <= MAX_ZONES) {
      char parsedName[MAX_ZONE_NAME_LEN + 1];
      size_t outIdx = 0;
      if (enc != 0x00) {
        for (size_t k = 0; k < strLen && outIdx < MAX_ZONE_NAME_LEN; k++) {
          uint8_t ch = strBytes[k];
          if (ch == 0x00 || ch == 0xFF) {
            break;
          }
          if (ch >= 0x20 && ch != 0x7F) {
            parsedName[outIdx++] = (char)ch;
          }
        }
      } else {
        for (size_t k = 0; k + 1 < strLen && outIdx < MAX_ZONE_NAME_LEN; k += 2) {
          uint8_t lo = strBytes[k];
          uint8_t hi = strBytes[k + 1];
          if (lo == 0x00 && hi == 0x00) {
            break;
          }
          if (hi == 0x00 && lo >= 0x20 && lo < 0x7F) {
            parsedName[outIdx++] = (char)lo;
          }
        }
      }
      while (outIdx > 0 && parsedName[outIdx - 1] == ' ') {
        outIdx--;
      }
      parsedName[outIdx] = '\0';
      if (parsedName[0] == '\0') {
        snprintf(parsedName, sizeof(parsedName), "Zone %u", (unsigned)zid);
      }

      StereoZoneEntry &z = stereoZones[zid - 1];
      if (!z.present || z.zoneId != zid || strcmp(z.name, parsedName) != 0) {
        z.zoneId = zid;
        z.present = true;
        strncpy(z.name, parsedName, sizeof(z.name) - 1);
        z.name[sizeof(z.name) - 1] = '\0';
        changed = true;
      }
      if (!z.hasVolume) {
        needVolumeRefresh = true;
      }
    }
    pos += 1 + (size_t)lauLen;
  }

  if (needVolumeRefresh && haveZoneVolumes) {
    haveZoneVolumes = false;
    requestZoneVolumesLocked();
  }
  if (changed) {
    zonesDirty = true;
  }
  portEXIT_CRITICAL(&mux);
}

static void onCanZoneConfigFastPacket(const twai_message_t &msg, uint8_t dlc, uint8_t sa, uint32_t now) {
  if (sa == BRIDGE_SA || sa == LINC_SA || dlc < 2) {
    return;
  }
  portENTER_CRITICAL(&mux);
  if (stereoSa != sa) {
    stereoSa = sa;
  }
  armZoneDiscoveryLocked(now, true);
  portEXIT_CRITICAL(&mux);

  uint8_t seq = (msg.data[0] >> 5) & 0x07;
  uint8_t frameIdx = msg.data[0] & 0x1F;

  if (frameIdx == 0) {
    uint8_t totalLen = msg.data[1];
    if (totalLen < 3 || totalLen > 223) {
      fp130574TotalLen = 0;
      return;
    }
    fp130574Seq = seq;
    fp130574Sa = sa;
    fp130574TotalLen = totalLen;
    fp130574AssembledLen = 0;
    fp130574NextIdx = 1;
    fp130574StartMs = now;
    for (uint8_t i = 2; i < dlc && fp130574AssembledLen < fp130574TotalLen; i++) {
      fp130574Buf[fp130574AssembledLen++] = msg.data[i];
    }
  } else {
    if (fp130574TotalLen == 0 ||
        (uint32_t)(now - fp130574StartMs) > 1000 ||
        seq != fp130574Seq ||
        sa != fp130574Sa ||
        frameIdx != fp130574NextIdx) {
      fp130574TotalLen = 0;
      return;
    }
    for (uint8_t i = 1; i < dlc && fp130574AssembledLen < fp130574TotalLen; i++) {
      fp130574Buf[fp130574AssembledLen++] = msg.data[i];
    }
    fp130574NextIdx++;
  }

  if (fp130574TotalLen > 0 && fp130574AssembledLen >= fp130574TotalLen) {
    uint8_t totalLen = fp130574TotalLen;
    fp130574TotalLen = 0;
    parseZoneConfig130574(fp130574Buf, totalLen, sa);
  }
}

static void onCanZoneVolume130582(const twai_message_t &msg, uint8_t dlc, uint8_t sa, uint32_t now) {
  // Ignore LINC (0x11) internal zones 05/06; only track stereo head unit (sa == stereoSa).
  if (sa == LINC_SA || dlc < 3) {
    return;
  }
  uint8_t zid = msg.data[0];
  uint8_t volPct = (msg.data[1] > 100) ? 100 : msg.data[1];
  bool muted = (((msg.data[2] >> 2) & 0x03) == 0x01);

  portENTER_CRITICAL(&mux);
  if (sa != stereoSa) {
    portEXIT_CRITICAL(&mux);
    return;
  }
  armZoneDiscoveryLocked(now, true);

  uint8_t maxAllowed = haveZoneNames ? configuredZoneCount : DEFAULT_FALLBACK_ZONES;
  if (maxAllowed > MAX_ZONES) {
    maxAllowed = MAX_ZONES;
  }
  if (zid == 0 || zid > maxAllowed) {
    portEXIT_CRITICAL(&mux);
    return;
  }

  StereoZoneEntry &z = stereoZones[zid - 1];
  bool changed = false;
  if (!z.present) {
    z.present = true;
    z.zoneId = zid;
    if (z.name[0] == '\0') {
      snprintf(z.name, sizeof(z.name), "Zone %u", (unsigned)zid);
    }
    changed = true;
  }
  if (!z.hasVolume || z.volumePct != volPct || z.muted != muted) {
    z.volumePct = volPct;
    z.muted = muted;
    z.hasVolume = true;
    changed = true;
  }
  haveZoneVolumes = true;
  if (changed) {
    zonesDirty = true;
  }
  portEXIT_CRITICAL(&mux);
}

static void onCan(const twai_message_t &msg) {
  if (!msg.extd || msg.rtr) {
    return;
  }
  uint32_t now = millis();
  uint8_t dlc = msg.data_length_code > 8 ? 8 : msg.data_length_code;
  uint32_t pgn = (msg.identifier >> 8) & 0x3FFFFU;
  uint8_t sa = (uint8_t)(msg.identifier & 0xFFU);

  if (msg.identifier == SURF_STATUS_ID && dlc >= 6) {
    bool busStarboard = (msg.data[0] & 0x08) != 0;
    bool busShiftActive = (msg.data[5] & 0x01) != 0;
    bool flippedStop = false;
    bool shiftConfirmedStop = false;
    bool shiftTargetActive = false;
    portENTER_CRITICAL(&mux);
    if (!haveBus) {
      haveBus = true;
      firstBusMs = now;
      if (nextStandaloneHbMs == 0) {
        nextStandaloneHbMs = now + PEER_OFFLINE_MS;
      }
      armZoneDiscoveryLocked(now, false);
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
      if (!isPeerOnlineLocked(now) && pendingShiftCmd == 0) {
        idleCmdPending = true;
        idleCmdDueMs = now + POST_FLIP_IDLE_DELAY_MS;
      }
    }
    // Immediate stop on ballast shift start/stop confirmation once at least 1 frame was transmitted.
    if (pendingShiftCmd != 0 && shiftSentCount >= 1) {
      bool wantActive = (pendingShiftCmd != 0x03);
      if (busShiftActive == wantActive) {
        pendingShiftCmd = 0;
        shiftTriesLeft = 0;
        shiftWaitingForPeer = false;
        shiftConfirmedStop = true;
        shiftTargetActive = wantActive;
        if (!isPeerOnlineLocked(now) && pendingSideCmd == 0) {
          idleCmdPending = true;
          idleCmdDueMs = now + POST_FLIP_IDLE_DELAY_MS;
        }
      }
    }
    portEXIT_CRITICAL(&mux);

    if (flippedStop) {
      Serial.printf("Wave flipped to %s, stopped side retries\n",
                    busStarboard ? "starboard" : "port");
    }
    if (shiftConfirmedStop) {
      Serial.printf("Ballast shift %s on 0x14EF4C11, stopped shift retries\n",
                    shiftTargetActive ? "started" : "stopped");
    }
    publishState(false);
  } else if (msg.identifier == SURF_CMD_ID && dlc >= 8) {
    portENTER_CRITICAL(&mux);
    memcpy(peerEcho, msg.data, 8);
    lastPeerEchoMs = now;
    havePeerEcho = true;
    oneShotWaitingForPeer = false;
    sideWaitingForPeer = false;
    shiftWaitingForPeer = false;
    idleCmdPending = false;
    portEXIT_CRITICAL(&mux);
  } else if (pgn == PGN_ZONE_CONFIG) {
    onCanZoneConfigFastPacket(msg, dlc, sa, now);
  } else if (pgn == PGN_ZONE_VOLUME) {
    onCanZoneVolume130582(msg, dlc, sa, now);
  } else {
    bool isTitle = (msg.identifier == TITLE_ID);
    bool isStereoTraffic = false;
    portENTER_CRITICAL(&mux);
    if (pgn == PGN_STEREO_TITLE && sa == stereoSa) {
      isTitle = true;
    }
    if (isTitle || ((pgn == PGN_STEREO_PROP_FF02 || pgn == PGN_STEREO_STATUS) && sa == stereoSa)) {
      isStereoTraffic = true;
      armZoneDiscoveryLocked(now, true);
    }
    portEXIT_CRITICAL(&mux);

    if (isTitle && dlc > 1) {
      (void)isStereoTraffic;
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

static void serviceOneShotCmd(uint32_t now) {
  uint8_t frameToSend[8];
  bool due = false;
  portENTER_CRITICAL(&mux);
  if (oneShotCmdPending &&
      canTransmit114CLocked(now, oneShotWaitingForPeer, oneShotPeerWaitDeadlineMs)) {
    memcpy(frameToSend, oneShotCmdFrame, 8);
    oneShotCmdPending = false;
    oneShotWaitingForPeer = false;
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
  uint32_t seqSnap = 0;

  portENTER_CRITICAL(&mux);
  if (pendingShiftCmd != 0) {
    if (shiftTriesLeft <= 0) {
      if ((int32_t)(now - shiftExpireMs) >= 0) {
        pendingShiftCmd = 0;
        if (!isPeerOnlineLocked(now) && pendingSideCmd == 0) {
          idleCmdPending = true;
          idleCmdDueMs = now + POST_FLIP_IDLE_DELAY_MS;
        }
      }
    } else if ((int32_t)(now - shiftNextDueMs) >= 0 &&
               canTransmit114CLocked(now, shiftWaitingForPeer, shiftPeerWaitDeadlineMs)) {
      buildBaseCmdFrameLocked(frameToSend, now);
      frameToSend[0] = 0x00;
      frameToSend[1] = 0x40;
      frameToSend[2] = pendingShiftCmd;
      seqSnap = shiftSeq;
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
  if (shiftSeq == seqSnap && pendingShiftCmd != 0 && shiftTriesLeft > 0) {
    if (ok) {
      shiftSentCount++;
      shiftTriesLeft--;
      shiftWaitingForPeer = false;
      if (shiftTriesLeft > 0) {
        shiftNextDueMs = afterTx + CMD_RETRY_GAP_MS;
      } else {
        shiftExpireMs = afterTx + 500;
      }
    } else if ((int32_t)(afterTx - shiftExpireMs) >= 0) {
      pendingShiftCmd = 0;
      shiftTriesLeft = 0;
      shiftWaitingForPeer = false;
    } else {
      shiftNextDueMs = afterTx + 40;
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
    if (!isPeerOnlineLocked(now) && pendingSideCmd == 0 && pendingShiftCmd == 0) {
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
      pendingSideCmd == 0 && pendingShiftCmd == 0 && !idleCmdPending &&
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

static bool hasN2kWorkPending() {
  bool pending = false;
  portENTER_CRITICAL(&mux);
  pending = (n2kTxCount > 0) || zonesForceNotifyPending || stateForceNotifyImmediate || zonesDirty ||
            oneShotCmdPending || (pendingSideCmd != 0) || (pendingShiftCmd != 0) || (burstLeft > 0);
  portEXIT_CRITICAL(&mux);
  return pending;
}

static void serviceZoneDiscovery(uint32_t now) {
  bool queuedNames = false;
  bool queuedVols = false;
  uint8_t tryNum = 0;
  uint8_t sa = DEFAULT_STEREO_SA;

  portENTER_CRITICAL(&mux);
  if (stereoDiscoveryArmed && !(haveZoneNames && haveZoneVolumes) &&
      zoneDiscoveryTries < ZONE_DISCOVERY_MAX_TRIES &&
      (int32_t)(now - zoneDiscoveryNextMs) >= 0) {
    zoneDiscoveryTries++;
    tryNum = zoneDiscoveryTries;
    zoneDiscoveryNextMs = now + ZONE_DISCOVERY_RETRY_MS;
    sa = stereoSa;
    if (!haveZoneNames) {
      queuedNames = requestZoneNamesLocked();
    }
    if (!haveZoneVolumes) {
      queuedVols = requestZoneVolumesLocked();
    }
  }
  portEXIT_CRITICAL(&mux);

  if (queuedNames || queuedVols) {
    Serial.printf("Stereo discovery #%u/%u -> SA 0x%02X (%s%s%s)\n",
                  (unsigned)tryNum,
                  (unsigned)ZONE_DISCOVERY_MAX_TRIES,
                  (unsigned)sa,
                  queuedNames ? "130574" : "",
                  (queuedNames && queuedVols) ? "+" : "",
                  queuedVols ? "130582" : "");
  }
}

static void serviceN2kTxQueue(uint32_t now) {
  N2kTxFrame item = {};
  bool shouldSend = false;

  portENTER_CRITICAL(&mux);
  if (n2kTxCount == 0) {
    if (n2kNextTxMs != 0 && (int32_t)(now - n2kNextTxMs) >= 0) {
      n2kNextTxMs = 0;
    }
  } else if (n2kNextTxMs == 0 || (int32_t)(now - n2kNextTxMs) >= 0) {
    item = n2kTxQueue[n2kTxHead];
    n2kTxHead = (n2kTxHead + 1) % N2K_TX_QUEUE_CAP;
    n2kTxCount--;
    shouldSend = true;
  }
  portEXIT_CRITICAL(&mux);

  if (!shouldSend) {
    return;
  }
  sendCanExtended(item.id, item.data, item.dlc);
  uint32_t afterTx = millis();
  portENTER_CRITICAL(&mux);
  n2kNextTxMs = afterTx + item.gapAfterMs;
  portEXIT_CRITICAL(&mux);
}

static void serviceZonesNotify() {
  bool forceZones = false;
  bool dirtyZones = false;
  bool forceStateNow = false;

  portENTER_CRITICAL(&mux);
  forceZones = zonesForceNotifyPending;
  dirtyZones = zonesDirty;
  forceStateNow = stateForceNotifyImmediate;
  zonesForceNotifyPending = false;
  stateForceNotifyImmediate = false;
  portEXIT_CRITICAL(&mux);

  if (forceStateNow) {
    publishState(true);
  }
  if (forceZones || dirtyZones) {
    publishZones(forceZones);
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
    TickType_t rxWait = hasN2kWorkPending() ? pdMS_TO_TICKS(2) : pdMS_TO_TICKS(10);
    twai_message_t rx;
    if (twai_receive(&rx, rxWait) == ESP_OK) {
      onCan(rx);
      while (twai_receive(&rx, 0) == ESP_OK) {
        onCan(rx);
      }
    }
    uint32_t now = millis();
    serviceCanHealth(now);
    serviceOneShotCmd(now);
    serviceSideSwitch(now);
    serviceShiftCmd(now);
    serviceIdleCmd(now);
    serviceBurst4C11(now);
    serviceStandaloneHeartbeat(now);
    serviceZoneDiscovery(now);
    serviceN2kTxQueue(now);
    serviceZonesNotify();
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

  // 24 handles comfortably fits 4 characteristics + BLE2902 descriptors (default 15 is limited to 3).
  BLEService *service = server->createService(BLEUUID(SERVICE_UUID), 24);

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

  zonesChar = service->createCharacteristic(
      ZONES_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  zonesChar->addDescriptor(new BLE2902());
  uint8_t emptyZones[2] = {0x01, 0x00};
  zonesChar->setValue(emptyZones, sizeof(emptyZones));

  service->start();

  // The 128-bit service UUID fills the advertising packet; local name is in scan response.
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->start();
  Serial.println("BLE advertising as iSurfSelect");
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
  StereoZoneEntry snapZones[MAX_ZONES];
  uint8_t maxAllowedZones;
  uint8_t curStereoSa;
  portENTER_CRITICAL(&mux);
  memcpy(curBus, busFrame, 6);
  memcpy(curPeer, peerEcho, 8);
  busOk = haveBus;
  peerOk = isPeerOnlineLocked(now);
  peerAgeMs = havePeerEcho ? (now - lastPeerEchoMs) : 0;
  memcpy(snapZones, stereoZones, sizeof(snapZones));
  maxAllowedZones = haveZoneNames ? configuredZoneCount : DEFAULT_FALLBACK_ZONES;
  if (maxAllowedZones > MAX_ZONES) {
    maxAllowedZones = MAX_ZONES;
  }
  curStereoSa = stereoSa;
  portEXIT_CRITICAL(&mux);

  uint8_t activeZoneCount = 0;
  for (uint8_t i = 0; i < maxAllowedZones; i++) {
    if (snapZones[i].present) {
      activeZoneCount++;
    }
  }

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
    Serial.printf("  stereo SA 0x%02X zones (%u):", (unsigned)curStereoSa, (unsigned)activeZoneCount);
    if (activeZoneCount == 0) {
      Serial.println(" none");
    } else {
      for (uint8_t i = 0; i < maxAllowedZones; i++) {
        if (snapZones[i].present) {
          Serial.printf(" %u[%s]=%u%%%s",
                        (unsigned)snapZones[i].zoneId,
                        snapZones[i].name,
                        (unsigned)snapZones[i].volumePct,
                        snapZones[i].muted ? "(M)" : "");
        }
      }
      Serial.println();
    }
    return;
  }

  if (!strcmp(line, "zones")) {
    if (activeZoneCount == 0) {
      Serial.printf("No stereo zones discovered yet (SA 0x%02X); refreshing...\n",
                    (unsigned)curStereoSa);
      applyZoneRefreshCommand();
    } else {
      for (uint8_t i = 0; i < maxAllowedZones; i++) {
        if (snapZones[i].present) {
          Serial.printf("Zone %u [%s]: %u%%%s\n",
                        (unsigned)snapZones[i].zoneId,
                        snapZones[i].name,
                        (unsigned)snapZones[i].volumePct,
                        snapZones[i].muted ? " (muted)" : "");
        }
      }
    }
    return;
  }

  if (!arg || !*arg) {
    if (!strcmp(line, "shift")) {
      Serial.println("Usage: shift <stop|port [50..400]|stbd [50..400]>");
    } else if (!strcmp(line, "track")) {
      Serial.println("Usage: track <next|prev>");
    }
    return;
  }

  if (!strcmp(line, "track")) {
    if (!strcasecmp(arg, "next") || !strcasecmp(arg, "n") ||
        !strcmp(arg, "+") || !strcmp(arg, ">")) {
      applyTrackSkipCommand(true);
    } else if (!strncasecmp(arg, "prev", 4) || !strcasecmp(arg, "p") ||
               !strcasecmp(arg, "back") || !strcmp(arg, "-") || !strcmp(arg, "<")) {
      applyTrackSkipCommand(false);
    } else {
      Serial.println("Usage: track <next|prev>");
    }
    return;
  }

  if (!strcmp(line, "zone")) {
    char *rest = nullptr;
    long zid = strtol(arg, &rest, 10);
    while (rest && *rest == ' ') {
      rest++;
    }
    if (zid < 1 || zid > MAX_ZONES || !rest || !*rest) {
      Serial.println("Usage: zone <1..8> <0..100|+|-|up|down>");
      return;
    }
    if (!strcmp(rest, "+") || !strcasecmp(rest, "up")) {
      applyZoneStepCommand((uint8_t)zid, true);
    } else if (!strcmp(rest, "-") || !strcasecmp(rest, "down") || !strcasecmp(rest, "dn")) {
      applyZoneStepCommand((uint8_t)zid, false);
    } else {
      char *endPtr = nullptr;
      long pct = strtol(rest, &endPtr, 10);
      if (endPtr == rest) {
        Serial.println("Usage: zone <1..8> <0..100|+|-|up|down>");
        return;
      }
      applyZoneVolumeCommand((uint8_t)zid, (uint8_t)constrain((int)pct, 0, 100));
    }
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
    const char *wordEnd = arg;
    while (*wordEnd && *wordEnd != ' ') {
      wordEnd++;
    }
    size_t wordLen = (size_t)(wordEnd - arg);
    const char *rest = wordEnd;
    while (*rest == ' ') {
      rest++;
    }

    if ((wordLen == 4 && !strncasecmp(arg, "stop", 4)) ||
        (wordLen == 3 && !strncasecmp(arg, "off", 3))) {
      applyShiftCommand(0x03);
      return;
    }

    uint8_t dirBits = 0;
    if ((wordLen == 4 && !strncasecmp(arg, "port", 4)) ||
        (wordLen == 1 && (arg[0] == 'p' || arg[0] == 'P'))) {
      dirBits = 0x01;
    } else if ((wordLen == 4 && (!strncasecmp(arg, "stbd", 4) || !strncasecmp(arg, "star", 4))) ||
               (wordLen == 9 && !strncasecmp(arg, "starboard", 9)) ||
               (wordLen == 1 && (arg[0] == 's' || arg[0] == 'S'))) {
      dirBits = 0x02;
    }

    if (dirBits != 0) {
      int steps = 1; // default 50 lbs -> steps = 1 (0x05 Port / 0x06 Stbd)
      if (*rest) {
        char *endPtr = nullptr;
        long val = strtol(rest, &endPtr, 10);
        if (endPtr == rest || val <= 0) {
          Serial.println("Usage: shift <stop|port [50..400]|stbd [50..400]>");
          return;
        }
        steps = (val <= 8) ? (int)val : (int)((val + 25) / 50);
        steps = constrain(steps, 1, 8);
      }
      applyShiftCommand((uint8_t)((steps << 2) | dirBits));
      return;
    }

    char *endPtr = nullptr;
    long rawCode = strtol(arg, &endPtr, 0);
    if (endPtr != arg && (rawCode == 0 || rawCode == 3)) {
      applyShiftCommand(0x03);
    } else if (endPtr != arg && rawCode >= 0x05 && rawCode <= 0x22) {
      applyShiftCommand((uint8_t)rawCode);
    } else {
      Serial.println("Usage: shift <stop|port [50..400]|stbd [50..400]>");
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("iSurfSelect bridge (ESP32)");
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
