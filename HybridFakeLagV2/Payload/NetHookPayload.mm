//
//  NetHookPayload.mm
//  libNetHookPayload.dylib — runs INSIDE the target process.
//
//  What changed (and why the old build captured exactly zero packets):
//
//   1. CONFIG CHANNEL. The old loader read AetherGetSharedState(); inside a
//      sandboxed app that call silently maps the TARGET'S OWN TMPDIR file,
//      whose magic matches, so the loader declared itself configured with
//      gActive=false and returned before ever trying the JSON mirrors.
//      Fixed: the shm dependency is gone entirely (it was also an undefined
//      symbol in the dylib, so dlopen failed before the ctor even ran). The
//      payload is now the server of a UNIX socket in its own TMPDIR and the
//      root app is the client — see headers/AetherNetIPC.h.
//
//   2. HOOK ENGINE. fishhook rebinds __la/__nl_symbol_ptr. Every image on
//      arm64e iOS 15-17 is dyld4 + chained fixups: no LC_DYSYMTAB, no indirect
//      symbol table, so fishhook returns early for EVERY image and orig_* stay
//      NULL. When Substrate/ellekit is present (any jailbreak that injects us)
//      MSHookFunction is the engine that actually patches __TEXT,__stubs on
//      arm64e, so we use it first and report which of the 6 symbols really got
//      hooked. fishhook stays only as a fallback for dyld3-era processes.
//
//   3. TARGET GATE. ellekit injects this dylib into every UIKit process, and
//      remote dlopen can land in anything. Without a gate we would hook the
//      whole device. shouldIntercept() now requires a config from the app whose
//      pid or bundle-id hash matches THIS process.
//
//   4. NO SILENT FAILURE. Everything the app displays (hooks landed, packets
//      seen, held, dropped) is reported back over the socket in
//      AetherIpcTelemetry, including status=AETHER_IPC_ST_NO_ENGINE when no
//      hook engine exists — instead of quietly passing packets through.
//
//   5. HOLD SAFETY. TX queue bounded by count AND bytes, dups the fd (the
//      original could flush a payload into a socket the app had closed and the
//      kernel had recycled), auto-flush driven by the IPC thread so an idle
//      target still releases, and RX hold blocks a blocking socket in poll()
//      instead of burning the caller's thread on a 20 ms EWOULDBLOCK spin.
//
//  ponytail: hooked at the BSD socket API, so traffic that never crosses the
//  target's own stubs (NSURLSession/CFNetwork traffic implemented inside
//  libnetwork, which lives in the read-only shared cache) is NOT visible here.
//  That layer is only reachable through the PacketTunnelProvider. Add an
//  nw_connection/nw_tcp_connection hook if that traffic ever has to be covered.
//
#ifdef HYBRID_PAYLOAD_BUILD

#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <time.h>
#include <atomic>
#include <vector>
#include <deque>
#include <algorithm>
#include <stdlib.h>
#include <stdarg.h>

#include <dlfcn.h>
#import <Foundation/Foundation.h>

#include "fishhook.h"
#include "../headers/AetherNetIPC.h"

// ── Original function pointers ───────────────────────────────────────────────
static ssize_t (*orig_send)(int, const void *, size_t, int) = NULL;
static ssize_t (*orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t) = NULL;
static ssize_t (*orig_sendmsg)(int, const struct msghdr *, int) = NULL;
static ssize_t (*orig_recv)(int, void *, size_t, int) = NULL;
static ssize_t (*orig_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *) = NULL;
static ssize_t (*orig_recvmsg)(int, struct msghdr *, int) = NULL;

// ── Config (atomics: read on every packet, written only from the IPC thread) ─
static std::atomic<uint32_t> gHaveConfig{0};
static std::atomic<int32_t>  gTargetPid{0};
static std::atomic<uint32_t> gBundleHash{0};
static std::atomic<uint32_t> gEnabled{0};
static std::atomic<uint32_t> gDirection{0};
static std::atomic<uint32_t> gProto{0};
static std::atomic<uint32_t> gMode{0};
static std::atomic<uint32_t> gRatio{100};
static std::atomic<uint32_t> gLatencyMs{0};
static std::atomic<uint32_t> gJitterMs{0};
static std::atomic<uint32_t> gAutoFlushSec{12};
static std::atomic<uint32_t> gSeq{0};

