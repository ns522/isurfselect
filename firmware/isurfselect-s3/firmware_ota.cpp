// Phone-driven firmware update for the ESP32-S3 bridge.
//
// The iPhone writes an app image over BLE. The bridge stores it in the inactive
// OTA slot, checks the image, then reboots into it. A later web update uses the
// same path: the phone downloads a bin and pushes these same bytes.
//
// Service 7c4e0010-6f3b-4a1e-9c55-1b2d3e4f5061
//   0011 Info    Read, Notify   44-byte status (layout below)
//   0012 Control Write          begin / abort / commit / reboot
//   0013 Data    Write          u32le offset + payload, offset must match bytes kept
//
// Info layout, little endian:
//   0  u16  magic 0x4F53
//   2  u8   protocol 1
//   3  u8   hardware 1 (ESP32-S3)
//   4  16   running version, UTF-8, NUL padded
//  20  u8   state: 0 idle, 1 receiving, 2 verified, 3 error, 4 verifying
//  21  u8   error: 0 none, 1 bad command, 2 too large, 3 bad offset, 4 flash,
//                 5 crc, 6 rejected, 7 busy, 8 incomplete, 9 wrong image, 10 no partition
//  22  u8   running slot
//  23  u8   flags, bit 0 set once the new image is the boot image
//  24  u32  slot capacity
//  28  u32  bytes accepted
//  32  u32  expected image size
//  36  u32  expected crc32 (zlib)
//  40  u32  crc32 of accepted bytes
//
// Control:
//   1 BEGIN  u32le size, u32le crc32, then up to 15 bytes of version text
//   2 ABORT
//   3 COMMIT
//   4 REBOOT

#include "firmware_ota.h"

#include <NimBLEDevice.h>
#include <Update.h>
#include <esp_app_format.h>
#include <esp_ota_ops.h>
#include <string.h>

const char FIRMWARE_VERSION[] = "1.0.1";

static const char *OTA_SERVICE_UUID = "7c4e0010-6f3b-4a1e-9c55-1b2d3e4f5061";
static const char *OTA_INFO_UUID = "7c4e0011-6f3b-4a1e-9c55-1b2d3e4f5061";
static const char *OTA_CONTROL_UUID = "7c4e0012-6f3b-4a1e-9c55-1b2d3e4f5061";
static const char *OTA_DATA_UUID = "7c4e0013-6f3b-4a1e-9c55-1b2d3e4f5061";

static const uint8_t OTA_HARDWARE = 1;
static const uint8_t OTA_PROTOCOL = 1;
static const size_t OTA_INFO_LEN = 44;
static const size_t OTA_QUEUE_DEPTH = 4;
static const size_t OTA_PACKET_MAX = 512;

static const uint8_t OTA_KIND_CONTROL = 1;
static const uint8_t OTA_KIND_DATA = 2;

static const uint8_t OTA_CMD_BEGIN = 1;
static const uint8_t OTA_CMD_ABORT = 2;
static const uint8_t OTA_CMD_COMMIT = 3;
static const uint8_t OTA_CMD_REBOOT = 4;

static const uint8_t OTA_STATE_IDLE = 0;
static const uint8_t OTA_STATE_RECEIVING = 1;
static const uint8_t OTA_STATE_VERIFIED = 2;
static const uint8_t OTA_STATE_ERROR = 3;
static const uint8_t OTA_STATE_VERIFYING = 4;

static const uint8_t OTA_ERR_NONE = 0;
static const uint8_t OTA_ERR_BAD_COMMAND = 1;
static const uint8_t OTA_ERR_TOO_LARGE = 2;
static const uint8_t OTA_ERR_OFFSET = 3;
static const uint8_t OTA_ERR_FLASH = 4;
static const uint8_t OTA_ERR_CRC = 5;
static const uint8_t OTA_ERR_REJECTED = 6;
static const uint8_t OTA_ERR_BUSY = 7;
static const uint8_t OTA_ERR_INCOMPLETE = 8;
static const uint8_t OTA_ERR_IMAGE = 9;
static const uint8_t OTA_ERR_PARTITION = 10;

static const size_t OTA_HEAD_LEN = 36;

