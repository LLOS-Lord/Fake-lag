// main.mm - Single binary dispatcher for HybridFakeLag V2
// (no args)  -> SwiftUI app
// -hud       -> HUD daemon (global floating button)
// -exit      -> kill HUD daemon
// -check     -> check HUD alive
// -sockdump  -> ROOT helper: dump a pid's live sockets to a JSON file
//               (arg2 = "<pid> <outfile>"), then exit. No UIKit involved.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <mach-o/dyld.h>

extern "C" int HUDMain(int argc, char *argv[]);
extern "C" int HybridWriteSocketDumpFile(int pid, const char *outfile);
extern BOOL gAetherIsDaemon;

// Earliest possible boot marker — runs at dyld time, BEFORE main().
// posix_spawn rc=0 does NOT prove exec succeeded; a child killed by
// AMFI/dyld/xpc-bootstrap before main() used to leave NO trace. This ctor is
// the first line the child can ever write (synced with PacketBlocker/main.mm).
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

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 2 && strcmp(argv[1], "-sockdump") == 0) {
            // Root helper mode — parse "<pid> <outfile>" and write the dump.
            int dumpPid = 0;
            char outPath[1024] = {0};
            if (sscanf(argv[2], "%d %1023s", &dumpPid, outPath) == 2 && dumpPid > 0 && outPath[0]) {
                int n = HybridWriteSocketDumpFile(dumpPid, outPath);
                return (n >= 0) ? 0 : 1;
            }
            return 2;
        }
        if (argc > 1) {
            gAetherIsDaemon = YES;
            int hudResult = HUDMain(argc, argv);
            if (hudResult != -1) {
                return hudResult;
            }
        }
        gAetherIsDaemon = NO;
        // Normal app - use AppDelegate which hosts SwiftUI ContentView
        // Need to import Swift bridging header for AppDelegate
        return UIApplicationMain(argc, argv, nil, @"AppDelegate");
    }
}