static std::atomic<uint32_t> gHookMask{0};
static std::atomic<uint32_t> gStatus{AETHER_IPC_ST_LISTENING};
static std::atomic<uint64_t> gHoldStartMs{0};

// ── Telemetry ───────────────────────────────────────────────────────────────
static std::atomic<uint64_t> gTcpRX{0}, gUdpRX{0}, gTcpTX{0}, gUdpTX{0};
static std::atomic<uint64_t> gBytesRX{0}, gBytesTX{0}, gDropped{0};
static std::atomic<uint64_t> gHeldNow{0};

// ── TX hold queue ───────────────────────────────────────────────────────────
struct HeldTx {
    int fd;                    // dup()'d — never the caller's raw descriptor
    std::vector<uint8_t> data;
    int flags;
    bool hasAddr;
    struct sockaddr_storage addr;
    socklen_t addrLen;
};
static pthread_mutex_t gQueueLock = PTHREAD_MUTEX_INITIALIZER;
static std::deque<HeldTx> gQueue;
static uint64_t gQueueBytes = 0;
static const size_t kMaxQueueEntries = 512;
static const size_t kMaxQueueBytes   = 2 * 1024 * 1024;

static inline uint64_t nowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000ULL);
}

static void plog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void plog(const char *fmt, ...) {
    static int fd = -2;
    if (fd == -2) {
        const char *tmp = getenv("TMPDIR");
        char path[512];
        snprintf(path, sizeof(path), "%s/aether_net_%d.log",
                 (tmp && *tmp) ? tmp : "/tmp", getpid());
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    }
    if (fd < 0) return;
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) { ssize_t w = write(fd, buf, (size_t)n); (void)w; }
}

// ── fd → protocol cache (lock-free; 2 syscalls per packet is a real stall) ───
enum { kProtoUnknown = 0, kProtoTCP = 1, kProtoUDP = 2, kProtoOther = 3 };
static std::atomic<uint32_t> gFdCache[256];

static uint8_t protoOfFd(int fd) {
    uint32_t slot = (uint32_t)(fd + 1) << 8;
    uint32_t idx = (uint32_t)fd & 0xFFu;
    uint32_t cached = gFdCache[idx].load(std::memory_order_relaxed);
    if ((cached & 0xFFFFFF00u) == slot) {
        uint8_t p = (uint8_t)(cached & 0xFFu);
        return p == kProtoUnknown ? kProtoOther : p;
    }

    uint8_t proto = kProtoOther;
    int type = 0;
    socklen_t tl = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl) != 0) return kProtoOther;

    // Local IPC / Mach sockets must pass straight through or the target's UI dies.
    struct sockaddr_storage ss;
    socklen_t sl = sizeof(ss);
    if (getsockname(fd, (struct sockaddr *)&ss, &sl) != 0) return kProtoOther;
    if (ss.ss_family != AF_INET && ss.ss_family != AF_INET6) return kProtoOther;

    if (type == SOCK_STREAM) proto = kProtoTCP;
    else if (type == SOCK_DGRAM) proto = kProtoUDP;

    uint32_t want = slot | proto;
    uint32_t prev = gFdCache[idx].load(std::memory_order_relaxed);
    while (prev != want &&
           !gFdCache[idx].compare_exchange_weak(prev, want, std::memory_order_relaxed)) {}
    return proto;
}

// ── Target gate ─────────────────────────────────────────────────────────────
static uint32_t ownBundleHash(void) {
    static uint32_t cached = 0;
    if (cached == 0) {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        cached = bid ? AetherBundleHash(bid.UTF8String) : 0;
    }
    return cached;
}

static bool isTarget(void) {
    if (gHaveConfig.load(std::memory_order_acquire) == 0) return false;
    int32_t pid = gTargetPid.load(std::memory_order_relaxed);
    if (pid > 0 && pid == getpid()) return true;
    uint32_t want = gBundleHash.load(std::memory_order_relaxed);
    return want != 0 && want == ownBundleHash();
}