struct OtaPacket {
  uint8_t kind;
  uint16_t len;
  uint8_t data[OTA_PACKET_MAX];
};

static portMUX_TYPE otaMux = portMUX_INITIALIZER_UNLOCKED;
static OtaPacket otaQueue[OTA_QUEUE_DEPTH];
static volatile uint8_t otaHead = 0;
static volatile uint8_t otaTail = 0;
static volatile bool otaOverflow = false;
static volatile bool otaDisconnect = false;

static NimBLECharacteristic *otaInfoChar = nullptr;
static NimBLECharacteristic *otaControlChar = nullptr;
static NimBLECharacteristic *otaDataChar = nullptr;

static char runningVersion[16];
static uint8_t otaState = OTA_STATE_IDLE;
static uint8_t otaError = OTA_ERR_NONE;
static uint8_t otaSlot = 0;
static uint32_t otaSlotSize = 0;
static uint32_t otaReceived = 0;
static uint32_t otaImageSize = 0;
static uint32_t otaImageCrc = 0;
static uint32_t otaReceivedCrc = 0;
static uint8_t otaHeadBytes[OTA_HEAD_LEN];
static uint8_t otaHeadGot = 0;
static bool otaHeadChecked = false;

static uint32_t readU32(const uint8_t *data) {
  return (uint32_t)data[0] | ((uint32_t)data[1] << 8) | ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24);
}

// zlib CRC-32. `crc` is the value returned by the previous call, or 0 to start.
static uint32_t crc32Update(uint32_t crc, const uint8_t *data, size_t len) {
  crc = ~crc;
  while (len--) {
    crc ^= *data++;
    for (int bit = 0; bit < 8; bit++) {
      uint32_t mask = -(crc & 1u);
      crc = (crc >> 1) ^ (0xEDB88320u & mask);
    }
  }
  return ~crc;
}

static void refreshSlot() {
  const esp_partition_t *running = esp_ota_get_running_partition();
  otaSlot = 0;
  if (running && running->subtype >= ESP_PARTITION_SUBTYPE_APP_OTA_0 &&
      running->subtype <= ESP_PARTITION_SUBTYPE_APP_OTA_15) {
    otaSlot = (uint8_t)(running->subtype - ESP_PARTITION_SUBTYPE_APP_OTA_0);
  }
  const esp_partition_t *next = esp_ota_get_next_update_partition(nullptr);
  otaSlotSize = next ? next->size : 0;
}

static void fillInfo(uint8_t out[OTA_INFO_LEN]) {
  memset(out, 0, OTA_INFO_LEN);
  out[0] = 0x53;
  out[1] = 0x4F;
  out[2] = OTA_PROTOCOL;
  out[3] = OTA_HARDWARE;
  memcpy(out + 4, runningVersion, sizeof(runningVersion));
  portENTER_CRITICAL(&otaMux);
  uint8_t state = otaState;
  uint8_t error = otaError;
  uint8_t slot = otaSlot;
  uint32_t slotSize = otaSlotSize;
  uint32_t received = otaReceived;
  uint32_t imageSize = otaImageSize;
  uint32_t imageCrc = otaImageCrc;
  uint32_t receivedCrc = otaReceivedCrc;
  portEXIT_CRITICAL(&otaMux);
  out[20] = state;
  out[21] = error;
  out[22] = slot;
  out[23] = state == OTA_STATE_VERIFIED ? 0x01 : 0x00;
  memcpy(out + 24, &slotSize, 4);
  memcpy(out + 28, &received, 4);
  memcpy(out + 32, &imageSize, 4);
  memcpy(out + 36, &imageCrc, 4);
  memcpy(out + 40, &receivedCrc, 4);
}

static void publishInfo() {
  if (!otaInfoChar) {
    return;
  }
  uint8_t buf[OTA_INFO_LEN];
  fillInfo(buf);
  otaInfoChar->setValue(buf, sizeof(buf));
  otaInfoChar->notify();
}

static void failUpdate(uint8_t error) {
  if (Update.isRunning()) {
    Update.abort();
  }
  otaState = OTA_STATE_ERROR;
  otaError = error;
  Serial.printf("OTA error %u\n", error);
}

