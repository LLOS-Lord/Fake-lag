// main.mm - Dispatcher for Hybrid V2 with Floating Button support
// Handles: -hud (global floating button daemon), -exit (kill daemon), normal app
// Added crash logging for _UIApplicationMainPreparations SIGABRT

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Core/PersonaHelper.h"
#import "Core/PayloadBridge.h"
#import <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <stdio.h>
#include <mach-o/dyld.h>

extern "C" int HUDMain(int argc, char *argv[]);
extern BOOL gAetherIsDaemon;
BOOL gAetherIsDaemon = NO;

// Earliest possible boot marker — runs at dyld time, BEFORE main().
// The persona-root spawn proves rc=0, but rc=0 does NOT prove exec succeeded:
// a child killed by AMFI/dyld/xpc-bootstrap before main() left NO trace and
// the HUD failure was undiagnosable ("posix_spawn rc=0 → silence").
// This constructor is the first line the child can ever write. If it appears
// without the following [MAIN_CRASH_LOG] main() line → death between ctor and
// main(); if it never appears → exec-level death (entitlements/trustcache).
static __attribute__((constructor)) void AetherEarlyBootLog(void) {
    char buf[640];
    char exe[1024] = {0};
    uint32_t exeLen = sizeof(exe);
    _NSGetExecutablePath(exe, &exeLen); // best effort
    int n = snprintf(buf, sizeof(buf),
                     "[%ld] [HUD_EARLY] ctor uid=%d euid=%d pid=%d ppid=%d exe=%s\n",
                     (long)time(NULL), getuid(), geteuid(), getpid(), getppid(), exe);
    if (n > 0) {
        int fd = open("/var/mobile/Library/Caches/hybrid_actions.log",
                      O_WRONLY | O_APPEND | O_CREAT, 0666);
        if (fd >= 0) { write(fd, buf, (size_t)n); close(fd); }
    }
}

static void LogCrash(NSString *msg) {
    @try {
        NSString *path = @"/var/mobile/Library/Caches/com.aethernet.main.crash.log";
        NSString *ts = [NSDate date].description;
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        chmod(path.UTF8String, 0666);
        NSLog(@"[MAIN_CRASH_LOG] %@", msg);
    } @catch(...) {}
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // Log args
        NSMutableString *argsStr = [NSMutableString string];
        for (int i=0;i<argc;i++) [argsStr appendFormat:@"%s ", argv[i]];
        LogCrash([NSString stringWithFormat:@"main() argc=%d args=%@ executable=%s", argc, argsStr, argv[0]]);

        if (argc > 1) {
            NSString *arg1 = [NSString stringWithUTF8String:argv[1]];

            // -sockdump "<pid> <outfile>" — ROOT helper mode (per-PID targeting).
            // proc_pidfdinfo on another process needs uid 0, so the app re-execs
            // itself via the persona root spawn. No UIKit involved → fast + safe.
            if ([arg1 isEqualToString:@"-sockdump"] && argc > 2) {
                int dumpPid = 0;
                char outPath[1024] = {0};
                if (sscanf(argv[2], "%d %1023s", &dumpPid, outPath) == 2 && dumpPid > 0 && outPath[0]) {
                    int n = HybridWriteSocketDumpFile(dumpPid, outPath);
                    LogCrash([NSString stringWithFormat:@"-sockdump pid=%d → %d entries → %s (uid=%d)",
                              dumpPid, n, outPath, getuid()]);
                    return (n >= 0) ? 0 : 1;
                }
                LogCrash(@"-sockdump malformed args");
                return 2;
            }

            // -inject "<pid> <dylibPath> <outFile>" — ROOT helper mode. It does
            // task_for_pid + remote dlopen and writes a verdict file; no UIKit,
            // so it exits immediately like -sockdump.
            if ([arg1 isEqualToString:@"-inject"] && argc > 2) {
                int targetPid = 0;
                char dylibPath[1024] = {0};
                char outFile[1024] = {0};
                if (sscanf(argv[2], "%d %1023s %1023s", &targetPid, dylibPath, outFile) == 3 &&
                    targetPid > 0) {
                    int rc = HybridRunInjectHelper(targetPid, dylibPath, outFile);
                    LogCrash([NSString stringWithFormat:@"-inject pid=%d rc=%d (uid=%d)",
                              targetPid, rc, getuid()]);
                    return (rc == HybridInjectOK) ? 0 : 1;
                }
                LogCrash(@"-inject malformed args");
                return 2;
            }

            if ([arg1 isEqualToString:@"-hud"] || [arg1 isEqualToString:@"-exit"] || [arg1 isEqualToString:@"-check"]) {
                gAetherIsDaemon = YES;
                LogCrash([NSString stringWithFormat:@"Dispatching to HUDMain with arg %@", arg1]);
                int hudResult = HUDMain(argc, argv);
                if (hudResult != -1) {
                    LogCrash([NSString stringWithFormat:@"HUDMain returned %d", hudResult]);
                    return hudResult;
                }
            }
        }
        gAetherIsDaemon = NO;
        
        // Check Info.plist existence
        NSString *infoPath = [[NSBundle mainBundle] pathForResource:@"Info" ofType:@"plist"];
        LogCrash([NSString stringWithFormat:@"Info.plist path=%@ exists=%d", infoPath, [[NSFileManager defaultManager] fileExistsAtPath:infoPath]]);
        if (infoPath) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            LogCrash([NSString stringWithFormat:@"Info.plist loaded keys=%@", info.allKeys]);
        }
        
        // Check AppDelegate class existence
        Class appDelegateClass = NSClassFromString(@"AppDelegate");
        LogCrash([NSString stringWithFormat:@"AppDelegate class lookup: %@ (%@)", appDelegateClass, appDelegateClass ? @"FOUND" : @"NOT FOUND"]);
        if (!appDelegateClass) {
            // Try with module prefix
            appDelegateClass = NSClassFromString(@"PacketBlocker.AppDelegate");
            LogCrash([NSString stringWithFormat:@"PacketBlocker.AppDelegate lookup: %@", appDelegateClass]);
        }
        
        @try {
            LogCrash(@"Calling UIApplicationMain with AppDelegate");
            int ret = UIApplicationMain(argc, argv, nil, @"AppDelegate");
            LogCrash([NSString stringWithFormat:@"UIApplicationMain returned %d", ret]);
            return ret;
        } @catch (NSException *ex) {
            NSString *msg = [NSString stringWithFormat:@"EXCEPTION in UIApplicationMain: %@ reason: %@ callStack: %@", ex.name, ex.reason, ex.callStackSymbols];
            LogCrash(msg);
            // Also try with module-prefixed delegate
            @try {
                LogCrash(@"Retrying with PacketBlocker.AppDelegate");
                return UIApplicationMain(argc, argv, nil, @"PacketBlocker.AppDelegate");
            } @catch (NSException *ex2) {
                LogCrash([NSString stringWithFormat:@"Second exception: %@ %@", ex2.name, ex2.reason]);
                @throw;
            }
        }
    }
}
