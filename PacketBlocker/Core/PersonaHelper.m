#import "PersonaHelper.h"
#import "AetherLog.h"
#import "AetherNetShared.h"
#import "PrivateSystemSPI.h"
#import <spawn.h>
#import <dlfcn.h>
#import <unistd.h>
#import <signal.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>
#import <time.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <mach-o/dyld.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <limits.h>

extern char **environ;

// ─────────────────────────────────────────────────────────────────────────────
// Root spawn (persona UID 0) — unchanged logic, kept for compatibility
// ─────────────────────────────────────────────────────────────────────────────

// Re-exec'd helpers/daemons must NOT inherit the app's XPC session variables
// (__XPC_*/XPC_*). launchd wires those to the PARENT's XPC session, so the
// child's own bootstrap/XPC setup can misbehave or bail out silently before
// main(). Build a cleaned environment once and use it for every spawn.
static char *const *HybridCleanEnvp(void) {
    static char **cleanEnv = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *kept = [NSMutableArray array];
        for (char **e = environ; e && *e; e++) {
            NSString *kv = [NSString stringWithUTF8String:*e];
            if (!kv) continue;
            if ([kv hasPrefix:@"__XPC_"] || [kv hasPrefix:@"XPC_"]) continue;
            [kept addObject:kv];
        }
        NSUInteger n = kept.count;
        cleanEnv = (char **)malloc(sizeof(char *) * (n + 1));
        if (!cleanEnv) return;
        for (NSUInteger i = 0; i < n; i++) {
            const char *c = kept[i].UTF8String;
            char *dup = (char *)malloc(strlen(c) + 1);
            if (dup) strcpy(dup, c);
            cleanEnv[i] = dup;
        }
        cleanEnv[n] = NULL;
    });
    return cleanEnv;
}

int HybridSpawnWithPersona(uid_t uid, gid_t gid, const char *execPath, char *const argv[], char *const envpIn[], pid_t *outPID) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    // Persona 99 + POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE is the TrollNetInterceptor
    // incantation that yields a uid-0 child on iOS. Persona 0 means "current
    // user's default persona" and does NOT escalate — the child stays uid 501
    // and SpringBoard kills the HUD window on lock. Every setter's return code
    // is logged: a non-zero return IS the root cause if the daemon isn't root.
    int persona_rc = -1, puid_rc = -1, pgid_rc = -1, papptype_rc = -1;
    const char *missing = NULL;
    void *handle = dlopen(NULL, RTLD_NOW);
    if (handle) {
        int (*set_persona_np)(posix_spawnattr_t *, int, uint32_t) = dlsym(handle, "posix_spawnattr_set_persona_np");
        int (*set_persona_uid_np)(posix_spawnattr_t *, uid_t)     = dlsym(handle, "posix_spawnattr_set_persona_uid_np");
        int (*set_persona_gid_np)(posix_spawnattr_t *, gid_t)     = dlsym(handle, "posix_spawnattr_set_persona_gid_np");
        if (!set_persona_np)     missing = "posix_spawnattr_set_persona_np";
        else if (!set_persona_uid_np) missing = "posix_spawnattr_set_persona_uid_np";
        else if (!set_persona_gid_np) missing = "posix_spawnattr_set_persona_gid_np";
        if (set_persona_np)     persona_rc = set_persona_np(&attr, 99, 1 /* POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE */);
        if (set_persona_uid_np) puid_rc    = set_persona_uid_np(&attr, uid);
        if (set_persona_gid_np) pgid_rc    = set_persona_gid_np(&attr, gid);
    }

    if (handle) {
        // iOS 15+ FrontBoard/RunningBoard only grants a display scene to a
        // child declared as a UI application. TrollSpeed gets this from its
        // LaunchDaemon (POSIXSpawnType=App); we spawn directly, so we have to
        // say it ourselves or the overlay window never renders.
        int (*set_apptype_np)(posix_spawnattr_t *, int) =
            (int (*)(posix_spawnattr_t *, int))dlsym(handle, "posix_spawnattr_setapptype_np");
        if (set_apptype_np) papptype_rc = set_apptype_np(&attr, 3 /* POSIX_SPAWN_PROCESS_TYPE_UIAPP */);
    }
    AetherLog(@"persona spawn: persona=%d uid=%d gid=%d apptype=%d missing=%s",
              persona_rc, puid_rc, pgid_rc, papptype_rc, missing ? missing : "-");

    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);

    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);

    // Ignore the caller's envp (usually the raw environ) and use the cleaned
    // environment instead — XPC session vars must not leak into children.
    char *const *envp = (char *const *)HybridCleanEnvp();
    int result = posix_spawn(outPID, execPath, &fileActions, &attr, argv, envp);

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fileActions);

    return result;
}