static bool ratioPasses(void) {
    uint32_t r = gRatio.load(std::memory_order_relaxed);
    if (r >= 100) return true;
    if (r == 0) return false;
    return arc4random_uniform(100) < (uint32_t)r;
}

static bool shouldIntercept(bool isUpload, uint8_t proto) {
    if (proto != kProtoTCP && proto != kProtoUDP) return false;
    if (!gEnabled.load(std::memory_order_relaxed)) return false;
    if (!isTarget()) return false;

    uint32_t dir = gDirection.load(std::memory_order_relaxed);
    if (dir == 1 && isUpload) return false;
    if (dir == 2 && !isUpload) return false;

    uint32_t pf = gProto.load(std::memory_order_relaxed);
    if (pf == 1 && proto != kProtoUDP) return false;
    if (pf == 2 && proto != kProtoTCP) return false;

    return ratioPasses();
}

// ── Hold window ─────────────────────────────────────────────────────────────
// A hold is one window: it opens with the first intercepted packet and closes
// on disable / mode change / auto-flush. Counting packets instead (the old
// code) never terminated and pinned heldPacketsCount forever.
static bool holdActive(void) {
    if (!gEnabled.load(std::memory_order_relaxed)) return false;
    if (gMode.load(std::memory_order_relaxed) != 0) return false;
    uint64_t start = gHoldStartMs.load(std::memory_order_relaxed);
    if (start == 0) return false;
    uint32_t secs = gAutoFlushSec.load(std::memory_order_relaxed);
    if (secs == 0) return true;
    return nowMs() - start < (uint64_t)secs * 1000ULL;
}

static void openHoldWindow(void) {
    uint64_t expected = 0;
    gHoldStartMs.compare_exchange_strong(expected, nowMs(), std::memory_order_relaxed);
}

static void closeHoldWindow(void) {
    gHoldStartMs.store(0, std::memory_order_relaxed);
}

static void flushQueue(void) {
    std::deque<HeldTx> out;
    pthread_mutex_lock(&gQueueLock);
    out.swap(gQueue);
    gQueueBytes = 0;
    pthread_mutex_unlock(&gQueueLock);

    for (size_t i = 0; i < out.size(); i++) {
        HeldTx &p = out[i];
        if (p.hasAddr && orig_sendto) {
            orig_sendto(p.fd, p.data.data(), p.data.size(), p.flags,
                        (const struct sockaddr *)&p.addr, p.addrLen);
        } else if (orig_send) {
            orig_send(p.fd, p.data.data(), p.data.size(), p.flags);
        }
        close(p.fd);   // our dup, not the app's descriptor
    }
    gHeldNow.store(0, std::memory_order_relaxed);
}

static void releaseHold(void) {
    closeHoldWindow();
    flushQueue();
}

// ── Hooks ───────────────────────────────────────────────────────────────────
static void countTx(uint8_t proto, size_t bytes) {
    if (proto == kProtoTCP) gTcpTX.fetch_add(1, std::memory_order_relaxed);
    else gUdpTX.fetch_add(1, std::memory_order_relaxed);
    gBytesTX.fetch_add(bytes, std::memory_order_relaxed);
}

static void applyDelay(size_t bytes) {
    uint32_t lat = gLatencyMs.load(std::memory_order_relaxed);
    uint32_t jit = gJitterMs.load(std::memory_order_relaxed);
    if (jit > 0) lat += (uint32_t)(arc4random_uniform(jit) + jit) / 2;
    if (lat > 0) usleep((useconds_t)lat * 1000);
}

