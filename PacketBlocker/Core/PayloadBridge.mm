//
//  PayloadBridge.mm
//  App side of the injected-payload control channel + Mach injector.
//
#import <Foundation/Foundation.h>
#import "PayloadBridge.h"
#import "PersonaHelper.h"
#import "AetherNetShared.h"

#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>

// ============================================================================
// 1. Root helper — remote dlopen
// ============================================================================

// Success is decided by the payload's own socket appearing, not by "the thread
// started": dlopen can still fail (missing dylib, unsigned dylib, library
// validation) long after thread_create_running returned KERN_SUCCESS.
static NSString *FindPayloadSocketPath(int pid) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @AETHER_IPC_DATA_ROOT;
    NSArray<NSString *> *containers = [fm contentsOfDirectoryAtPath:root error:nil];
    NSString *leaf = [NSString stringWithFormat:@"aether_net_%d.sock", pid];
    for (NSString *c in containers) {
        NSString *candidate = [root stringByAppendingPathComponent:
            [c stringByAppendingPathComponent:[@"tmp" stringByAppendingPathComponent:leaf]]];
        if ([fm fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

static int AetherDoRemoteInject(int pid, const char *dylibPath,
                                char *detail, size_t detailLen) {
    // NOTE: Objective-C++ forbids `goto` that jumps over an initialised local,
    // so every early exit is a `break` out of this do-block and all cleanup
    // happens in one place afterwards.
    int rc = HybridInjectNotAttempted;
    mach_port_t task = MACH_PORT_NULL;
    mach_port_t thread = MACH_PORT_NULL;

    do {
        if (pid <= 1) {
            snprintf(detail, detailLen, "bad pid %d", pid);
            break;
        }
        if (!dylibPath || access(dylibPath, R_OK) != 0) {
            snprintf(detail, detailLen, "dylib unreadable: %s", dylibPath ?: "(null)");
            rc = HybridInjectDylibMissing;
            break;
        }
        // The dylib must be readable by the TARGET's uid, not just by root.
        chmod(dylibPath, 0755);

        if (task_for_pid(mach_task_self(), (pid_t)pid, &task) != KERN_SUCCESS ||
            !MACH_PORT_VALID(task)) {
            snprintf(detail, detailLen,
                     "task_for_pid(%d) denied — needs root AND a CS_DEBUGGED/PPL-bypassed target", pid);
            rc = HybridInjectNoTaskPort;
            break;
        }

        // One page of stack, one page for the path, plus a park stub.
        mach_vm_address_t remoteStack = 0, remotePath = 0;
        if (mach_vm_allocate(task, &remoteStack, 0x4000, VM_FLAGS_ANYWHERE) != KERN_SUCCESS ||
            mach_vm_allocate(task, &remotePath, 0x1000, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
            snprintf(detail, detailLen, "mach_vm_allocate failed");
            rc = HybridInjectAllocFailed;
            break;
        }

        // The remote thread returns here after dlopen. The old injector left
        // __lr at 0, so the target died with EXC_BAD_ACCESS on return.
        uint32_t parkInsn = 0x14000000u;   // b .
        if (mach_vm_write(task, remoteStack, (vm_offset_t)&parkInsn, 4) != KERN_SUCCESS ||
            mach_vm_write(task, remotePath, (vm_offset_t)dylibPath,
                          (mach_msg_type_number_t)strlen(dylibPath) + 1) != KERN_SUCCESS) {
            snprintf(detail, detailLen, "mach_vm_write failed");
            rc = HybridInjectAllocFailed;
            break;
        }

        // The dyld shared cache is mapped at the same slide in every process of
        // a boot session, so our dlopen address is the target's dlopen address.
        void *dlopenAddr = dlsym(RTLD_DEFAULT, "dlopen");
        if (!dlopenAddr) {
            snprintf(detail, detailLen, "dlopen symbol not found");
            rc = HybridInjectThreadFailed;
            break;
        }

#if defined(__arm64__) || defined(__aarch64__)
        arm_thread_state64_t st;
        memset(&st, 0, sizeof(st));
        st.__x[0] = (uint64_t)remotePath;
        st.__x[1] = (uint64_t)RTLD_NOW;
        st.__sp   = (uint64_t)(remoteStack + 0x2000);
        st.__pc   = (uint64_t)dlopenAddr;
        st.__lr   = (uint64_t)remoteStack;      // park stub

        if (thread_create_running(task, ARM_THREAD_STATE64, (thread_state_t *)&st,
                                  ARM_THREAD_STATE64_COUNT, &thread) != KERN_SUCCESS) {
            snprintf(detail, detailLen,
                     "thread_create_running refused (target is not CS_DEBUGGED — PPL/PAC)");
            rc = HybridInjectThreadFailed;
            break;
        }

        // Success = the payload's own IPC socket appeared. "The thread started"
        // is not evidence: dlopen can still fail afterwards.
        NSString *sockPath = nil;
        for (int i = 0; i < 60 && !sockPath; i++) {
            sockPath = FindPayloadSocketPath(pid);
            if (!sockPath) usleep(50 * 1000);
        }
        if (sockPath) {
            rc = HybridInjectOK;
            snprintf(detail, detailLen, "armed, ipc=%s", sockPath.UTF8String);
        } else {
            rc = HybridInjectLibValidation;
            snprintf(detail, detailLen,
                     "dlopen thread ran but no IPC socket appeared (dylib unsigned / "
                     "library validation / no hook engine) — see the target's "
                     "tmp/aether_net_%d.log", pid);
        }
#else
        snprintf(detail, detailLen, "unsupported architecture");
        rc = HybridInjectThreadFailed;
#endif
    } while (0);

    // Never leave a thread parked inside the target.
    if (MACH_PORT_VALID(thread)) {
        thread_terminate(thread);
        mach_port_deallocate(mach_task_self(), thread);
    }
    if (MACH_PORT_VALID(task)) mach_port_deallocate(mach_task_self(), task);
    return rc;
}

int HybridRunInjectHelper(int pid, const char *dylibPath, const char *outFile) {
    char detail[256] = {0};
    int rc = AetherDoRemoteInject(pid, dylibPath, detail, sizeof(detail));
    if (outFile) {
        FILE *f = fopen(outFile, "w");
        if (f) { fprintf(f, "%d\n%s\n", rc, detail); fclose(f); chmod(outFile, 0666); }
    }
    fprintf(stderr, "[inject] rc=%d %s\n", rc, detail);
    return rc;
}

// ============================================================================
// 2. App side driver
// ============================================================================

static int    gClientFd  = -1;
static int    gClientPid = 0;
static char   gSockPath[512] = {0};
static uint32_t gSeq = 0;

const char *HybridInjectResultString(int rc) {
    switch (rc) {
        case HybridInjectOK:           return "injected";
        case HybridInjectNoTaskPort:   return "task_for_pid denied";
        case HybridInjectAllocFailed:  return "remote alloc failed";
        case HybridInjectThreadFailed: return "remote thread refused (PPL/CS_DEBUGGED)";
        case HybridInjectDylibMissing: return "payload dylib missing";
        case HybridInjectSpawnFailed:  return "root helper spawn failed";
        case HybridInjectTimeout:      return "helper timed out";
        case HybridInjectHelperFailed: return "root helper failed";
        case HybridInjectLibValidation:return "dlopen ran but payload did not arm";
        default:                       return "not attempted";
    }
}

int HybridPayloadInject(int pid, char *errOut, int errOutLen) {
    if (errOut && errOutLen > 0) errOut[0] = '\0';
    if (pid <= 1) return HybridInjectNotAttempted;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundled = [[NSBundle mainBundle] pathForResource:@"libNetHookPayload"
                                                        ofType:@"dylib"];
    if (!bundled) {
        if (errOut) snprintf(errOut, errOutLen, "libNetHookPayload.dylib not in bundle");
        return HybridInjectDylibMissing;
    }

    NSString *staged = @"/var/mobile/Library/Caches/libNetHookPayload.dylib";
    [fm removeItemAtPath:staged error:nil];
    if (![fm copyItemAtPath:bundled toPath:staged error:nil]) {
        if (errOut) snprintf(errOut, errOutLen, "cannot stage payload to %@", staged);
        return HybridInjectDylibMissing;
    }
    chmod(staged.fileSystemRepresentation, 0755);

    NSString *outFile = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"aether_inject_%d.txt", pid]];
    [fm removeItemAtPath:outFile error:nil];

    uint32_t exeLen = 0;
    _NSGetExecutablePath(NULL, &exeLen);
    char *exePath = (char *)calloc(1, exeLen + 1);
    _NSGetExecutablePath(exePath, &exeLen);

    int childPid = 0;
    NSString *args = [NSString stringWithFormat:@"%d %s %s", pid,
                      staged.fileSystemRepresentation, outFile.fileSystemRepresentation];
    int spawnRC = HybridSpawnRootPID(exePath, "-inject", args.UTF8String, &childPid);
    free(exePath);

    if (spawnRC != 0) {
        if (errOut) snprintf(errOut, errOutLen, "root helper spawn failed (%d)", spawnRC);
        return HybridInjectSpawnFailed;
    }

    int rc = HybridInjectHelperFailed;
    for (int i = 0; i < 80; i++) {                     // ≤4 s
        NSString *text = [NSString stringWithContentsOfFile:outFile
                                                  encoding:NSUTF8StringEncoding error:nil];
        if (text.length > 0) {
            NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
            rc = [lines.firstObject intValue];
            if (errOut && lines.count > 1)
                snprintf(errOut, errOutLen, "%s", lines[1].UTF8String);
            break;
        }
        usleep(50 * 1000);
    }
    if (rc == HybridInjectHelperFailed && errOut) {
        snprintf(errOut, errOutLen, "root helper produced no result (pid %d)", childPid);
    }
    [fm removeItemAtPath:outFile error:nil];
    return rc;
}

// ── Control channel ─────────────────────────────────────────────────────────
void HybridPayloadDetach(void) {
    if (gClientFd >= 0) { close(gClientFd); gClientFd = -1; }
    if (gSockPath[0]) { unlink(gSockPath); gSockPath[0] = '\0'; }
    gClientPid = 0;
}

int HybridPayloadIsAttached(void) { return gClientFd >= 0 ? 1 : 0; }

int HybridPayloadAttach(int pid) {
    if (gClientFd >= 0 && gClientPid == pid) return 1;
    HybridPayloadDetach();

    NSString *path = FindPayloadSocketPath(pid);
    if (!path) return 0;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return 0; }

    gClientFd = fd;
    gClientPid = pid;
    strlcpy(gSockPath, path.fileSystemRepresentation, sizeof(gSockPath));
    return 1;
}

int HybridPayloadSendConfig(int enabled, int targetPID, const char *bundleID,
                            int direction, int protocolFilter, int mode,
                            int captureRatio, int latencyMs, int jitterMs,
                            int autoFlushSeconds) {
    if (gClientFd < 0) return 0;
    AetherIpcConfig c;
    memset(&c, 0, sizeof(c));
    c.magic = AETHER_IPC_MAGIC;
    c.version = AETHER_IPC_VERSION;
    c.seq = ++gSeq;
    c.targetPID = targetPID;
    c.bundleHash = bundleID ? HybridBundleHash(bundleID) : 0;
    c.enabled = enabled ? 1u : 0u;
    c.direction = (uint32_t)direction;
    c.protocolFilter = (uint32_t)protocolFilter;
    c.mode = (uint32_t)mode;
    c.captureRatio = (uint32_t)captureRatio;
    c.latencyMs = (uint32_t)latencyMs;
    c.jitterMs = (uint32_t)jitterMs;
    c.autoFlushSeconds = (uint32_t)autoFlushSeconds;
    ssize_t w = send(gClientFd, &c, sizeof(c), MSG_NOSIGNAL);
    return w == (ssize_t)sizeof(c);
}

int HybridPayloadPoll(AetherIpcTelemetry *out) {
    if (gClientFd < 0 || !out) return 0;
    AetherIpcTelemetry t;
    ssize_t r = recv(gClientFd, &t, sizeof(t), MSG_DONTWAIT);
    if (r != (ssize_t)sizeof(t)) return 0;
    if (t.magic != AETHER_IPC_MAGIC || t.version != AETHER_IPC_VERSION) return 0;
    *out = t;
    return 1;
}

uint32_t HybridBundleHash(const char *s) { return AetherBundleHash(s); }

void HybridPayloadSetTarget(int pid, const char *bundleID) {
    AetherSharedState *st = AetherGetSharedState();
    if (!st) return;
    aether_atomic_store(&st->targetPID, (pid_t)pid);
    if (bundleID) {
        strlcpy(st->targetBundleID, bundleID, sizeof(st->targetBundleID));
        strlcpy(st->targetProcessName, bundleID, sizeof(st->targetProcessName));
    }
    st->socketEntryCount = 0;
}