import SwiftUI

// SwiftUI App entry for normal mode (called from main.mm via AppDelegate)
struct HybridApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// For main.mm compatibility, we need UIKit AppDelegate that hosts SwiftUI
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: ContentView())
        window.makeKeyAndVisible()
        self.window = window
        // Log
        AppGroupStore.logAction("APP_LAUNCH", details: "Hybrid V2 launched")
        return true
    }
}
