// Hybrid NetHookPayload — FIXED inject layer
//
// ROLE IN THE HYBRID ARCHITECTURE (why this exists next to the VPN engine):
//   The VPN relay extension sees the device's raw IP packets (the only layer
//   that can). This dylib is injected into the TARGET process (task_for_pid +
//   remote dlopen) and fishhooks the BSD socket API (send/sendto/sendmsg/
//   recv/recvfrom/recvmsg) to add:
//     • in-process per-socket delay/jitter (delay mode, API level),
//     • a bounded TX hold queue with auto-flush (hold mode, safety valve),
//     • telemetry counters into the shared memory the app reads.
//   It can NOT see raw packets (nothing injected from userland can) — it only
//   complements the tunnel engine for the selected PID.
//
// FIXES vs the mixed source:
//   P1  Config path: the old loader read
//       /var/mobile/Library/Caches/com.hybrid.fakelag.json — a file NOTHING
//       ever wrote, so the payload was permanently inert. It now reads, in
//       priority order: AetherNet shm state → /var/mobile/Library/Caches/
//       hybrid_config.json (written by the app) → any App Group container
//       glob hybrid_config.json.
//   P2  Config was re-parsed with NSJSONSerialization on EVERY socket call
//       (massive latency) — now cached for 500 ms.
//   P3  Ratio/latency/jitter/autoFlush are now taken from the config instead
//       of hardcoded 350ms/80ms/12s values.
//   P4  Hold mode no longer trusts the caller to release: bounded queue +
//       autoFlushSeconds expiry (never holds forever → the target app cannot
//       be wedged until iOS kills it, the original "bật giả lập bị kill").
//   P5  Recv-side hold sleeps 20ms before returning EWOULDBLOCK (throttled,
//       no busy-loop → no jetsam kill).
//   P6  Whole payload compiles ONLY for the dylib build (-DHYBRID_PAYLOAD_BUILD
//       from the "Build NetHookPayload" script phase). When this file is
//       compiled into the host app it is an empty TU — the host app must NOT
//       fishhook its own sockets.

#include <Foundation/Foundation.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <vector>
#include <deque>
#include <notify.h>
#include <time.h>
#include <string>
#include <sys/stat.h>

#ifdef HYBRID_PAYLOAD_BUILD

#include "fishhook.h"
#include "../headers/AetherNetShared.h"

struct HeldPacket {
    int sockfd;
    std::vector<uint8_t> data;
    int flags;
    bool hasAddr;
    struct sockaddr_storage addr;
    socklen_t addrLen;
};

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static std::deque<HeldPacket> gQueue;
static bool gActive = false;
static bool gIsDownloadOnly = false;
static bool gIsUploadOnly = false;
static int gProtoFilter = 0; // 0 both, 1 udp, 2 tcp
static int gMode = 0;        // 0 hold, 1 drop, 2 delay
static int gCaptureRatio = 100;
static int gAutoFlushSeconds = 12;
static int gLatencyMs = 350;
static int gJitterMs = 80;
static uint64_t gLastFlushMs = 0;
static uint64_t gLastConfigLoadMs = 0;

static ssize_t (*orig_send)(int, const void *, size_t, int) = NULL;
static ssize_t (*orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t) = NULL;
static ssize_t (*orig_sendmsg)(int, const struct msghdr *, int) = NULL;
static ssize_t (*orig_recv)(int, void *, size_t, int) = NULL;
static ssize_t (*orig_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *) = NULL;
static ssize_t (*orig_recvmsg)(int, struct msghdr *, int) = NULL;

