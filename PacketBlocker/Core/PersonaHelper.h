#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ── Root spawn (persona UID 0) ──────────────────────────────────────────────
int HybridSpawnWithPersona(uid_t uid, gid_t gid, const char *execPath, char *const argv[], char *const envp[], pid_t *outPID);
int HybridSpawnRoot(const char *execPath, const char *arg1, const char *arg2);
// Same spawn but also returns the CHILD PID (outPid may be NULL). rc is the
// posix_spawn return code (0 = spawned — NOT a guarantee that exec succeeded);
// probe the child afterwards with HybridProcIsAlive / HybridChildPidPath.
int HybridSpawnRootPID(const char *execPath, const char *arg1, const char *arg2, int * _Nullable outPid);
// Convenience liveness probe for a freshly spawned child:
//   0 = gone, 1 = alive, 2 = alive-but-more-privileged (EPERM on signal 0).
// When alive, childPath (if non-NULL, <=1024 bytes) receives proc_pidpath.
int HybridProbeChildPid(int pid, char * _Nullable childPath, int pathMax);

// ── HUD daemon lifecycle helpers (port of TrollNetInterceptor
//    ProcessManager.setGlobalFloatingHUDEnabled / isGlobalFloatingHUDRunning) ──

// Prepares shared state right before spawning a fresh -hud daemon:
//   1. If an old daemon is alive (pid file / shm heartbeat / EPERM probe) it is
//      asked to exit via the shm command channel + a root "-exit" re-exec.
//   2. Stale pid files are removed, shm hudCommand/hudHeartbeatTs are reset so
//      the NEW daemon cannot be killed by a leftover "exit" command.
// Returns: 0 = clean to spawn now, 1 = an old daemon was killed, wait ~1s then spawn.
int HybridHUDPrepareForSpawn(void);

// YES when a HUD daemon PROCESS exists: shm heartbeat (<=3s old) or pid file
// with kill(pid,0)==0 / errno==EPERM (EPERM means "exists but more privileged").
// Used to decide whether an old daemon has to be killed before spawning.
BOOL HybridHUDDaemonAlive(void);

// YES only when the user can actually SEE a button: the daemon is alive AND it
// has registered its window (shm hudVisible, set after
// registerWindowWithContextID:). A daemon that booted and died before
// rendering must not be reported as running.
BOOL HybridHUDIsRunning(void);

// Graceful stop: shm hudCommand=1 (daemon heartbeat exits itself), then the
// legacy root "-exit" re-exec as a fallback, then stale pid file cleanup.
void HybridHUDRequestExit(void);

// Writes the build number into the shm daemon handshake field (best effort).
void HybridHUDTouchHeartbeat(void);

// Pushes the floating-button customization (Settings tab) into the shared
// memory the HUD daemon reads. Without this the daemon never sees the
// size/opacity/position changes made in the SwiftUI app.
void HybridHUDSyncFloatingConfig(float size, float opacity, bool edgeSnap,
                                 bool lockPosition, bool haptic,
                                 float posX, float posY);

// ── Real process enumeration (sysctl KERN_PROC_ALL + libproc SPI) ───────────
// Replaces the mock Swift enumerator so per-PID VPN targeting gets REAL data.

typedef struct {
    int  pid;
    int  ppid;
    int  uid;
    int  isUserApp;
    int  tcpCount;
    int  udpCount;
    char name[256];
    char displayName[256];
    char bundleID[256];
    char execPath[1024];
} HybridProcInfo;

typedef struct {
    unsigned short localPort;
    unsigned short remotePort;
    char           remoteIP[46];
    char           proto[8];   // "tcp" / "udp"
} HybridSocketEntryC;

// Enumerates running processes. Returns count written (<= max). Scan is
// best-effort: on sandboxed/non-TrollStore builds it may return 0.
int HybridProcEnumerate(HybridProcInfo * _Nullable out, int max);

// Dumps the live TCP/UDP remote sockets of one PID via proc_pidfdinfo.
// Returns count written (<= max).
int HybridProcSocketDump(int pid, HybridSocketEntryC * _Nullable out, int max);

// ── ROOT socket dump (per-PID targeting on device) ──────────────────────────
// proc_pidfdinfo on another process needs uid 0; the app is uid 501. The app
// re-execs ITSELF as root ("self -sockdump <pid> <outfile>"); the helper
// writes a JSON array (chmod 0666) and exits. No UIKit → cannot die like HUD.

// ROOT side (called from main.mm "-sockdump"). Writes the JSON result file.
// Returns entry count, or <0 on failure. A valid EMPTY dump still writes "[]".
int HybridWriteSocketDumpFile(int pid, const char *outfile);

// APP side: spawn the root helper, wait (≤2s) for the result file.
// YES = file produced (parse it), NO = fall back to the in-process dump.
// childPid (may be NULL) receives the helper pid immediately after spawn.
BOOL HybridSockDumpViaRootPID(int pid, const char *outfile, int * _Nullable childPid);
BOOL HybridSockDumpViaRoot(int pid, const char *outfile);

// 0 when the pid is gone, 1 when alive, 2 when alive-but-root (EPERM).
int HybridProcIsAlive(int pid);

NS_ASSUME_NONNULL_END