static void idleUpdate() {
  if (Update.isRunning()) {
    Update.abort();
  }
  otaState = OTA_STATE_IDLE;
  otaError = OTA_ERR_NONE;
  otaReceived = 0;
  otaImageSize = 0;
  otaImageCrc = 0;
  otaReceivedCrc = 0;
  otaHeadGot = 0;
  otaHeadChecked = false;
}

static bool imageHeaderRejected(const uint8_t head[OTA_HEAD_LEN]) {
  if (head[0] != ESP_IMAGE_HEADER_MAGIC) {
    return true;
  }
  uint16_t chip = (uint16_t)head[12] | ((uint16_t)head[13] << 8);
  if (chip != ESP_CHIP_ID_ESP32S3) {
    return true;
  }
  uint32_t desc = readU32(head + 32);
  return desc != ESP_APP_DESC_MAGIC_WORD;
}

static void rememberHeader(uint32_t offset, const uint8_t *data, size_t len) {
  for (size_t i = 0; i < len; i++) {
    uint32_t at = offset + (uint32_t)i;
    if (at < OTA_HEAD_LEN) {
      otaHeadBytes[at] = data[i];
      if (at + 1 > otaHeadGot) {
        otaHeadGot = (uint8_t)(at + 1);
      }
    }
  }
}

static void handleBegin(const uint8_t *data, size_t len) {
  if (otaState == OTA_STATE_VERIFYING || otaState == OTA_STATE_VERIFIED) {
    otaError = OTA_ERR_BUSY;
    return;
  }
  if (len < 9) {
    failUpdate(OTA_ERR_BAD_COMMAND);
    return;
  }
  uint32_t size = readU32(data + 1);
  uint32_t crc = readU32(data + 5);
  refreshSlot();
  if (otaSlotSize == 0) {
    failUpdate(OTA_ERR_PARTITION);
    return;
  }
  if (size < OTA_HEAD_LEN) {
    failUpdate(OTA_ERR_IMAGE);
    return;
  }
  if (size > otaSlotSize) {
    failUpdate(OTA_ERR_TOO_LARGE);
    return;
  }
  idleUpdate();
  if (!Update.begin(size)) {
    uint8_t error = Update.getError() == UPDATE_ERROR_NO_PARTITION ? OTA_ERR_PARTITION : OTA_ERR_FLASH;
    failUpdate(error);
    return;
  }
  otaImageSize = size;
  otaImageCrc = crc;
  otaState = OTA_STATE_RECEIVING;
  otaError = OTA_ERR_NONE;
  char label[16];
  memset(label, 0, sizeof(label));
  size_t labelLen = len - 9;
  if (labelLen > 15) {
    labelLen = 15;
  }
  memcpy(label, data + 9, labelLen);
  Serial.printf("OTA begin %u bytes crc %08x %s\n", size, crc, label);
}

static void handleAbort() {
  if (otaState == OTA_STATE_VERIFIED) {
    const esp_partition_t *running = esp_ota_get_running_partition();
    if (running) {
      esp_ota_set_boot_partition(running);
    }
  }
  idleUpdate();
  Serial.println("OTA aborted");
}

static void handleCommit() {
  if (otaState != OTA_STATE_RECEIVING) {
    otaError = OTA_ERR_BAD_COMMAND;
    return;
  }
  if (otaReceived != otaImageSize) {
    failUpdate(OTA_ERR_INCOMPLETE);
    return;
  }
  if (!otaHeadChecked || otaReceivedCrc != otaImageCrc) {
    failUpdate(otaHeadChecked ? OTA_ERR_CRC : OTA_ERR_IMAGE);
    return;
  }
  otaState = OTA_STATE_VERIFYING;
  otaError = OTA_ERR_NONE;
  publishInfo();
  if (!Update.end(true)) {
    Serial.printf("OTA verify failed: %s\n", Update.errorString());
    failUpdate(OTA_ERR_REJECTED);
    return;
  }
  otaState = OTA_STATE_VERIFIED;
  otaError = OTA_ERR_NONE;
  Serial.printf("OTA verified %u bytes\n", otaImageSize);
}