int HybridSpawnRootPID(const char *execPath, const char *arg1, const char *arg2, int *outPid) {
    pid_t pid = 0;
    const char *argv[4];
    argv[0] = execPath;
    argv[1] = arg1;
    argv[2] = arg2;
    argv[3] = NULL;
    int rc = HybridSpawnWithPersona(0, 0, execPath, (char *const *)argv, NULL, &pid);
    if (outPid) *outPid = (int)pid;

    // rc == 0 only means "fork + exec worked". Prove the escalation landed:
    // from a uid-501 parent, kill() on a uid-0 child returns EPERM, which is
    // exactly what HybridProbeChildPid reports as 2. Reporting this is the
    // difference between "spawn rc=0" and "a daemon that is actually root".
    if (rc == 0 && pid > 0) {
        for (int i = 0; i < 20; i++) {
            int probe = HybridProbeChildPid((int)pid, NULL, 0);
            if (probe == 2) { AetherLog(@"root spawn %s: pid %d IS root", arg1, (int)pid); break; }
            if (probe == 0) { AetherLog(@"root spawn %s: pid %d died immediately", arg1, (int)pid); break; }
            usleep(25000);
        }
    }
    return rc;
}

int HybridSpawnRoot(const char *execPath, const char *arg1, const char *arg2) {
    return HybridSpawnRootPID(execPath, arg1, arg2, NULL);
}

int HybridProbeChildPid(int pid, char *childPath, int pathMax) {
    if (pid <= 0) return 0;
    errno = 0;
    int rc = kill((pid_t)pid, 0);
    int alive = 0;
    if (rc == 0) alive = 1;
    else if (errno == EPERM) alive = 2;
    if (alive && childPath && pathMax > 0) {
        memset(childPath, 0, (size_t)pathMax);
        if (proc_pidpath((pid_t)pid, childPath, (size_t)pathMax) <= 0) childPath[0] = '\0';
    }
    return alive;
}

// ─────────────────────────────────────────────────────────────────────────────
// HUD daemon lifecycle — ported 1:1 from TrollNetInterceptor (the .zip source)
// so "Create Floating Button" behaves exactly like the reference app:
//   * shm heartbeat is the PRIMARY liveness channel (works across uid 501↔root)
//   * pid file + kill() is the fallback, EPERM counts as "alive"
//   * hudCommand / hudHeartbeatTs MUST be reset before spawning a new daemon,
//     otherwise a leftover exit command kills the fresh daemon in <1s
//     (the exact "bấm Create mà không thấy nút" bug).
// ─────────────────────────────────────────────────────────────────────────────

static BOOL HUDPidFilePid(pid_t *outPid) {
    FILE *f = fopen(AETHER_HUD_PID_PATH, "r");
    if (!f) return NO;
    char buf[32] = {0};
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    if (n == 0) return NO;
    int v = atoi(buf);
    if (v <= 0) return NO;
    *outPid = (pid_t)v;
    return YES;
}

static BOOL HUDProcessAlive(pid_t pid) {
    if (pid <= 0) return NO;
    errno = 0;
    int rc = kill(pid, 0);
    if (rc == 0) return YES;
    return (errno == EPERM); // exists but more privileged (root daemon)
}

// "Is a daemon process around?" — used to decide whether an OLD daemon must be
// killed before spawning a new one. Deliberately ignores window state.
BOOL HybridHUDDaemonAlive(void) {
    // Channel 1 (primary): shm heartbeat — the daemon stamps time(NULL) every 1s.
    AetherSharedState *st = AetherGetSharedState();
    if (st) {
        uint64_t hb = aether_atomic_load(&st->hudHeartbeatTs);
        if (hb > 0 && (uint64_t)time(NULL) - hb <= 3) {
            // Cross-check the pid file when present: a heartbeat from a daemon
            // that died a moment ago can linger for up to 3s.
            pid_t pidFilePid = 0;
            if (HUDPidFilePid(&pidFilePid)) {
                if (HUDProcessAlive(pidFilePid)) return YES;
                // heartbeat fresh but process gone → treat as not running and
                // clean the stale fields so a new spawn is never blocked.
                aether_atomic_store(&st->hudHeartbeatTs, 0);
                aether_atomic_store(&st->hudCommand, 0);
                unlink(AETHER_HUD_PID_PATH);
                return NO;
            }
            return YES;
        }
    }

    // Channel 2 (fallback): pid file + signal probe.
    pid_t pid = 0;
    if (HUDPidFilePid(&pid) && HUDProcessAlive(pid)) return YES;
    return NO;
}

