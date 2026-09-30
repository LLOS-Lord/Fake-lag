//
//  ProcessManager.mm
//  AetherNet — Process Enumeration, XNU Socket Telemetry & HUD Spawner
//

#import "ProcessManager.h"
#import "AetherLog.h"
#import "DopamineBridge.h"
#import "../headers/PrivateSystemSPI.h"
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <limits.h>
#include <errno.h>
#include <time.h>
#include <arpa/inet.h>
#include <spawn.h>
#include <notify.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <signal.h>

extern "C" char **environ;
extern "C" int AetherInjectDylibIntoPID(pid_t pid, const char *dylibPath, char *errBuf, size_t errBufLen);
extern "C" int AetherApplyRootTrafficControl(pid_t pid, AetherSharedState *state);

// Writes the {enabled,timestamp} override consumed by the VPN relay engine
// (PacketTunnelProvider). Called from BOTH the app (HybridHUDSetInterceptionActive)
// and the root HUD daemon (floating button tap) so the extension follows the
// simulation switch instantly, even with the app closed.
static void HybridWriteExtOverrideFiles(BOOL active) {
    NSDictionary *dict = @{@"enabled": @(active), @"timestamp": @(NSDate.date.timeIntervalSince1970)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!data) return;
    NSString *cachesPath = @"/var/mobile/Library/Caches/hybrid_ext_override.json";
    [data writeToFile:cachesPath atomically:YES];
    chmod(cachesPath.UTF8String, 0666);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSURL *> *roots = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:@"/var/mobile/Containers/Shared/AppGroup"]
                                includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *root in roots) {
        NSString *marker = [root.path stringByAppendingPathComponent:@"hybrid_config.json"];
        if ([fm fileExistsAtPath:marker]) {
            [data writeToFile:[root.path stringByAppendingPathComponent:@"hybrid_ext_override.json"] atomically:YES];
        }
    }
    notify_post("com.aethernet.interceptor.config_changed");
}

@implementation AetherProcessInfo
@end

@implementation AetherProcessManager {
    NSMutableDictionary<NSString *, LSApplicationProxy *> *_pathToAppProxyCache;
    NSTimer *_telemetryTimer;
}

+ (instancetype)sharedManager {
    static AetherProcessManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AetherProcessManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        _pathToAppProxyCache = [NSMutableDictionary dictionary];
        [self rebuildInstalledAppCache];
    }
    return self;
}

- (void)rebuildInstalledAppCache {
    [_pathToAppProxyCache removeAllObjects];
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    if (!wsClass) return;

    LSApplicationWorkspace *workspace = [wsClass defaultWorkspace];
    NSArray<LSApplicationProxy *> *apps = [workspace allInstalledApplications];
    for (LSApplicationProxy *proxy in apps) {
        NSString *bundlePath = proxy.bundleURL.path;
        if (bundlePath.length > 0) {
            _pathToAppProxyCache[bundlePath] = proxy;
        }
    }
}