static ssize_t hooked_sendto(int fd, const void *buf, size_t len, int flags,
                             const struct sockaddr *dest, socklen_t addrlen) {
    if (!orig_sendto) return -1;
    uint8_t proto = protoOfFd(fd);
    if (proto != kProtoTCP && proto != kProtoUDP) return orig_sendto(fd, buf, len, flags, dest, addrlen);

    countTx(proto, len);
    if (!shouldIntercept(true, proto)) return orig_sendto(fd, buf, len, flags, dest, addrlen);

    uint32_t mode = gMode.load(std::memory_order_relaxed);
    if (mode == 0) {                       // hold
        openHoldWindow();
        bool queued = false;
        pthread_mutex_lock(&gQueueLock);
        if (gQueue.size() < kMaxQueueEntries && gQueueBytes + len <= kMaxQueueBytes) {
            HeldTx h;
            h.fd = dup(fd);
            h.data.assign((const uint8_t *)buf, (const uint8_t *)buf + len);
            h.flags = flags;
            h.hasAddr = (dest != NULL && addrlen > 0);
            h.addrLen = h.hasAddr ? addrlen : 0;
            if (h.hasAddr) memcpy(&h.addr, dest, std::min(sizeof(h.addr), (size_t)addrlen));
            if (h.fd >= 0) { gQueueBytes += len; gQueue.push_back(std::move(h)); queued = true; }
        }
        size_t n = gQueue.size();
        pthread_mutex_unlock(&gQueueLock);
        gHeldNow.store(n, std::memory_order_relaxed);
        if (!queued) gDropped.fetch_add(1, std::memory_order_relaxed);
        return (ssize_t)len;
    }
    if (mode == 1) {                       // drop
        gDropped.fetch_add(1, std::memory_order_relaxed);
        return (ssize_t)len;
    }
    if (mode == 2) applyDelay(len);        // delay + jitter
    return orig_sendto(fd, buf, len, flags, dest, addrlen);
}

static ssize_t hooked_send(int fd, const void *b, size_t l, int f) {
    return hooked_sendto(fd, b, l, f, NULL, 0);
}

static ssize_t hooked_sendmsg(int fd, const struct msghdr *msg, int flags) {
    if (!orig_sendmsg) return -1;
    size_t total = 0;
    for (size_t i = 0; i < msg->msg_iovlen; i++) total += msg->msg_iov[i].iov_len;
    uint8_t proto = protoOfFd(fd);
    if (proto != kProtoTCP && proto != kProtoUDP) return orig_sendmsg(fd, msg, flags);

    countTx(proto, total);
    if (!shouldIntercept(true, proto)) return orig_sendmsg(fd, msg, flags);

    uint32_t mode = gMode.load(std::memory_order_relaxed);
    if (mode == 0) {                       // gather-and-hold for scatter/gather
        openHoldWindow();
        bool queued = false;
        pthread_mutex_lock(&gQueueLock);
        if (gQueue.size() < kMaxQueueEntries && gQueueBytes + total <= kMaxQueueBytes) {
            HeldTx h;
            h.fd = dup(fd);
            h.data.reserve(total);
            for (size_t i = 0; i < msg->msg_iovlen; i++) {
                const uint8_t *p = (const uint8_t *)msg->msg_iov[i].iov_base;
                h.data.insert(h.data.end(), p, p + msg->msg_iov[i].iov_len);
            }
            h.flags = flags;
            h.hasAddr = false;
            h.addrLen = 0;
            if (h.fd >= 0) { gQueueBytes += total; gQueue.push_back(std::move(h)); queued = true; }
        }
        size_t n = gQueue.size();
        pthread_mutex_unlock(&gQueueLock);
        gHeldNow.store(n, std::memory_order_relaxed);
        if (!queued) gDropped.fetch_add(1, std::memory_order_relaxed);
        return (ssize_t)total;
    }
    if (mode == 1) { gDropped.fetch_add(1, std::memory_order_relaxed); return (ssize_t)total; }
    if (mode == 2) applyDelay(total);
    return orig_sendmsg(fd, msg, flags);
}

// A blocking socket is held the way a caller expects — parked in poll() and
// woken on release. A non-blocking one gets a real EWOULDBLOCK. The old code
// slept 20 ms and returned EWOULDBLOCK for both, which starved a blocking
// caller in a spin and burned a core.
static ssize_t heldRecvfrom(int fd, void *buf, size_t len, int flags) {
    (void)buf; (void)len; (void)flags;
    int fl = fcntl(fd, F_GETFL);
    bool nonBlocking = (fl >= 0) && (fl & O_NONBLOCK);
    if (!nonBlocking) {
        while (holdActive()) {
            struct pollfd pfd = { fd, POLLIN, 0 };
            poll(&pfd, 1, 100);
        }
    }
    errno = EWOULDBLOCK;
    return -1;
}

