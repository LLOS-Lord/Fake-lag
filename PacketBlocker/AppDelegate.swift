import UIKit
import SwiftUI

@objc class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        // Host SwiftUI ContentView
        let contentView = ContentView()
        window.rootViewController = UIHostingController(rootView: contentView)
        window.makeKeyAndVisible()
        self.window = window
        
        // Ensure App Group container exists and log
        AppGroupStore.logAction("APP_LAUNCH", details: "Hybrid V2 with Floating Button - main.mm dispatcher active")
        
        // Ensure shared memory init
        // Call AetherGetSharedState via ObjC bridge if available
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        AppGroupStore.logAction("APP_BACKGROUND", details: "")
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        AppGroupStore.logAction("APP_FOREGROUND", details: "")
    }
}