- (NSArray<AetherProcessInfo *> *)enumerateRunningProcessesWithFilter:(nullable NSString *)searchQuery
                                                         onlyUserApps:(BOOL)onlyUserApps {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t bufSize = 0;

    if (sysctl(mib, 4, NULL, &bufSize, NULL, 0) < 0 || bufSize == 0) {
        return @[];
    }

    // Add slack for newly spawned processes
    bufSize += sizeof(struct kinfo_proc) * 32;
    struct kinfo_proc *procs = (struct kinfo_proc *)calloc(1, bufSize);
    if (!procs) return @[];

    if (sysctl(mib, 4, procs, &bufSize, NULL, 0) < 0) {
        free(procs);
        return @[];
    }

    size_t count = bufSize / sizeof(struct kinfo_proc);
    NSMutableArray<AetherProcessInfo *> *result = [NSMutableArray arrayWithCapacity:count];
    pid_t selfPID = getpid();

    for (size_t i = 0; i < count; i++) {
        struct kinfo_proc *kp = &procs[i];
        pid_t pid = kp->kp_proc.p_pid;
        if (pid <= 1 || pid == selfPID) continue;

        char pathBuf[PATH_MAX] = {0};
        proc_pidpath(pid, pathBuf, sizeof(pathBuf));
        NSString *execPath = pathBuf[0] ? [NSString stringWithUTF8String:pathBuf] : @"";
        NSString *commName = [NSString stringWithUTF8String:kp->kp_proc.p_comm];
        if (execPath.length > 0) {
            commName = [execPath lastPathComponent];
        }

        BOOL isAppBundle = [execPath containsString:@".app/"];
        BOOL isUserApp = [execPath hasPrefix:@"/var/containers/Bundle/Application/"] ||
                         [execPath hasPrefix:@"/private/var/containers/Bundle/Application/"];

        if (onlyUserApps && !isAppBundle) {
            continue;
        }

        AetherProcessInfo *info = [[AetherProcessInfo alloc] init];
        info.pid = pid;
        info.ppid = kp->kp_eproc.e_ppid;
        info.uid = kp->kp_eproc.e_ucred.cr_uid;
        info.processName = commName ?: @"unknown";
        info.displayName = info.processName;
        info.executablePath = execPath;
        info.isUserApp = isUserApp;
        info.bundleIdentifier = isUserApp ? @"com.user.application" : @"com.apple.system";

        // Match .app bundle path to LSApplicationProxy metadata + icon
        if (isAppBundle) {
            NSRange appRange = [execPath rangeOfString:@".app/"];
            if (appRange.location != NSNotFound) {
                NSString *bundleDir = [execPath substringToIndex:appRange.location + 4];
                LSApplicationProxy *proxy = _pathToAppProxyCache[bundleDir];
                if (proxy) {
                    if (proxy.localizedName.length > 0) info.displayName = proxy.localizedName;
                    if (proxy.applicationIdentifier.length > 0) info.bundleIdentifier = proxy.applicationIdentifier;
                } else {
                    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:
                        [bundleDir stringByAppendingPathComponent:@"Info.plist"]];
                    if (infoPlist[@"CFBundleDisplayName"]) {
                        info.displayName = infoPlist[@"CFBundleDisplayName"];
                    } else if (infoPlist[@"CFBundleName"]) {
                        info.displayName = infoPlist[@"CFBundleName"];
                    }
                    if (infoPlist[@"CFBundleIdentifier"]) {
                        info.bundleIdentifier = infoPlist[@"CFBundleIdentifier"];
                    }
                }

                if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
                    info.appIcon = [UIImage _applicationIconImageForBundleIdentifier:info.bundleIdentifier
                                                                              format:0
                                                                               scale:[UIScreen mainScreen].scale];
                }
            }
        }

        // Count active L4 TCP/UDP sockets for this PID
        uint32_t tcpCount = 0, udpCount = 0;
        [self countSocketsForPID:pid outTCP:&tcpCount outUDP:&udpCount];
        info.tcpSocketCount = tcpCount;
        info.udpSocketCount = udpCount;

        // Apply search query filter if non-empty
        if (searchQuery.length > 0) {
            NSString *q = [searchQuery lowercaseString];
            BOOL matchName = [[info.displayName lowercaseString] containsString:q] ||
                             [[info.processName lowercaseString] containsString:q] ||
                             [[info.bundleIdentifier lowercaseString] containsString:q] ||
                             [[NSString stringWithFormat:@"%d", info.pid] containsString:q];
            if (!matchName) continue;
        }

        [result addObject:info];
    }

    free(procs);

    // Sort: User apps first, then processes with active UDP/TCP sockets, then by displayName
    [result sortUsingComparator:^NSComparisonResult(AetherProcessInfo *a, AetherProcessInfo *b) {
        if (a.isUserApp != b.isUserApp) {
            return a.isUserApp ? NSOrderedAscending : NSOrderedDescending;
        }
        uint32_t aSockets = a.tcpSocketCount + a.udpSocketCount;
        uint32_t bSockets = b.tcpSocketCount + b.udpSocketCount;
        if (aSockets != bSockets) {
            return (aSockets > bSockets) ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
    }];

    return result;
}

