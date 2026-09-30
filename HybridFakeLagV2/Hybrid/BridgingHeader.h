//
//  BridgingHeader.h — the ONLY header the Swift side imports.
//
//  Deliberately minimal: it does NOT include AetherNetShared.h (its `_Atomic`
//  fields cannot be parsed by the Swift Clang importer) and does NOT re-declare
//  AetherProcessManager. Everything crosses the bridge as plain C.
//
//  Implementations live in Core/ProcessManager.mm (already part of the app
//  target's Sources build phase — no pbxproj surgery needed for the .mm).
//

#ifndef HybridBridgingHeader_h
#define HybridBridgingHeader_h

#import <Foundation/Foundation.h>
#import <stdbool.h>
#import <notify.h>
#import "PrivateSystemSPI.h"

// NOTE: deliberately NO NS_ASSUME_NONNULL here — the char* parameters must
// import into Swift as optional pointers so callers can pass `nil`
// (e.g. HybridSpawnRoot(path, "-hud", nil)).

// ── HUD daemon lifecycle (wraps AetherProcessManager + shm command channel) ─
// YES when the HUD daemon looks alive: shm heartbeat (≤3s old) or pid file
// with kill(pid,0)==0 / errno==EPERM (EPERM = exists but more privileged).
bool HybridHUDIsRunning(void);

// Prepares shared state before spawning a fresh -hud daemon:
//   1. Asks a live old daemon to exit (shm hudCommand=1 + root "-exit" re-exec).
//   2. Removes stale pid files, resets shm hudCommand/hudHeartbeatTs so the
//      NEW daemon cannot be killed by a leftover exit command.
// Returns: 0 = spawn now, 1 = an old daemon was killed (wait ~1s then spawn).
int HybridHUDPrepareForSpawn(void);

// Graceful stop: shm hudCommand=1 (the daemon's heartbeat exits itself),
// then the legacy root "-exit" re-exec as fallback, then pid-file cleanup.
void HybridHUDRequestExit(void);

// Root spawn (persona UID 0 / GID 0 via posix_spawnattr_set_persona_np).
// argv1/argv2 may be NULL. Returns the posix_spawn result code (0 = ok).
// PID variant also returns the child pid (outPid may be NULL) — probe it with
// HybridProbeChildPid afterwards, since rc=0 does NOT prove exec succeeded.
int HybridSpawnRoot(const char *execPath, const char *argv1, const char *argv2);
int HybridSpawnRootPID(const char *execPath, const char *argv1, const char *argv2, int *outPid);

// 0 = gone, 1 = alive, 2 = alive-but-root (EPERM on signal 0).
// childPath (may be NULL) receives proc_pidpath of the live child.
int HybridProbeChildPid(int pid, char *childPath, int pathMax);

// Same probe for arbitrary pids (0=gone 1=alive 2=alive-but-more-privileged).
int HybridProcIsAlive(int pid);

// Pushes the floating-button customization into the shared memory the HUD
// daemon reads every frame. Without this the daemon never sees size/opacity/
// position changes made in the SwiftUI app.
void HybridHUDSyncFloatingConfig(float size, float opacity, bool edgeSnap,
                                 bool lockPosition, bool haptic,
                                 float posX, float posY);

// Master simulation switch (Play ▶ / Pause ⏸) shared by the Home tab and the
// floating button: updates shm interceptionActive, retries live injection into
// the selected PID and writes the extension override JSON so the VPN relay
// engine follows instantly.
void HybridHUDSetInterceptionActive(bool active);

// ── ROOT socket dump (per-PID targeting) ────────────────────────────────────
// proc_pidfdinfo on ANOTHER process requires uid 0 — the app is uid 501, so
// the dump runs in a root re-exec of this binary. Spawns
// "self -sockdump <pid> <outfile>" (persona root spawn, same proven
// mechanism as the HUD daemon) and waits ≤2s for the JSON result file:
//   [{"proto":"tcp","localPort":1,"remotePort":2,"remoteIP":"1.2.3.4"}]
// YES = file produced (parse it), NO = fall back to the in-process dump
// (directDump — possible because PrivateSystemSPI.h is imported above).
bool HybridSockDumpViaRoot(int pid, const char *outfile);
bool HybridSockDumpViaRootPID(int pid, const char *outfile, int *childPid);

#endif /* HybridBridgingHeader_h */