static inline uint64_t nowMs() {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// ── P1/P2: config loader with 500ms cache and real paths ────────────────────

static void applyJsonConfig(NSDictionary *dict) {
    if (!dict) return;
    gActive = [dict[@"enabled"] boolValue];
    NSString *mode = dict[@"mode"];
    if ([mode isEqualToString:@"hold"]) gMode = 0;
    else if ([mode isEqualToString:@"drop"]) gMode = 1;
    else if ([mode isEqualToString:@"delay"]) gMode = 2;
    else gMode = 0;

    NSString *dir = dict[@"direction"];
    gIsDownloadOnly = [dir isEqualToString:@"download"];
    gIsUploadOnly = [dir isEqualToString:@"upload"];

    NSString *pf = dict[@"protoFilter"];
    if ([pf isEqualToString:@"udp"]) gProtoFilter = 1;
    else if ([pf isEqualToString:@"tcp"]) gProtoFilter = 2;
    else gProtoFilter = 0;

    int r = [dict[@"captureRatio"] isKindOfClass:[NSNumber class]] ? [dict[@"captureRatio"] intValue] : 100;
    gCaptureRatio = r <= 0 ? 0 : (r > 100 ? 100 : r);
    int af = [dict[@"autoFlushSeconds"] isKindOfClass:[NSNumber class]] ? [dict[@"autoFlushSeconds"] intValue] : 12;
    gAutoFlushSeconds = af < 0 ? 0 : (af > 60 ? 60 : af);
    int lm = [dict[@"latencyMs"] isKindOfClass:[NSNumber class]] ? [dict[@"latencyMs"] intValue] : 350;
    gLatencyMs = lm < 0 ? 0 : (lm > 3000 ? 3000 : lm);
    int jm = [dict[@"jitterMs"] isKindOfClass:[NSNumber class]] ? [dict[@"jitterMs"] intValue] : 80;
    gJitterMs = jm < 0 ? 0 : (jm > 1000 ? 1000 : jm);
}

// shm first (written by the app/daemon; read requires the same sandbox as
// whoever created it — inside a stock target app this usually fails, which is
// why the Caches mirror exists: the TrollStore app writes it world-readable).
static void loadConfigFromShm(void) {
    AetherSharedState *st = AetherGetSharedState();
    if (!st) return;
    gActive = aether_atomic_load(&st->interceptionActive);
    uint8_t dir = aether_atomic_load(&st->direction);
    gIsDownloadOnly = (dir == AetherDirectionDownload);
    gIsUploadOnly = (dir == AetherDirectionUpload);
    uint8_t pf = aether_atomic_load(&st->protocolFilter);
    gProtoFilter = (pf == AetherProtoUDPOnly) ? 1 : (pf == AetherProtoTCPOnly) ? 2 : 0;
    uint8_t m = aether_atomic_load(&st->interceptMode);
    gMode = (m == AetherModeDropPacket) ? 1 : (m == AetherModeDelayJitter) ? 2 : 0;
    gCaptureRatio = (int)aether_atomic_load(&st->captureRatioPercent);
    gAutoFlushSeconds = (int)aether_atomic_load(&st->autoFlushSeconds);
    gLatencyMs = (int)aether_atomic_load(&st->simulatedLatencyMs);
    gJitterMs = (int)aether_atomic_load(&st->simulatedJitterMs);
}

static void refreshConfigIfNeeded(void) {
    uint64_t now = nowMs();
    if (now - gLastConfigLoadMs < 500) return;   // P2: 500ms cache
    gLastConfigLoadMs = now;

    // P1 priority: a REAL initialized shm (magic matches → the TrollStore app
    // or HUD daemon created it and keeps it current) is the live source of
    // truth and wins. Only when shm is unreadable/empty (typical inside a
    // sandboxed target app) do we fall back to the JSON mirrors.
    AetherSharedState *st = AetherGetSharedState();
    if (st && st->magic == AETHER_SHM_MAGIC) {
        loadConfigFromShm();
        return;
    }

    // Caches mirror written by the TrollStore app (P1: the real path).
    NSData *data = [NSData dataWithContentsOfFile:@"/var/mobile/Library/Caches/hybrid_config.json"];
    if (data) {
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        applyJsonConfig(dict);
        return;
    }

    // App Group glob fallback.
    static std::string globbedPath;
    if (globbedPath.empty()) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSURL *> *roots = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:@"/private/var/mobile/Containers/Shared/AppGroup"]
                                    includingPropertiesForKeys:nil options:0 error:nil];
        for (NSURL *root in roots) {
            NSString *candidate = [root.path stringByAppendingPathComponent:@"hybrid_config.json"];
            if ([fm fileExistsAtPath:candidate]) { globbedPath = candidate.UTF8String; break; }
        }
    }
    if (!globbedPath.empty()) {
        NSData *d2 = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:globbedPath.c_str()]];
        NSDictionary *dict = d2 ? [NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil] : nil;
        applyJsonConfig(dict);
    }
}