- (void)countSocketsForPID:(pid_t)pid outTCP:(uint32_t *)outTCP outUDP:(uint32_t *)outUDP {
    uint32_t tcp = 0, udp = 0;
    int bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bufSize > 0) {
        struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc(bufSize);
        if (fds) {
            int actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bufSize);
            int fdCount = actual / sizeof(struct proc_fdinfo);
            for (int i = 0; i < fdCount; i++) {
                if (fds[i].proc_fdtype == PROX_FDTYPE_SOCKET) {
                    struct aether_socket_fdinfo sockInfo;
                    int rc = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &sockInfo, sizeof(sockInfo));
                    if (rc == sizeof(sockInfo)) {
                        int fam = sockInfo.psi.soi_family;
                        if (fam == AF_INET || fam == AF_INET6) {
                            if (sockInfo.psi.soi_type == SOCK_STREAM) tcp++;
                            else if (sockInfo.psi.soi_type == SOCK_DGRAM) udp++;
                        }
                    }
                }
            }
            free(fds);
        }
    }
    if (outTCP) *outTCP = tcp;
    if (outUDP) *outUDP = udp;
}

- (void)refreshSocketTelemetryForPID:(pid_t)pid {
    AetherSharedState *state = AetherGetSharedState();
    if (!state || pid <= 0) return;

    int bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bufSize <= 0) return;

    struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc(bufSize);
    if (!fds) return;

    int actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bufSize);
    int fdCount = actual / sizeof(struct proc_fdinfo);

    uint32_t tcpCount = 0;
    uint32_t udpCount = 0;
    uint32_t entryIdx = 0;

    for (int i = 0; i < fdCount; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;

        struct aether_socket_fdinfo sinfo;
        int rc = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &sinfo, sizeof(sinfo));
        if (rc != sizeof(sinfo)) continue;

        int family = sinfo.psi.soi_family;
        if (family != AF_INET && family != AF_INET6) continue;

        int sockType = sinfo.psi.soi_type;
        if (sockType == SOCK_STREAM) tcpCount++;
        else if (sockType == SOCK_DGRAM) udpCount++;
        else continue;

        if (entryIdx < AETHER_MAX_TRACKED_SOCKETS) {
            AetherSocketEntry *entry = &state->activeSockets[entryIdx++];
            memset(entry, 0, sizeof(AetherSocketEntry));
            entry->protocol = (sockType == SOCK_STREAM) ? IPPROTO_TCP : IPPROTO_UDP;

            struct in_sockinfo *ini = (sockType == SOCK_STREAM)
                ? &sinfo.psi.soi_proto.pri_tcp.tcpsi_ini
                : &sinfo.psi.soi_proto.pri_in;

            entry->localPort = ntohs((uint16_t)ini->insi_lport);
            entry->remotePort = ntohs((uint16_t)ini->insi_fport);
            entry->state = (sockType == SOCK_STREAM) ? (uint8_t)sinfo.psi.soi_proto.pri_tcp.tcpsi_state : 1;
            entry->rxBytes = sinfo.psi.soi_rcv.sbi_cc;
            entry->txBytes = sinfo.psi.soi_snd.sbi_cc;

            if (family == AF_INET) {
                inet_ntop(AF_INET, &ini->insi_faddr.ina_46, entry->remoteAddress, sizeof(entry->remoteAddress));
            } else {
                inet_ntop(AF_INET6, &ini->insi_faddr.ina_6, entry->remoteAddress, sizeof(entry->remoteAddress));
            }
        }
    }

    free(fds);

    aether_atomic_store(&state->activeTCPSockets, tcpCount);
    aether_atomic_store(&state->activeUDPSockets, udpCount);
    state->socketEntryCount = entryIdx;
}

