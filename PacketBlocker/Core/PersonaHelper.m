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
int HybridSpawnWithPersona(uid_t uid, gid_t gid, const char *execPath, char *const argv[], char *const envp[], pid_t *outPID) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    void *handle = dlopen(NULL, RTLD_NOW);
    if (handle) {
        int (*set_persona_np)(posix_spawnattr_t *, int, uint32_t) = dlsym(handle, "posix_spawnattr_set_persona_np");
        int (*set_persona_uid_np)(posix_spawnattr_t *, uid_t)     = dlsym(handle, "posix_spawnattr_set_persona_uid_np");
        int (*set_persona_gid_np)(posix_spawnattr_t *, gid_t)     = dlsym(handle, "posix_spawnattr_set_persona_gid_np");
        if (set_persona_np)     set_persona_np(&attr, 99, 1 /* POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE */);
        if (set_persona_uid_np) set_persona_uid_np(&attr, uid);
        if (set_persona_gid_np) set_persona_gid_np(&attr, gid);
    }

    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);

    posix_spawn_file_actions_t fileActions;
    posix_spawn_file_actions_init(&fileActions);

    int result = posix_spawn(outPID, execPath, &fileActions, &attr, argv, envp);

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fileActions);

    return result;
}

int HybridSpawnRoot(const char *execPath, const char *arg1, const char *arg2) {
    pid_t pid = 0;
    const char *argv[4];
    argv[0] = execPath;
    argv[1] = arg1;
    argv[2] = arg2;
    argv[3] = NULL;
    return HybridSpawnWithPersona(0, 0, execPath, (char *const *)argv, environ, &pid);
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

BOOL HybridHUDIsRunning(void) {
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

int HybridHUDPrepareForSpawn(void) {
    @autoreleasepool {
        char execPath[4096] = {0};
        uint32_t len = sizeof(execPath);
        if (_NSGetExecutablePath(execPath, &len) != 0) return 0;

        BOOL killedOld = NO;
        if (HybridHUDIsRunning()) {
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
            aether_atomic_store(&st->hudVisible, true);
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
