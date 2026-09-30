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

extern "C" int HUDMain(int argc, char *argv[]);
extern "C" int HybridWriteSocketDumpFile(int pid, const char *outfile);
extern BOOL gAetherIsDaemon;

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