- (BOOL)injectIntoProcess:(AetherProcessInfo *)processInfo
                    error:(NSError * _Nullable * _Nullable)error {
    AetherSharedState *state = AetherGetSharedState();
    if (!state) return NO;

    AetherResetTelemetryForNewTarget(
        state,
        processInfo.pid,
        [processInfo.displayName UTF8String],
        [processInfo.bundleIdentifier UTF8String],
        [processInfo.executablePath UTF8String]
    );

    // Stage 1: Copy bundled libNetHookPayload.dylib to accessible world-readable path
    NSString *bundledDylib = [[NSBundle mainBundle] pathForResource:@"libNetHookPayload" ofType:@"dylib"];
    if (bundledDylib) {
        [[NSFileManager defaultManager] copyItemAtPath:bundledDylib
                                                toPath:@AETHER_DYLIB_INSTALL_PATH
                                                 error:nil];
        chmod(AETHER_DYLIB_INSTALL_PATH, 0755);
    }

    // Stage 0: Dopamine 3.x PPL-Bypass Bridge (A12+/iOS 15-17.3.1 with Dopamine installed)
    //   - Trust libNetHookPayload.dylib in the kernel trust cache
    //   - cs_allow_invalid(target): CS_DEBUGGED + pmap/TXM allowsInvalidCode (Dopamine's PPL fix)
    //   This is what un-blocks unsigned dylib injection where PPL would normally kill it.
    BOOL dopamineAssisted = NO;
    if (AetherDopamineAvailable()) {
        dopamineAssisted = AetherDopaminePrepareInjection(processInfo.pid, AETHER_DYLIB_INSTALL_PATH);
    }

    // Stage 2: Attempt Mach Task Thread Injection (task_for_pid -> remote dlopen)
    char errBuf[256] = {0};
    int injectRC = AetherInjectDylibIntoPID(processInfo.pid, AETHER_DYLIB_INSTALL_PATH, errBuf, sizeof(errBuf));
    AetherLog(@"attach inject pid %d rc=%d dopamine=%d err=[%s]",
              processInfo.pid, injectRC, dopamineAssisted, errBuf);

    if (injectRC == 0) {
        aether_atomic_store(&state->isInjected, true);
        aether_atomic_store(&state->injectionMethod, dopamineAssisted ? 3 : 1); // Dopamine-assisted / plain Mach Dylib Hook
    } else {
        // Fallback Stage 3: Root Socket / Kernel PF + Dummynet per-PID Shaper
        // Works on all A12+ iOS 15.0 - 17.0 TrollStore devices even with PPL enabled
        AetherApplyRootTrafficControl(processInfo.pid, state);
        aether_atomic_store(&state->isInjected, true);
        aether_atomic_store(&state->injectionMethod, 2); // Root Kernel/Socket Engine
    }

    AetherLog(@"attach pid %d name=%s bundle=%s", processInfo.pid,
              processInfo.processName.UTF8String ?: "?",
              processInfo.bundleIdentifier.UTF8String ?: "?");
    [self refreshSocketTelemetryForPID:processInfo.pid];
    notify_post(kAetherNotifyStateChanged);
    return YES;
}

- (void)detachFromCurrentProcess {
    AetherSharedState *state = AetherGetSharedState();
    if (!state) return;

    aether_atomic_store(&state->interceptionActive, false);
    aether_atomic_store(&state->isInjected, false);
    aether_atomic_store(&state->targetPID, 0);
    notify_post(kAetherNotifyFlushQueue);
    notify_post(kAetherNotifyStateChanged);
}

#pragma mark - Global Root Floating HUD Button Management