// "Can the user see a button?" — the heartbeat alone is not enough: the daemon
// stamps it from boot step 1, so a daemon that dies before
// registerWindowWithContextID: looked healthy forever and the watchdog never
// rescued it. hudVisible is set only once the window is on screen.
BOOL HybridHUDIsRunning(void) {
    if (!HybridHUDDaemonAlive()) return NO;
    AetherSharedState *st = AetherGetSharedState();
    if (st && !aether_atomic_load(&st->hudVisible)) return NO;
    return YES;
}

int HybridHUDPrepareForSpawn(void) {
    @autoreleasepool {
        char execPath[4096] = {0};
        uint32_t len = sizeof(execPath);
        if (_NSGetExecutablePath(execPath, &len) != 0) return 0;

        BOOL killedOld = NO;
        if (HybridHUDDaemonAlive()) {
            // 1. Graceful: shm command channel (daemon heartbeat observes it).
            AetherSharedState *st = AetherGetSharedState();
            if (st) aether_atomic_store(&st->hudCommand, 1);

            // 2. Legacy: root "-exit" re-exec (kills whatever owns the pid file,
            //    including a daemon left by an OLDER app build / the old
            //    TrollNetInterceptor app which shares the same shm + pid paths).
            HybridSpawnRoot(execPath, "-exit", NULL);

            // 3. Belt & braces: direct SIGKILL on the pid-file pid when we can.
            pid_t pid = 0;
            if (HUDPidFilePid(&pid)) {
                kill(pid, SIGKILL);
            }
            killedOld = YES;
            AetherLog(@"HUD prepare: killed previous daemon (pid %d)", pid);
            usleep(600 * 1000); // give the old daemon time to die & unlink
        }

        // Always: remove stale pid file + reset shm handshake so the new
        // daemon starts with a CLEAN command channel.
        unlink(AETHER_HUD_PID_PATH);
        AetherSharedState *st = AetherGetSharedState();
        if (st) {
            aether_atomic_store(&st->hudCommand, 0);
            aether_atomic_store(&st->hudHeartbeatTs, 0);
            aether_atomic_store(&st->hudVisible, false);
        }
        return killedOld ? 1 : 0;
    }
}

void HybridHUDRequestExit(void) {
    @autoreleasepool {
        AetherSharedState *st = AetherGetSharedState();
        if (st) {
            aether_atomic_store(&st->hudCommand, 1);
            aether_atomic_store(&st->hudHeartbeatTs, 0);
            aether_atomic_store(&st->hudVisible, false);
        }

        char execPath[4096] = {0};
        uint32_t len = sizeof(execPath);
        if (_NSGetExecutablePath(execPath, &len) == 0) {
            HybridSpawnRoot(execPath, "-exit", NULL);
        }

        pid_t pid = 0;
        if (HUDPidFilePid(&pid)) {
            kill(pid, SIGKILL);
        }
        unlink(AETHER_HUD_PID_PATH);
        AetherLog(@"HUD exit requested (shm cmd + -exit + SIGKILL fallback)");
    }
}

void HybridHUDTouchHeartbeat(void) {
    AetherSharedState *st = AetherGetSharedState();
    if (st) aether_atomic_store(&st->daemonBuild, AETHER_BUILD_NUM);
}