static void handleReboot() {
  if (otaState != OTA_STATE_VERIFIED) {
    otaError = OTA_ERR_BAD_COMMAND;
    publishInfo();
    return;
  }
  Serial.println("OTA reboot");
  publishInfo();
  delay(400);
  ESP.restart();
}

static void handleData(const uint8_t *data, size_t len) {
  if (otaState == OTA_STATE_ERROR) {
    return;
  }
  if (otaState != OTA_STATE_RECEIVING) {
    failUpdate(OTA_ERR_BAD_COMMAND);
    return;
  }
  if (len < 5) {
    failUpdate(OTA_ERR_BAD_COMMAND);
    return;
  }
  uint32_t offset = readU32(data);
  const uint8_t *payload = data + 4;
  size_t payloadLen = len - 4;
  if (offset != otaReceived) {
    if (offset < otaReceived && offset + payloadLen <= otaReceived) {
      return;
    }
    failUpdate(OTA_ERR_OFFSET);
    return;
  }
  if (otaReceived + payloadLen > otaImageSize) {
    failUpdate(OTA_ERR_TOO_LARGE);
    return;
  }

  rememberHeader(offset, payload, payloadLen);
  if (!otaHeadChecked && otaHeadGot >= OTA_HEAD_LEN) {
    otaHeadChecked = true;
    if (imageHeaderRejected(otaHeadBytes)) {
      failUpdate(OTA_ERR_IMAGE);
      return;
    }
  }

  size_t wrote = Update.write(const_cast<uint8_t *>(payload), payloadLen);
  if (wrote != payloadLen || Update.hasError()) {
    Serial.printf("OTA flash write failed: %s\n", Update.errorString());
    failUpdate(OTA_ERR_FLASH);
    return;
  }
  otaReceivedCrc = crc32Update(otaReceivedCrc, payload, payloadLen);
  otaReceived += payloadLen;
  uint32_t previous = otaReceived - (uint32_t)payloadLen;
  if ((otaReceived >> 16) != (previous >> 16) || otaReceived == otaImageSize) {
    Serial.printf("OTA %u/%u\n", otaReceived, otaImageSize);
  }
}

static void handlePacket(const OtaPacket *packet) {
  if (packet->kind == OTA_KIND_CONTROL) {
    if (packet->len < 1) {
      failUpdate(OTA_ERR_BAD_COMMAND);
    } else {
      switch (packet->data[0]) {
        case OTA_CMD_BEGIN:
          handleBegin(packet->data, packet->len);
          break;
        case OTA_CMD_ABORT:
          handleAbort();
          break;
        case OTA_CMD_COMMIT:
          handleCommit();
          break;
        case OTA_CMD_REBOOT:
          handleReboot();
          return;
        default:
          failUpdate(OTA_ERR_BAD_COMMAND);
          break;
      }
    }
  } else if (packet->kind == OTA_KIND_DATA) {
    handleData(packet->data, packet->len);
  } else {
    failUpdate(OTA_ERR_BAD_COMMAND);
  }
  publishInfo();
}

static bool enqueuePacket(uint8_t kind, const uint8_t *data, size_t len) {
  if (data == nullptr || len == 0 || len > OTA_PACKET_MAX) {
    return false;
  }
  portENTER_CRITICAL(&otaMux);
  uint8_t next = (uint8_t)((otaHead + 1) % OTA_QUEUE_DEPTH);
  if (next == otaTail) {
    otaOverflow = true;
    portEXIT_CRITICAL(&otaMux);
    return false;
  }
  OtaPacket *slot = &otaQueue[otaHead];
  slot->kind = kind;
  slot->len = (uint16_t)len;
  memcpy(slot->data, data, len);
  otaHead = next;
  portEXIT_CRITICAL(&otaMux);
  return true;
}

static bool dequeuePacket(OtaPacket *out) {
  portENTER_CRITICAL(&otaMux);
  if (otaTail == otaHead) {
    portEXIT_CRITICAL(&otaMux);
    return false;
  }
  *out = otaQueue[otaTail];
  otaTail = (uint8_t)((otaTail + 1) % OTA_QUEUE_DEPTH);
  portEXIT_CRITICAL(&otaMux);
  return true;
}