- (BOOL)isGlobalFloatingHUDRunning {
    // Channel 1 (primary): shm heartbeat — HUD daemon stamps time(NULL) every 1s.
    // Works across uid/root and roothide path shadowing (no filesystem trust needed).
    AetherSharedState *state = AetherGetSharedState();
    if (state) {
        uint64_t hb = aether_atomic_load(&state->hudHeartbeatTs);
        if (hb > 0 && (uint64_t)time(NULL) - hb <= 3) return YES;
    }

    // Channel 2 (fallback): pid file + signal probe. App runs as uid 501, HUD
    // daemon as ROOT — kill(_,0) yields EPERM for an existing privileged process.
    NSString *pidStr = [NSString stringWithContentsOfFile:@AETHER_HUD_PID_PATH
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    if (pidStr.length) {
        pid_t hudPID = (pid_t)[pidStr intValue];
        if (hudPID > 0) {
            int alive = kill(hudPID, 0);
            if (alive == 0 || errno == EPERM) return YES;
        }
    }
    return NO;
}

- (void)setGlobalFloatingHUDEnabled:(BOOL)enabled {
    AetherSharedState *state = AetherGetSharedState();

    uint32_t execSize = 0;
    _NSGetExecutablePath(NULL, &execSize);
    char *execPath = (char *)calloc(1, execSize + 1);
    _NSGetExecutablePath(execPath, &execSize);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

#if !TARGET_OS_SIMULATOR
    // Elevate HUD child daemon to root (UID 0 / GID 0) using com.apple.private.persona-mgmt
    // Required so SpringBoard does not kill the HUD window upon device lock/unlock
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
#endif

    if (enabled) {
        if ([self isGlobalFloatingHUDRunning]) {
            free(execPath);
            posix_spawnattr_destroy(&attr);
            return;
        }

        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

        if (state) {
            aether_atomic_store(&state->hudCommand, 0);
            aether_atomic_store(&state->hudHeartbeatTs, 0);
        }
        pid_t childPID = 0;
        const char *args[] = { execPath, "-hud", NULL };
        int rc = posix_spawn(&childPID, execPath, NULL, &attr, (char **)args, environ);
        AetherLog(@"spawn HUD daemon rc=%d pid=%d", rc, rc == 0 ? childPID : -1);
        if (rc == 0 && state) {
            aether_atomic_store(&state->hudVisible, true);
        }
    } else {
        // Primary: graceful exit via shm command channel (the HUD daemon's
        // heartbeat timer observes this and exit(0)s itself)
        if (state) {
            aether_atomic_store(&state->hudCommand, 1);
            aether_atomic_store(&state->hudHeartbeatTs, 0);
            aether_atomic_store(&state->hudVisible, false);
            aether_atomic_store(&state->interceptionActive, false);
            AetherLog(@"HUD remove command sent (graceful exit + legacy -exit)");
            pid_t fp = aether_atomic_load(&state->rootFrozenPid);
            if (fp > 0) { kill(fp, SIGCONT); aether_atomic_store(&state->rootFrozenPid, 0);
                          AetherLog(@"unfroze pid %d on HUD remove", fp); }
        }
        notify_post(kAetherNotifyHUDToggle);

        // Fallback: legacy -exit re-exec (pid-file based)
        pid_t childPID = 0;
        const char *args[] = { execPath, "-exit", NULL };
        posix_spawn(&childPID, execPath, NULL, &attr, (char **)args, environ);
    }

    posix_spawnattr_destroy(&attr);
    free(execPath);
    notify_post(kAetherNotifyStateChanged);
}

- (void)setInterceptionActive:(BOOL)active {
    AetherSharedState *state = AetherGetSharedState();
    if (!state) return;

    bool wasActive = aether_atomic_exchange(&state->interceptionActive, active);
    AetherLog(@"interception %s (was %d)", active ? "START" : "STOP", wasActive);

    // ── Frida-style LIVE attach on demand (user requirement: no respring,
    // no tweak installation). If the earlier attach-time injection didn't
    // land (target relaunched / was busy), retry NOW with fresh logs of the
    // exact Mach failure. The payload announces itself via
    // "[hook] payload armed in target" in the merged log on success. ──
    if (active && !aether_atomic_load(&state->isInjected)) {
        pid_t targetPID = aether_atomic_load(&state->targetPID);
        if (targetPID > 0) {
            NSString *bundled = [[NSBundle mainBundle] pathForResource:@"libNetHookPayload" ofType:@"dylib"];
            NSString *signedCopy = @"/var/mobile/Library/AetherNetHook.signed.dylib";
            NSString *use = bundled ?: nil;
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:signedCopy]) use = signedCopy; // coretrust-signed beats adhoc
            if (use) {
                [fm removeItemAtPath:@AETHER_DYLIB_INSTALL_PATH error:nil];
                [fm copyItemAtPath:use toPath:@AETHER_DYLIB_INSTALL_PATH error:nil];
                chmod(AETHER_DYLIB_INSTALL_PATH, 0755);
            }
            char errBuf2[256] = {0};
            int rc2 = AetherInjectDylibIntoPID(targetPID, AETHER_DYLIB_INSTALL_PATH, errBuf2, sizeof(errBuf2));
            AetherLog(@"LIVE attach pid %d rc=%d src=%@ err=[%s]",
                      targetPID, rc2, use.lastPathComponent ?: @"(none)", errBuf2);
            if (rc2 == 0) {
                aether_atomic_store(&state->isInjected, true);
                aether_atomic_store(&state->injectionMethod, 1);
            }
        }
    }

    if (wasActive && !active) {
        // Flushing held TCP/UDP packet queue when switching from ⏸ (Pause/Hold) -> ▶ (Play/Release)
        notify_post(kAetherNotifyFlushQueue);
    }

    pid_t targetPID = aether_atomic_load(&state->targetPID);
    if (targetPID > 0 && aether_atomic_load(&state->injectionMethod) == 2) {
        AetherApplyRootTrafficControl(targetPID, state);
    }

    // Keep the VPN relay engine in sync: floating button + app toggle both
    // land here, so the extension sees the same switch instantly.
    HybridWriteExtOverrideFiles(active);

    notify_post(kAetherNotifyStateChanged);
}