void HybridHUDSyncFloatingConfig(float size, float opacity, bool edgeSnap,
                                 bool lockPosition, bool haptic,
                                 float posX, float posY) {
    AetherSharedState *st = AetherGetSharedState();
    if (!st) return;
    aether_atomic_store(&st->floatingButtonSize, size);
    aether_atomic_store(&st->floatingButtonOpacity, opacity);
    aether_atomic_store(&st->floatingEdgeSnap, edgeSnap);
    aether_atomic_store(&st->floatingLockPosition, lockPosition);
    aether_atomic_store(&st->floatingHapticEnabled, haptic);
    if (posX > 0 && posY > 0) {
        aether_atomic_store(&st->floatingPosX, posX);
        aether_atomic_store(&st->floatingPosY, posY);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Real process enumeration (ports TrollNetInterceptor ProcessManager.mm)
// ─────────────────────────────────────────────────────────────────────────────

static void CopyStr(char *dst, size_t dstSz, const char *src) {
    if (!src) { dst[0] = '\0'; return; }
    strncpy(dst, src, dstSz - 1);
    dst[dstSz - 1] = '\0';
}

static void CountSocketsForPID(pid_t pid, int *outTCP, int *outUDP) {
    int tcp = 0, udp = 0;
    int bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bufSize > 0) {
        struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc(bufSize);
        if (fds) {
            int actual = (int)proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bufSize);
            int fdCount = actual / (int)sizeof(struct proc_fdinfo);
            for (int i = 0; i < fdCount; i++) {
                if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
                struct aether_socket_fdinfo sinfo;
                int rc = (int)proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &sinfo, sizeof(sinfo));
                if (rc != (int)sizeof(sinfo)) continue;
                int fam = sinfo.psi.soi_family;
                if (fam != AF_INET && fam != AF_INET6) continue;
                if (sinfo.psi.soi_type == SOCK_STREAM) tcp++;
                else if (sinfo.psi.soi_type == SOCK_DGRAM) udp++;
            }
            free(fds);
        }
    }
    *outTCP = tcp;
    *outUDP = udp;
}

int HybridProcIsAlive(int pid) {
    if (pid <= 0) return 0;
    errno = 0;
    int rc = kill((pid_t)pid, 0);
    if (rc == 0) return 1;
    if (errno == EPERM) return 2;
    return 0;
}

int HybridProcEnumerate(HybridProcInfo *out, int max) {
    if (!out || max <= 0) return 0;

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t bufSize = 0;
    if (sysctl(mib, 4, NULL, &bufSize, NULL, 0) < 0 || bufSize == 0) return 0;
    bufSize += sizeof(struct kinfo_proc) * 32;

    struct kinfo_proc *procs = (struct kinfo_proc *)calloc(1, bufSize);
    if (!procs) return 0;
    if (sysctl(mib, 4, procs, &bufSize, NULL, 0) < 0) {
        free(procs);
        return 0;
    }

    size_t count = bufSize / sizeof(struct kinfo_proc);
    pid_t selfPID = getpid();
    int written = 0;

    for (size_t i = 0; i < count && written < max; i++) {
        struct kinfo_proc *kp = &procs[i];
        pid_t pid = kp->kp_proc.p_pid;
        if (pid <= 1 || pid == selfPID) continue;

        char pathBuf[PATH_MAX] = {0};
        proc_pidpath(pid, pathBuf, sizeof(pathBuf));

        HybridProcInfo *info = &out[written];
        memset(info, 0, sizeof(*info));
        info->pid  = (int)pid;
        info->ppid = (int)kp->kp_eproc.e_ppid;
        info->uid  = (int)kp->kp_eproc.e_ucred.cr_uid;

        const char *comm = kp->kp_proc.p_comm;
        CopyStr(info->name, sizeof(info->name), comm);
        if (pathBuf[0]) {
            CopyStr(info->execPath, sizeof(info->execPath), pathBuf);
            const char *lastSlash = strrchr(pathBuf, '/');
            CopyStr(info->name, sizeof(info->name), lastSlash ? lastSlash + 1 : pathBuf);
        }

        BOOL isAppBundle = (strstr(info->execPath, ".app/") != NULL);
        BOOL isUserApp   = (strncmp(info->execPath, "/var/containers/Bundle/Application/", 35) == 0 ||
                            strncmp(info->execPath, "/private/var/containers/Bundle/Application/", 43) == 0);
        info->isUserApp = isUserApp ? 1 : 0;
        CopyStr(info->displayName, sizeof(info->displayName), info->name);
        CopyStr(info->bundleID, sizeof(info->bundleID), isUserApp ? "com.user.application" : "com.apple.system");

        if (isAppBundle) {
            // Resolve localized name + bundle id from the .app Info.plist
            char bundleDir[1024] = {0};
            const char *appMark = strstr(info->execPath, ".app/");
            if (appMark) {
                size_t n = (size_t)(appMark - info->execPath) + 4;
                if (n >= sizeof(bundleDir)) n = sizeof(bundleDir) - 1;
                memcpy(bundleDir, info->execPath, n);
                char plistPath[1200];
                snprintf(plistPath, sizeof(plistPath), "%s/Info.plist", bundleDir);
                NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:@(plistPath)];
                if (infoPlist) {
                    NSString *dn = infoPlist[@"CFBundleDisplayName"] ?: infoPlist[@"CFBundleName"];
                    NSString *bid = infoPlist[@"CFBundleIdentifier"];
                    if ([dn isKindOfClass:[NSString class]]) CopyStr(info->displayName, sizeof(info->displayName), dn.UTF8String);
                    if ([bid isKindOfClass:[NSString class]]) CopyStr(info->bundleID, sizeof(info->bundleID), bid.UTF8String);
                }
            }
        }

        int tcp = 0, udp = 0;
        CountSocketsForPID(pid, &tcp, &udp);
        info->tcpCount = tcp;
        info->udpCount = udp;

        written++;
    }

    free(procs);
    return written;
}

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
        CopyStr(e->proto, sizeof(e->proto), (sockType == SOCK_STREAM) ? "tcp" : "udp");

        char ip[64] = {0};
        if (family == AF_INET) {
            inet_ntop(AF_INET, &ini->insi_faddr.ina_46, ip, sizeof(ip));
        } else {
            inet_ntop(AF_INET6, &ini->insi_faddr.ina_6, ip, sizeof(ip));
        }
        CopyStr(e->remoteIP, sizeof(e->remoteIP), ip);

        // Skip loopback & unspecified remotes — they are never useful targets.
        if (e->remotePort == 0 || strncmp(e->remoteIP, "127.0.0.1", 9) == 0 || e->remoteIP[0] == '\0') continue;

        written++;
    }

    free(fds);
    return written;
}

