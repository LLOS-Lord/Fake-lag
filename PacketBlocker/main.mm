// main.mm - Dispatcher for Hybrid V2 with Floating Button support
// Handles: -hud (global floating button daemon), -exit (kill daemon), normal app
// Added crash logging for _UIApplicationMainPreparations SIGABRT

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

extern "C" int HUDMain(int argc, char *argv[]);
extern BOOL gAetherIsDaemon;
BOOL gAetherIsDaemon = NO;

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
