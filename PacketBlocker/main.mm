// main.mm - Dispatcher for Hybrid V2 with Floating Button support
// Handles: -hud (global floating button daemon), -exit (kill daemon), normal app

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern "C" int HUDMain(int argc, char *argv[]);
extern BOOL gAetherIsDaemon;
BOOL gAetherIsDaemon = NO;

// Forward declare AppDelegate from Swift (we will have @objc class AppDelegate)
int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1) {
            NSString *arg1 = [NSString stringWithUTF8String:argv[1]];
            if ([arg1 isEqualToString:@"-hud"] || [arg1 isEqualToString:@"-exit"] || [arg1 isEqualToString:@"-check"]) {
                gAetherIsDaemon = YES;
                int hudResult = HUDMain(argc, argv);
                if (hudResult != -1) {
                    return hudResult;
                }
            }
        }
        gAetherIsDaemon = NO;
        // Normal app launch - use AppDelegate (Swift)
        return UIApplicationMain(argc, argv, nil, @"AppDelegate");
    }
}