static ssize_t hooked_recvfrom(int fd, void *buf, size_t len, int flags,
                               struct sockaddr *src, socklen_t *addrlen) {
    if (!orig_recvfrom) return -1;
    uint8_t proto = protoOfFd(fd);
    if (proto != kProtoTCP && proto != kProtoUDP) return orig_recvfrom(fd, buf, len, flags, src, addrlen);

    if (shouldIntercept(false, proto)) {
        uint32_t mode = gMode.load(std::memory_order_relaxed);
        if (mode == 0) {
            openHoldWindow();
            gHeldNow.store(1, std::memory_order_relaxed);
            return heldRecvfrom(fd, buf, len, flags);
        }
        if (mode == 1) {                       // drop: consume, never deliver
            ssize_t r = orig_recvfrom(fd, buf, len, flags, src, addrlen);
            if (r > 0) gDropped.fetch_add(1, std::memory_order_relaxed);
            errno = EAGAIN;
            return -1;
        }
        if (mode == 2) applyDelay(len);
    }

    ssize_t r = orig_recvfrom(fd, buf, len, flags, src, addrlen);
    if (r > 0) {
        if (proto == kProtoTCP) gTcpRX.fetch_add(1, std::memory_order_relaxed);
        else gUdpRX.fetch_add(1, std::memory_order_relaxed);
        gBytesRX.fetch_add((uint64_t)r, std::memory_order_relaxed);
    }
    return r;
}

static ssize_t hooked_recv(int fd, void *b, size_t l, int f) {
    return hooked_recvfrom(fd, b, l, f, NULL, NULL);
}

static ssize_t hooked_recvmsg(int fd, struct msghdr *msg, int flags) {
    if (!orig_recvmsg) return -1;
    uint8_t proto = protoOfFd(fd);
    if (proto != kProtoTCP && proto != kProtoUDP) return orig_recvmsg(fd, msg, flags);

    if (shouldIntercept(false, proto)) {
        uint32_t mode = gMode.load(std::memory_order_relaxed);
        if (mode == 0) {
            openHoldWindow();
            gHeldNow.store(1, std::memory_order_relaxed);
            return heldRecvfrom(fd, NULL, 0, flags);
        }
        if (mode == 1) {
            ssize_t r = orig_recvmsg(fd, msg, flags);
            if (r > 0) gDropped.fetch_add(1, std::memory_order_relaxed);
            errno = EAGAIN;
            return -1;
        }
        if (mode == 2) applyDelay(0);
    }

    ssize_t r = orig_recvmsg(fd, msg, flags);
    if (r > 0) {
        if (proto == kProtoTCP) gTcpRX.fetch_add(1, std::memory_order_relaxed);
        else gUdpRX.fetch_add(1, std::memory_order_relaxed);
        gBytesRX.fetch_add((uint64_t)r, std::memory_order_relaxed);
    }
    return r;
}

// ── Hook installation ────────────────────────────────────────────────────────
typedef void (*MSHookFunction_t)(void *, void *, void **);