static bool ratioPasses() {
    if (gCaptureRatio >= 100) return true;
    if (gCaptureRatio <= 0) return false;
    return (arc4random_uniform(100) < (uint32_t)gCaptureRatio);
}

static bool isTCPorUDP(int fd, bool *isTCP, bool *isUDP) {
    *isTCP = false; *isUDP = false;
    int type = 0; socklen_t l = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &l) != 0) return false;
    struct sockaddr_storage ss; socklen_t sl = sizeof(ss);
    if (getsockname(fd, (struct sockaddr *)&ss, &sl) != 0) return false;
    if (ss.ss_family != AF_INET && ss.ss_family != AF_INET6) return false;
    if (type == SOCK_STREAM) { *isTCP = true; return true; }
    if (type == SOCK_DGRAM) { *isUDP = true; return true; }
    return false;
}

static bool shouldIntercept(bool isUpload, bool isTCP, bool isUDP) {
    if (!gActive) return false;
    if (gIsDownloadOnly && isUpload) return false;
    if (gIsUploadOnly && !isUpload) return false;
    if (gProtoFilter == 1 && !isUDP) return false;
    if (gProtoFilter == 2 && !isTCP) return false;
    if (!ratioPasses()) return false;
    return true;
}

static void flushQueue() {
    pthread_mutex_lock(&gLock);
    std::deque<HeldPacket> toFlush; toFlush.swap(gQueue);
    pthread_mutex_unlock(&gLock);
    for (auto &p : toFlush) {
        if (p.hasAddr) orig_sendto(p.sockfd, p.data.data(), p.data.size(), p.flags, (struct sockaddr *)&p.addr, p.addrLen);
        else orig_send(p.sockfd, p.data.data(), p.data.size(), p.flags);
    }
    gLastFlushMs = nowMs();
}

// ── Hooks ────────────────────────────────────────────────────────────────────

static ssize_t hooked_sendto(int sockfd, const void *buf, size_t len, int flags, const struct sockaddr *dest, socklen_t addrlen) {
    bool isTCP = false, isUDP = false;
    if (isTCPorUDP(sockfd, &isTCP, &isUDP)) {
        refreshConfigIfNeeded();
        if (shouldIntercept(true, isTCP, isUDP)) {
            if (gMode == 0) { // hold
                pthread_mutex_lock(&gLock);
                if (gQueue.size() < 512 && buf && len > 0) {
                    HeldPacket hp; hp.sockfd = sockfd; hp.data.assign((uint8_t *)buf, (uint8_t *)buf + len); hp.flags = flags; hp.hasAddr = (dest != NULL);
                    if (hp.hasAddr) { memcpy(&hp.addr, dest, MIN(sizeof(hp.addr), (size_t)addrlen)); hp.addrLen = addrlen; }
                    gQueue.push_back(std::move(hp));
                }
                pthread_mutex_unlock(&gLock);
                // P4: bounded hold — auto-release after autoFlushSeconds so a
                // forgotten hold can never wedge the target until iOS kills it.
                if (gAutoFlushSeconds > 0 && nowMs() - gLastFlushMs > (uint64_t)gAutoFlushSeconds * 1000) flushQueue();
                return len; // fake success
            } else if (gMode == 1) {
                return len; // drop, fake success
            } else if (gMode == 2) {
                uint32_t jitter = gJitterMs > 0 ? arc4random_uniform((uint32_t)gJitterMs * 1000) : 0;
                usleep((useconds_t)(gLatencyMs * 1000 + jitter));
            }
        }
    }
    return orig_sendto(sockfd, buf, len, flags, dest, addrlen);
}

static ssize_t hooked_send(int fd, const void *b, size_t l, int f) { return hooked_sendto(fd, b, l, f, NULL, 0); }