@end

#pragma mark - C bridge for Swift (see Hybrid/BridgingHeader.h)
//
// Plain-C surface so Swift can drive the HUD daemon lifecycle without the
// bridging importer choking on AetherNetShared.h's `_Atomic` fields.

#import <sys/stat.h>

bool HybridHUDIsRunning(void) {
    return [[AetherProcessManager sharedManager] isGlobalFloatingHUDRunning];
}

int HybridHUDPrepareForSpawn(void) {
    AetherSharedState *state = AetherGetSharedState();

    // 1. Old daemon alive? Ask it to leave (graceful shm command + root -exit).
    BOOL wasAlive = [[AetherProcessManager sharedManager] isGlobalFloatingHUDRunning];
    if (wasAlive) {
        if (state) {
            aether_atomic_store(&state->hudCommand, 1);
            aether_atomic_store(&state->hudHeartbeatTs, 0);
        }
        uint32_t execSize = 0;
        _NSGetExecutablePath(NULL, &execSize);
        char *execPath = (char *)calloc(1, execSize + 1);
        _NSGetExecutablePath(execPath, &execSize);

        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
#if !TARGET_OS_SIMULATOR
        posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&attr, 0);
        posix_spawnattr_set_persona_gid_np(&attr, 0);
#endif
        pid_t child = 0;
        const char *args[] = { execPath, "-exit", NULL };
        posix_spawn(&child, execPath, NULL, &attr, (char **)args, environ);
        posix_spawnattr_destroy(&attr);
        free(execPath);

        // Give the old daemon a moment to die before we clear its pid file.
        usleep(350 * 1000);
    }

    // 2. Stale pid file: unlink when the recorded pid is dead OR is not our
    //    executable (pid reuse by an innocent process would otherwise trip the
    //    daemon's single-instance guard and make it exit instantly).
    NSString *pidStr = [NSString stringWithContentsOfFile:@AETHER_HUD_PID_PATH
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    if (pidStr.length) {
        pid_t oldPid = (pid_t)[pidStr intValue];
        BOOL stale = YES;
        if (oldPid > 0 && (kill(oldPid, 0) == 0 || errno == EPERM)) {
            char pathBuf[4096] = {0};
            char selfBuf[4096] = {0};
            uint32_t len = sizeof(selfBuf);
            if (proc_pidpath(oldPid, pathBuf, sizeof(pathBuf)) > 0 &&
                _NSGetExecutablePath(selfBuf, &len) == 0 &&
                strcmp(pathBuf, selfBuf) == 0) {
                stale = NO; // alive AND ours — isGlobalFloatingHUDRunning missed it
            }
        }
        if (stale) unlink(AETHER_HUD_PID_PATH);
    }

    // 3. Reset the command channel so the fresh daemon is not killed by a
    //    leftover exit command (the original "Create does nothing" bug).
    if (state) {
        aether_atomic_store(&state->hudCommand, 0);
        aether_atomic_store(&state->hudHeartbeatTs, 0);
        aether_atomic_store(&state->hudVisible, false);
    }
    return wasAlive ? 1 : 0;
}