static uint32_t installHooks(void) {
    struct HookSpec {
        const char *name;
        void *replacement;
        void **original;
        uint32_t bit;
    } specs[] = {
        { "send",     (void *)hooked_send,     (void **)&orig_send,     AETHER_HOOK_SEND },
        { "sendto",   (void *)hooked_sendto,   (void **)&orig_sendto,   AETHER_HOOK_SENDTO },
        { "sendmsg",  (void *)hooked_sendmsg,  (void **)&orig_sendmsg,  AETHER_HOOK_SENDMSG },
        { "recv",     (void *)hooked_recv,     (void **)&orig_recv,     AETHER_HOOK_RECV },
        { "recvfrom", (void *)hooked_recvfrom, (void **)&orig_recvfrom, AETHER_HOOK_RECVFROM },
        { "recvmsg",  (void *)hooked_recvmsg,  (void **)&orig_recvmsg,  AETHER_HOOK_RECVMSG },
    };
    const size_t n = sizeof(specs) / sizeof(specs[0]);

    // Resolve every address BEFORE hooking anything, so dlsym can never
    // hand us one of our own replacements back.
    void *targets[6];
    for (size_t i = 0; i < n; i++) targets[i] = dlsym(RTLD_DEFAULT, specs[i].name);

    MSHookFunction_t msHook = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    uint32_t mask = 0;

    if (msHook) {
        // Substrate / ellekit: the only engine that understands arm64e stubs.
        for (size_t i = 0; i < n; i++) {
            if (!targets[i]) continue;
            msHook(targets[i], specs[i].replacement, specs[i].original);
            if (*specs[i].original) mask |= specs[i].bit;
        }
        plog("[payload] MSHookFunction engine mask=0x%x\n", mask);
        return mask;
    }

    // dyld3-era fallback. On chained-fixups images this installs nothing, so
    // the mask stays 0 and the app is told AETHER_IPC_ST_NO_ENGINE.
    struct rebinding rbs[6];
    size_t m = 0;
    for (size_t i = 0; i < n; i++) {
        rbs[m].name = specs[i].name;
        rbs[m].replacement = specs[i].replacement;
        rbs[m].replaced = specs[i].original;
        m++;
    }
    rebind_symbols(rbs, (uint32_t)m);
    for (size_t i = 0; i < n; i++) if (*specs[i].original) mask |= specs[i].bit;
    plog("[payload] fishhook fallback mask=0x%x\n", mask);
    return mask;
}

// ── IPC server ──────────────────────────────────────────────────────────────
static void applyConfig(const AetherIpcConfig *c) {
    uint32_t seq = c->seq;
    uint32_t prevSeq = gSeq.exchange(seq, std::memory_order_acq_rel);
    bool windowClosing = (prevSeq != seq) &&
                        (gMode.load(std::memory_order_relaxed) != c->mode ||
                         !c->enabled);

    gTargetPid.store(c->targetPID, std::memory_order_relaxed);
    gBundleHash.store(c->bundleHash, std::memory_order_relaxed);
    gDirection.store(c->direction, std::memory_order_relaxed);
    gProto.store(c->protocolFilter, std::memory_order_relaxed);
    gMode.store(c->mode, std::memory_order_relaxed);
    gRatio.store(c->captureRatio > 100 ? 100 : c->captureRatio, std::memory_order_relaxed);
    gLatencyMs.store(c->latencyMs, std::memory_order_relaxed);
    gJitterMs.store(c->jitterMs, std::memory_order_relaxed);
    gAutoFlushSec.store(c->autoFlushSeconds, std::memory_order_relaxed);
    gEnabled.store(c->enabled, std::memory_order_relaxed);
    gHaveConfig.store(1, std::memory_order_release);

    if (windowClosing) releaseHold();
    gStatus.store(isTarget() ? AETHER_IPC_ST_HOOKED : AETHER_IPC_ST_GATED,
                  std::memory_order_relaxed);
}

static AetherIpcTelemetry buildTelemetry(void) {
    AetherIpcTelemetry t;
    memset(&t, 0, sizeof(t));
    t.magic = AETHER_IPC_MAGIC;
    t.version = AETHER_IPC_VERSION;
    t.seq = gSeq.load(std::memory_order_relaxed);
    t.hookMask = gHookMask.load(std::memory_order_relaxed);
    t.status = gStatus.load(std::memory_order_relaxed);
    t.pid = (uint32_t)getpid();
    t.queued = (uint32_t)gQueue.size();
    t.isTarget = isTarget() ? 1u : 0u;
    t.tcpRX = gTcpRX.load(std::memory_order_relaxed);
    t.udpRX = gUdpRX.load(std::memory_order_relaxed);
    t.tcpTX = gTcpTX.load(std::memory_order_relaxed);
    t.udpTX = gUdpTX.load(std::memory_order_relaxed);
    t.bytesRX = gBytesRX.load(std::memory_order_relaxed);
    t.bytesTX = gBytesTX.load(std::memory_order_relaxed);
    t.held = gHeldNow.load(std::memory_order_relaxed);
    t.dropped = gDropped.load(std::memory_order_relaxed);
    return t;
}