static void dropQueue() {
  portENTER_CRITICAL(&otaMux);
  otaTail = otaHead;
  portEXIT_CRITICAL(&otaMux);
}

class OtaCallbacks : public NimBLECharacteristicCallbacks {
  void onRead(NimBLECharacteristic *chr) override {
    uint8_t buf[OTA_INFO_LEN];
    fillInfo(buf);
    chr->setValue(buf, sizeof(buf));
  }

  void onWrite(NimBLECharacteristic *chr) override {
    NimBLEAttValue value = chr->getValue();
    uint8_t kind = chr == otaControlChar ? OTA_KIND_CONTROL : OTA_KIND_DATA;
    enqueuePacket(kind, value.data(), value.length());
  }
};

static OtaCallbacks otaCallbacks;

void firmwareOtaStart(NimBLEServer *server) {
  memset(runningVersion, 0, sizeof(runningVersion));
  strncpy(runningVersion, FIRMWARE_VERSION, sizeof(runningVersion) - 1);
  refreshSlot();
  otaState = OTA_STATE_IDLE;
  otaError = OTA_ERR_NONE;

  NimBLEService *svc = server->createService(OTA_SERVICE_UUID);
  otaInfoChar = svc->createCharacteristic(OTA_INFO_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  otaInfoChar->setCallbacks(&otaCallbacks);
  uint8_t info[OTA_INFO_LEN];
  fillInfo(info);
  otaInfoChar->setValue(info, sizeof(info));
  otaControlChar = svc->createCharacteristic(OTA_CONTROL_UUID, NIMBLE_PROPERTY::WRITE);
  otaControlChar->setCallbacks(&otaCallbacks);
  otaDataChar = svc->createCharacteristic(OTA_DATA_UUID, NIMBLE_PROPERTY::WRITE);
  otaDataChar->setCallbacks(&otaCallbacks);
  svc->start();
  Serial.printf("OTA firmware %s slot %u capacity %u\n", FIRMWARE_VERSION, otaSlot, otaSlotSize);
}

void firmwareOtaOnDisconnect() {
  portENTER_CRITICAL(&otaMux);
  otaDisconnect = true;
  portEXIT_CRITICAL(&otaMux);
}

bool firmwareOtaPoll() {
  bool activity = false;

  bool disconnected = false;
  portENTER_CRITICAL(&otaMux);
  if (otaDisconnect) {
    otaDisconnect = false;
    disconnected = true;
  }
  portEXIT_CRITICAL(&otaMux);
  if (disconnected) {
    dropQueue();
    if (otaState == OTA_STATE_RECEIVING) {
      idleUpdate();
      publishInfo();
      Serial.println("OTA dropped with the connection");
      activity = true;
    } else if (otaState == OTA_STATE_VERIFIED) {
      // The image is already the boot image. Apply it even if the phone drops
      // before the reboot command arrives.
      Serial.println("OTA reboot after disconnect");
      delay(200);
      ESP.restart();
    }
  }

  bool overflow = false;
  portENTER_CRITICAL(&otaMux);
  if (otaOverflow) {
    otaOverflow = false;
    overflow = true;
  }
  portEXIT_CRITICAL(&otaMux);
  if (overflow && otaState == OTA_STATE_RECEIVING) {
    failUpdate(OTA_ERR_OFFSET);
    publishInfo();
    activity = true;
  }

  OtaPacket packet;
  if (dequeuePacket(&packet)) {
    handlePacket(&packet);
    activity = true;
  }
  return activity;
}

void firmwareOtaMarkValid() {
  esp_err_t err = esp_ota_mark_app_valid_cancel_rollback();
  Serial.printf("OTA running image confirmed (%d)\n", (int)err);
}

void firmwareOtaPrint() {
  Serial.printf(
      "OTA version %s state %u error %u slot %u capacity %u received %u/%u crc %08x/%08x\n",
      FIRMWARE_VERSION, otaState, otaError, otaSlot, otaSlotSize, otaReceived, otaImageSize, otaReceivedCrc,
      otaImageCrc);
}