void HybridHUDRequestExit(void) {
    AetherSharedState *state = AetherGetSharedState();
    if (state) {
        aether_atomic_store(&state->hudCommand, 1);
        aether_atomic_store(&state->hudHeartbeatTs, 0);
        aether_atomic_store(&state->hudVisible, false);
        pid_t fp = aether_atomic_load(&state->rootFrozenPid);
        if (fp > 0) {
            kill(fp, SIGCONT);
            aether_atomic_store(&state->rootFrozenPid, 0);
        }
    }
    notify_post(kAetherNotifyHUDToggle);

    // Legacy fallback: root "-exit" re-exec (pid-file based).
    uint32_t execSize = 0;
    _NSGetExecutablePath(NULL, &execSize);
    char *execPath = (char *)calloc(1, execSize + 1);
    _NSGetExecutablePath(execPath, &execSize);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
#if !TARGET_OS_SIMULATOR
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
#endif
    pid_t child = 0;
    const char *args[] = { execPath, "-exit", NULL };
    posix_spawn(&child, execPath, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);
    free(execPath);
}

int HybridSpawnRoot(const char *execPath, const char *argv1, const char *argv2) {
    if (!execPath) return -1;
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
#if !TARGET_OS_SIMULATOR
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
#endif
    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

    const char *args[4] = { execPath, argv1, argv2, NULL };
    pid_t child = 0;
    int rc = posix_spawn(&child, execPath, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);
    AetherLog(@"HybridSpawnRoot %s %s rc=%d pid=%d", execPath, argv1 ?: "", rc, child);
    if (rc == 0) {
        AetherSharedState *state = AetherGetSharedState();
        if (state && argv1 && strcmp(argv1, "-hud") == 0) {
            aether_atomic_store(&state->hudVisible, true);
        }
    }
    return rc;
}

void HybridHUDSyncFloatingConfig(float size, float opacity, bool edgeSnap,
                                 bool lockPosition, bool haptic,
                                 float posX, float posY) {
    AetherSharedState *state = AetherGetSharedState();
    if (!state) {
        AetherLog(@"HybridHUDSyncFloatingConfig: no shm yet — settings apply on next daemon spawn");
        return;
    }
    aether_atomic_store(&state->floatingButtonSize, size);
    aether_atomic_store(&state->floatingButtonOpacity, opacity);
    aether_atomic_store(&state->floatingEdgeSnap, edgeSnap);
    aether_atomic_store(&state->floatingLockPosition, lockPosition);
    aether_atomic_store(&state->floatingHapticEnabled, haptic);
    aether_atomic_store(&state->floatingPosX, posX);
    aether_atomic_store(&state->floatingPosY, posY);
    notify_post(kAetherNotifyConfigChanged);
}

void HybridHUDSetInterceptionActive(bool active) {
    // setInterceptionActive: updates shm + retries live injection + applies PF
    // rules + writes the extension override files (HybridWriteExtOverrideFiles),
    // so the VPN relay engine follows the same switch instantly.
    [[AetherProcessManager sharedManager] setInterceptionActive:active ? YES : NO];
}

// ─────────────────────────────────────────────────────────────────────────────
// ROOT socket dump (per-PID targeting) — synced with PacketBlocker/Core/
// PersonaHelper.m. proc_pidfdinfo on another process needs uid 0; the app is
// uid 501, so the dump runs in a root re-exec of this binary ("-sockdump").
// ─────────────────────────────────────────────────────────────────────────────