static void *ipcServerThread(void *arg) {
    (void)arg;
    char path[512];
    const char *tmp = getenv("TMPDIR");
    snprintf(path, sizeof(path), "%s/" AETHER_IPC_SOCK_NAME,
             (tmp && *tmp) ? tmp : "/tmp", getpid());
    plog("[payload] ipc socket %s\n", path);

    if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        plog("[payload] TMPDIR too long for AF_UNIX: %s\n", path);
        return NULL;
    }

    // Resolve + cache the bundle hash before the loop: it touches NSBundle and
    // must not run autoreleased on this thread forever.
    { @autoreleasepool { ownBundleHash(); } }

    int listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listenFd < 0) { gStatus.store(AETHER_IPC_ST_NO_ENGINE); return NULL; }
    unlink(path);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, path, sizeof(addr.sun_path));
    // 0666: the root app connects as another uid.
    if (bind(listenFd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(listenFd, 2) != 0) {
        plog("[payload] bind/listen failed errno=%d\n", errno);
        close(listenFd);
        return NULL;
    }
    chmod(path, 0666);
    gStatus.store(AETHER_IPC_ST_LISTENING, std::memory_order_relaxed);

    int clientFd = -1;
    uint64_t lastTick = 0;
    for (;;) {
        if (clientFd < 0) {
            struct pollfd pfd = { listenFd, POLLIN, 0 };
            if (poll(&pfd, 1, 250) > 0 && (pfd.revents & POLLIN)) {
                clientFd = accept(listenFd, NULL, NULL);
                if (clientFd >= 0) plog("[payload] app connected\n");
            }
            continue;
        }

        struct pollfd pfd = { clientFd, POLLIN, 0 };
        int pr = poll(&pfd, 1, 250);
        if (pr > 0 && (pfd.revents & (POLLIN | POLLHUP | POLLERR))) {
            if (pfd.revents & POLLIN) {
                AetherIpcConfig c;
                ssize_t got = recv(clientFd, &c, sizeof(c), 0);
                if (got == (ssize_t)sizeof(c) && c.magic == AETHER_IPC_MAGIC &&
                    c.version == AETHER_IPC_VERSION) {
                    applyConfig(&c);
                } else if (got <= 0) {
                    close(clientFd);
                    clientFd = -1;
                    plog("[payload] app disconnected\n");
                }
            } else {
                close(clientFd);
                clientFd = -1;
            }
        } else if (pr < 0 && errno != EINTR) {
            close(clientFd);
            clientFd = -1;
        }

        if (nowMs() - lastTick >= 250) {
            lastTick = nowMs();
            // Auto-flush here, not inside a socket call: an idle target must
            // still release, otherwise it stays wedged until iOS kills it.
            if (holdActive() == false && gHeldNow.load(std::memory_order_relaxed) > 0) {
                releaseHold();
            }
            AetherIpcTelemetry t = buildTelemetry();
            ssize_t w = send(clientFd, &t, sizeof(t), MSG_NOSIGNAL);
            if (w < 0 && (errno == EPIPE || errno == ECONNRESET)) {
                close(clientFd);
                clientFd = -1;
            }
        }
    }
    return NULL;
}

__attribute__((constructor))
static void aetherPayloadInit(void) {
    gStatus.store(AETHER_IPC_ST_LISTENING, std::memory_order_relaxed);

    uint32_t mask = installHooks();
    gHookMask.store(mask, std::memory_order_relaxed);
    if (mask == 0) {
        // Refuse to pretend: no engine means the process runs untouched and the
        // app is told so, instead of showing a live capture UI over zero hooks.
        gStatus.store(AETHER_IPC_ST_NO_ENGINE, std::memory_order_relaxed);
    } else {
        gStatus.store(AETHER_IPC_ST_HOOKED, std::memory_order_relaxed);
    }

    pthread_t th;
    pthread_create(&th, NULL, ipcServerThread, NULL);
    pthread_detach(th);

    plog("[payload] armed pid=%d mask=0x%x bundle=0x%x\n",
         getpid(), mask, ownBundleHash());
}

#else
// Host-app build: intentionally empty (the payload must only ever run inside
// the injected TARGET process, never inside our own app).
#endif /* HYBRID_PAYLOAD_BUILD */