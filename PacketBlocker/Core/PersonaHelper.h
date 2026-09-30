#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ── Root spawn (persona UID 0) ──────────────────────────────────────────────
int HybridSpawnWithPersona(uid_t uid, gid_t gid, const char *execPath, char *const argv[], char *const envp[], pid_t *outPID);
int HybridSpawnRoot(const char *execPath, const char *arg1, const char *arg2);

// ── HUD daemon lifecycle helpers (port of TrollNetInterceptor
//    ProcessManager.setGlobalFloatingHUDEnabled / isGlobalFloatingHUDRunning) ──

// Prepares shared state right before spawning a fresh -hud daemon:
//   1. If an old daemon is alive (pid file / shm heartbeat / EPERM probe) it is
//      asked to exit via the shm command channel + a root "-exit" re-exec.
//   2. Stale pid files are removed, shm hudCommand/hudHeartbeatTs are reset so
//      the NEW daemon cannot be killed by a leftover "exit" command.
// Returns: 0 = clean to spawn now, 1 = an old daemon was killed, wait ~1s then spawn.
int HybridHUDPrepareForSpawn(void);

// YES when the HUD daemon looks alive: shm heartbeat (<=3s old) or pid file
// with kill(pid,0)==0 / errno==EPERM (EPERM means "exists but more privileged").
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
BOOL HybridSockDumpViaRoot(int pid, const char *outfile);

// 0 when the pid is gone, 1 when alive, 2 when alive-but-root (EPERM).
int HybridProcIsAlive(int pid);

NS_ASSUME_NONNULL_END
