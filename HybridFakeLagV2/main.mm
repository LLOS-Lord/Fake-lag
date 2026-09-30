// main.mm - Single binary dispatcher for HybridFakeLag V2
// (no args) -> SwiftUI app
// -hud      -> HUD daemon (global floating button)
// -exit     -> kill HUD daemon
// -check    -> check HUD alive

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern "C" int HUDMain(int argc, char *argv[]);
extern BOOL gAetherIsDaemon;

int main(int argc, char *argv[]) {
    @autoreleasepool {
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