// Dumps the live TCP/UDP remote sockets of one PID via proc_pidfdinfo.
int HybridProcSocketDump(int pid, HybridSocketEntryC *out, int max) {
    if (!out || max <= 0 || pid <= 0) return 0;

    int bufSize = (int)proc_pidinfo((pid_t)pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bufSize <= 0) return 0;

    struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc(bufSize);
    if (!fds) return 0;
    int actual = (int)proc_pidinfo((pid_t)pid, PROC_PIDLISTFDS, 0, fds, bufSize);
    int fdCount = actual / (int)sizeof(struct proc_fdinfo);

    int written = 0;
    for (int i = 0; i < fdCount && written < max; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;

        struct aether_socket_fdinfo sinfo;
        int rc = (int)proc_pidfdinfo((pid_t)pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &sinfo, sizeof(sinfo));
        if (rc != (int)sizeof(sinfo)) continue;

        int family = sinfo.psi.soi_family;
        if (family != AF_INET && family != AF_INET6) continue;

        int sockType = sinfo.psi.soi_type;
        if (sockType != SOCK_STREAM && sockType != SOCK_DGRAM) continue;

        struct in_sockinfo *ini = (sockType == SOCK_STREAM)
            ? &sinfo.psi.soi_proto.pri_tcp.tcpsi_ini
            : &sinfo.psi.soi_proto.pri_in;

        HybridSocketEntryC *e = &out[written];
        memset(e, 0, sizeof(*e));
        e->localPort  = ntohs((uint16_t)ini->insi_lport);
        e->remotePort = ntohs((uint16_t)ini->insi_fport);
        snprintf(e->proto, sizeof(e->proto), "%s", (sockType == SOCK_STREAM) ? "tcp" : "udp");

        char ip[64] = {0};
        if (family == AF_INET) {
            inet_ntop(AF_INET, &ini->insi_faddr.ina_46, ip, sizeof(ip));
        } else {
            inet_ntop(AF_INET6, &ini->insi_faddr.ina_6, ip, sizeof(ip));
        }
        snprintf(e->remoteIP, sizeof(e->remoteIP), "%s", ip);

        if (e->remotePort == 0 || strncmp(e->remoteIP, "127.0.0.1", 9) == 0 || e->remoteIP[0] == '\0') continue;

        written++;
    }

    free(fds);
    return written;
}

// ROOT side: dump one pid's sockets into a JSON file (chmod 0666).
// A valid EMPTY dump still writes "[]" so the app can distinguish outcomes.
int HybridWriteSocketDumpFile(int pid, const char *outfile) {
    if (pid <= 0 || !outfile || !outfile[0]) return -1;

    HybridSocketEntryC buf[128];
    int n = HybridProcSocketDump((pid_t)pid, buf, 128);

    FILE *f = fopen(outfile, "w");
    if (!f) return -2;
    fprintf(f, "[");
    for (int i = 0; i < n; i++) {
        fprintf(f, "%s{\"proto\":\"%s\",\"localPort\":%u,\"remotePort\":%u,\"remoteIP\":\"%s\"}",
                (i > 0) ? "," : "",
                buf[i].proto,
                (unsigned)buf[i].localPort,
                (unsigned)buf[i].remotePort,
                buf[i].remoteIP);
    }
    fprintf(f, "]");
    fclose(f);
    chmod(outfile, 0666);
    return n;
}

// APP side: spawn the root helper, wait (≤2s) for the result file.
BOOL HybridSockDumpViaRoot(int pid, const char *outfile) {
    if (pid <= 0 || !outfile || !outfile[0]) return NO;

    unlink(outfile);

    uint32_t len = 0;
    _NSGetExecutablePath(NULL, &len);
    if (len == 0) return NO;
    char *execPath = (char *)calloc(1, len + 1);
    if (_NSGetExecutablePath(execPath, &len) != 0) { free(execPath); return NO; }

    char arg2[2048];
    snprintf(arg2, sizeof(arg2), "%d %s", pid, outfile);
    int rc = HybridSpawnRoot(execPath, "-sockdump", arg2);
    free(execPath);
    if (rc != 0) return NO;

    for (int i = 0; i < 40; i++) { // 40 × 50ms = 2.0s budget
        usleep(50 * 1000);
        struct stat st;
        if (stat(outfile, &st) == 0 && st.st_size >= 2) return YES;
    }
    return NO;
}

