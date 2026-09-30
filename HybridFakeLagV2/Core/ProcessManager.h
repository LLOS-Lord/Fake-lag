//
//  ProcessManager.h
//  AetherNet — Process Discovery, Socket Inspector & PID Injection Engine
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "../headers/AetherNetShared.h"

NS_ASSUME_NONNULL_BEGIN

@interface AetherProcessInfo : NSObject
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) pid_t ppid;
@property (nonatomic, assign) uid_t uid;
@property (nonatomic, copy) NSString *processName;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *executablePath;
@property (nonatomic, assign) BOOL isUserApp;
@property (nonatomic, assign) uint32_t tcpSocketCount;
@property (nonatomic, assign) uint32_t udpSocketCount;
@property (nonatomic, strong, nullable) UIImage *appIcon;
@end

@interface AetherProcessManager : NSObject

+ (instancetype)sharedManager;

/// Enumerates running processes (prioritizing user apps & active network processes)
- (NSArray<AetherProcessInfo *> *)enumerateRunningProcessesWithFilter:(nullable NSString *)searchQuery
                                                         onlyUserApps:(BOOL)onlyUserApps;

/// Inspects live L4 TCP/UDP file descriptors of a target PID via XNU libproc SPI
- (void)refreshSocketTelemetryForPID:(pid_t)pid;

/// Injects libNetHookPayload.dylib into target PID and binds L4 TCP/UDP hooks
- (BOOL)injectIntoProcess:(AetherProcessInfo *)processInfo
                    error:(NSError * _Nullable * _Nullable)error;

/// Detaches hooks and flushes held packet queues
- (void)detachFromCurrentProcess;

// ── ROOT socket dump (per-PID targeting) — C bridge, synced with PacketBlocker ──
// proc_pidfdinfo on another process needs uid 0; the app re-execs ITSELF as
// root ("-sockdump <pid> <outfile>") and parses the JSON result file.

// ROOT side (called from main.mm "-sockdump"). Writes the JSON result file
// (chmod 0666). Returns entry count, or <0 on failure. A valid EMPTY dump
// still writes "[]".
int HybridWriteSocketDumpFile(int pid, const char *outfile);

// APP side: spawn the root helper, wait (≤2s) for the result file.
// YES = file produced (parse it), NO = fall back to the in-process dump.
// childPid (may be NULL) receives the helper pid right after spawn.
BOOL HybridSockDumpViaRootPID(int pid, const char *outfile, int * _Nullable childPid);
BOOL HybridSockDumpViaRoot(int pid, const char *outfile);

// 0 when the pid is gone, 1 when alive, 2 when alive-but-root (EPERM).
int HybridProcIsAlive(int pid);

// In-process dump via proc_pidfdinfo (needs uid 0 to succeed; fallback path).
int HybridProcSocketDump(int pid, HybridSocketEntryC * _Nullable out, int max);


/// Spawns or terminates the global root Floating HUD Button daemon
- (void)setGlobalFloatingHUDEnabled:(BOOL)enabled;
- (BOOL)isGlobalFloatingHUDRunning;

/// Toggles active packet interception (Play ▶ <-> Pause ⏸)
- (void)setInterceptionActive:(BOOL)active;

@end

NS_ASSUME_NONNULL_END
