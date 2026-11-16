#pragma once

#include <stdint.h>

class NimBLEServer;

// Bump this when shipping a bin the phone should treat as a new release.
extern const char FIRMWARE_VERSION[];

void firmwareOtaStart(NimBLEServer *server);
void firmwareOtaOnDisconnect();
bool firmwareOtaPoll();
void firmwareOtaMarkValid();
void firmwareOtaPrint();