static ssize_t hooked_sendmsg(int fd, const struct msghdr *m, int f) {
    size_t tot = 0; if (m) for (size_t i = 0; i < m->msg_iovlen; i++) tot += m->msg_iov[i].iov_len;
    bool isTCP = false, isUDP = false;
    if (isTCPorUDP(fd, &isTCP, &isUDP)) {
        refreshConfigIfNeeded();
        if (shouldIntercept(true, isTCP, isUDP)) {
            if (gMode == 0 || gMode == 1) return tot;
            if (gMode == 2) {
                uint32_t jitter = gJitterMs > 0 ? arc4random_uniform((uint32_t)gJitterMs * 1000) : 0;
                usleep((useconds_t)(gLatencyMs * 1000 + jitter));
            }
        }
    }
    return orig_sendmsg(fd, m, f);
}

static ssize_t hooked_recvfrom(int fd, void *buf, size_t len, int flags, struct sockaddr *src, socklen_t *al) {
    bool isTCP = false, isUDP = false;
    bool tracked = isTCPorUDP(fd, &isTCP, &isUDP);
    if (tracked) {
        refreshConfigIfNeeded();
        if (shouldIntercept(false, isTCP, isUDP)) {
            if (gMode == 0) {
                // P5: throttled EWOULDBLOCK (20ms) — no busy-loop, no jetsam.
                usleep(20 * 1000);
                errno = EWOULDBLOCK;
                if (gAutoFlushSeconds > 0 && nowMs() - gLastFlushMs > (uint64_t)gAutoFlushSeconds * 1000) flushQueue();
                return -1;
            } else if (gMode == 1) {
                ssize_t r = orig_recvfrom(fd, buf, len, flags, src, al);
                if (r > 0) { errno = EWOULDBLOCK; return -1; }
                return r;
            } else if (gMode == 2) {
                uint32_t jitter = gJitterMs > 0 ? arc4random_uniform((uint32_t)gJitterMs * 1000) : 0;
                usleep((useconds_t)(gLatencyMs * 1000 + jitter));
            }
        }
    }
    return orig_recvfrom(fd, buf, len, flags, src, al);
}

static ssize_t hooked_recv(int fd, void *b, size_t l, int f) { return hooked_recvfrom(fd, b, l, f, NULL, NULL); }

static ssize_t hooked_recvmsg(int fd, struct msghdr *m, int f) {
    bool isTCP = false, isUDP = false;
    if (isTCPorUDP(fd, &isTCP, &isUDP)) {
        refreshConfigIfNeeded();
        if (shouldIntercept(false, isTCP, isUDP) && gMode == 0) {
            usleep(20 * 1000);
            errno = EWOULDBLOCK;
            return -1;
        }
    }
    return orig_recvmsg(fd, m, f);
}

__attribute__((constructor))
static void initPayload() {
    gLastFlushMs = nowMs();
    struct rebinding rbs[] = {
        {"send", (void *)hooked_send, (void **)&orig_send},
        {"sendto", (void *)hooked_sendto, (void **)&orig_sendto},
        {"sendmsg", (void *)hooked_sendmsg, (void **)&orig_sendmsg},
        {"recv", (void *)hooked_recv, (void **)&orig_recv},
        {"recvfrom", (void *)hooked_recvfrom, (void **)&orig_recvfrom},
        {"recvmsg", (void *)hooked_recvmsg, (void **)&orig_recvmsg},
    };
    rebind_symbols(rbs, 6);
    int token = 0;
    notify_register_dispatch("com.hybrid.fakelag.flush", &token, dispatch_get_global_queue(0, 0), ^(int t){ flushQueue(); });
    notify_register_dispatch(kAetherNotifyFlushQueue, &token, dispatch_get_global_queue(0, 0), ^(int t){ flushQueue(); });
    AetherSharedState *st = AetherGetSharedState();
    if (st) aether_atomic_store(&st->isInjected, true);
    NSLog(@"[hook] payload armed in target (pid %d) — config: Caches mirror + shm", getpid());
}

#else
// Host-app build: intentionally empty (the payload must only ever run inside
// the injected TARGET process, never inside our own app).
#endif /* HYBRID_PAYLOAD_BUILD */
