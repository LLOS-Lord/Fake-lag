//
//  AetherNetIPC.h
//  Wire format for the injected-payload control channel.
//
//  WHY THIS EXISTS
//  The payload runs INSIDE the target process, which is sandboxed: it cannot
//  open /var/mobile/Library/Caches/*.shm or hybrid_config.json, and
//  AetherGetSharedState() silently falls back to the target's OWN
//  NSTemporaryDirectory() shm — whose magic matches, so the old loader treated
//  it as authoritative and short-circuited every fallback. Result: gActive was
//  permanently false and not one packet was ever intercepted.
//
//  The fix is a channel the target can actually use: a UNIX socket bound
//  INSIDE the target's own TMPDIR ($TMPDIR/aether_net_<pid>.sock). The payload
//  is the server (only it can create files in its container); the root app is
//  the client and finds the socket by globbing the Data containers. No shared
//  filesystem path, no entitlement, no seatbelt exception.
//
#ifndef AetherNetIPC_h
#define AetherNetIPC_h

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define AETHER_IPC_MAGIC     0xA374EC01u
#define AETHER_IPC_VERSION   1u

// Socket basename; %d is replaced with the owning pid.
#define AETHER_IPC_SOCK_NAME "aether_net_%d.sock"
// Where the root side globs for it (iOS 14+ App Store container layout).
#define AETHER_IPC_DATA_ROOT "/var/mobile/Containers/Data/Application"

// Telemetry status values.
#define AETHER_IPC_ST_LISTENING  1u  // socket bound, waiting for the app
#define AETHER_IPC_ST_HOOKED     2u  // hooks actually installed
#define AETHER_IPC_ST_NO_ENGINE  3u  // no hook engine in this process
#define AETHER_IPC_ST_GATED      4u  // running but not the attached target

// hookMask bits — which symbols really got hooked (not merely requested).
#define AETHER_HOOK_SEND     (1u << 0)
#define AETHER_HOOK_SENDTO   (1u << 1)
#define AETHER_HOOK_SENDMSG  (1u << 2)
#define AETHER_HOOK_RECV     (1u << 3)
#define AETHER_HOOK_RECVFROM (1u << 4)
#define AETHER_HOOK_RECVMSG  (1u << 5)
#define AETHER_HOOK_ALL      0x3Fu

// FNV-1a — must stay bit-identical on both sides.
static inline uint32_t AetherBundleHash(const char *s) {
    uint32_t h = 2166136261u;
    if (!s) return 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
        h ^= *p;
        h *= 16777619u;
    }
    return h ? h : 1u;
}

// app -> payload
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t seq;            // bumped on every change; payload acks it back
    int32_t  targetPID;      // primary target selector (0 = ignore)
    uint32_t bundleHash;     // secondary selector, survives a pid change
    uint32_t enabled;        // master switch (floating button)
    uint32_t direction;      // 0 both, 1 download, 2 upload
    uint32_t protocolFilter; // 0 tcp+udp, 1 udp, 2 tcp
    uint32_t mode;           // 0 hold, 1 drop, 2 delay, 3 tamper
    uint32_t captureRatio;   // 0..100
    uint32_t latencyMs;
    uint32_t jitterMs;
    uint32_t autoFlushSeconds; // 0 = manual
} AetherIpcConfig;

// payload -> app
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t seq;          // config seq this snapshot reflects
    uint32_t status;       // AETHER_IPC_ST_*
    uint32_t hookMask;     // AETHER_HOOK_* actually installed
    uint32_t pid;
    uint32_t queued;       // packets currently held in the TX queue
    uint32_t isTarget;     // 1 when the gate matched this process
    uint64_t tcpRX, udpRX;
    uint64_t tcpTX, udpTX;
    uint64_t bytesRX, bytesTX;
    uint64_t held;         // held right now (not cumulative)
    uint64_t dropped;      // cumulative
} AetherIpcTelemetry;

#endif /* AetherNetIPC_h */