// ─────────────────────────────────────────────────────────────────────────────
// ROOT socket dump — makes per-PID targeting REAL on device.
//
// proc_pidfdinfo on ANOTHER process requires uid 0. The app runs as mobile
// (uid 501) so the in-app dump always came back EMPTY ("socket dump EMPTY,
// sockets=0" in device logs) and per-PID targeting silently degraded to
// match-all. The persona root spawn IS proven to work on device (the -hud
// daemon runs), so we reuse the SAME binary re-exec trick:
//   app --posix_spawn(root, self, "-sockdump", "<pid> <outfile>")--> helper
//   helper: HybridProcSocketDump(pid) → JSON file (chmod 0666) → exit
//   app: polls for the file, parses it, feeds cfg.targetSockets.
// No UIKit is involved in this mode, so it cannot die like the HUD daemon.
// ─────────────────────────────────────────────────────────────────────────────

// ROOT side: dump one pid's live TCP/UDP remote sockets into a JSON file.
// Returns the number of entries written (0 is a VALID result — an empty "[]"
// file is still produced so the app can tell "dump ran, zero sockets" apart
// from "dump never ran").
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
    chmod(outfile, 0666); // app (uid 501) must be able to read it back
    return n;
}

// APP side: spawn the root helper and wait for the result file.
// Returns YES when the helper produced the file (parse it next),
// NO when spawn failed or the helper did not answer within the timeout —
// caller falls back to the (possibly empty) in-process dump.
// childPid (optional) receives the helper's pid right after spawn so the
// caller can probe whether the child even came up (exec-level diagnostics).
BOOL HybridSockDumpViaRootPID(int pid, const char *outfile, int *childPid) {
    if (pid <= 0 || !outfile || !outfile[0]) return NO;

    unlink(outfile); // stale result from a previous dump must not satisfy us

    char execPath[4096] = {0};
    uint32_t len = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &len) != 0) return NO;

    char arg2[2048];
    snprintf(arg2, sizeof(arg2), "%d %s", pid, outfile);
    int rc = HybridSpawnRootPID(execPath, "-sockdump", arg2, childPid);
    if (rc != 0) return NO;

    // A cold spawn + proc dump typically completes in 50-300ms.
    for (int i = 0; i < 40; i++) { // 40 × 50ms = 2.0s budget
        usleep(50 * 1000);
        struct stat st;
        if (stat(outfile, &st) == 0 && st.st_size >= 2) return YES;
    }
    return NO;
}

BOOL HybridSockDumpViaRoot(int pid, const char *outfile) {
    return HybridSockDumpViaRootPID(pid, outfile, NULL);
}
