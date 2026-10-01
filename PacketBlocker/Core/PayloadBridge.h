//
//  PayloadBridge.h
//  App side of the injected-payload control channel.
//
//  Two jobs:
//    1. HybridPayloadInject() — get libNetHookPayload.dylib into a live target
//       through task_for_pid + a remote dlopen thread, then PROVE it landed by
//       reading the target's image list back (the old injector returned 0 for
//       "thread started", which is indistinguishable from a failed dlopen).
//    2. The AF_UNIX client for AetherNetIPC: push config in, read telemetry out.
//
//  Both run through a short-lived root helper (the app itself is uid 501 and
//  cannot task_for_pid under PPL), reusing the -sockdump pattern already in
//  main.mm.
//
#ifndef PayloadBridge_h
#define PayloadBridge_h

#include <stdint.h>
#include "AetherNetIPC.h"

typedef enum {
    HybridInjectOK            =  1,
    HybridInjectNotAttempted  =  0,
    HybridInjectNoTaskPort    = -2,
    HybridInjectAllocFailed   = -3,
    HybridInjectThreadFailed  = -4,
    HybridInjectDylibMissing  = -5,
    HybridInjectSpawnFailed   = -6,
    HybridInjectTimeout       = -7,
    HybridInjectHelperFailed  = -8,
    HybridInjectLibValidation = -9,
} HybridInjectResult;

const char *HybridInjectResultString(int rc);

// Copies the bundled dylib to a root-readable path, spawns the root helper and
// waits (≤4 s) for its verdict. `errOut` (may be NULL) receives detail.
int HybridPayloadInject(int pid, char *errOut, int errOutLen);

// Control channel. Attach locates the target's socket inside the App Store
// container layout; the payload is the server because only it may create files
// in its own container.
int  HybridPayloadAttach(int pid);
void HybridPayloadDetach(void);
int  HybridPayloadIsAttached(void);

// Returns 1 when the config reached the payload.
int HybridPayloadSendConfig(int enabled, int targetPID, const char *bundleID,
                            int direction, int protocolFilter, int mode,
                            int captureRatio, int latencyMs, int jitterMs,
                            int autoFlushSeconds);

// Returns 1 when *out was filled with a fresh snapshot.
int HybridPayloadPoll(AetherIpcTelemetry *out);

uint32_t HybridBundleHash(const char *s);

// Publishes the selected target into the shared state. The HUD daemon reads
// targetBundleID when it writes the ellekit Filter plist — without this the
// filter could only name com.apple.UIKit, i.e. SpringBoard, and the payload was
// never loaded into the app the user actually targeted.
void HybridPayloadSetTarget(int pid, const char *bundleID);

// Root helper body, dispatched from main.mm with "-inject <pid> <dylib> <out>".
int HybridRunInjectHelper(int pid, const char *dylibPath, const char *outFile);

#endif /* PayloadBridge_h */