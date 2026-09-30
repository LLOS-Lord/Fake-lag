import UIKit
import SwiftUI

@objc(AppDelegate)
public class AppDelegate: UIResponder, UIApplicationDelegate {
    public var window: UIWindow?
    
    public func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        NSLog("[AppDelegate] didFinishLaunching - creating window")
        do {
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.backgroundColor = .black
            let contentView = ContentView()
            let hosting = UIHostingController(rootView: contentView)
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            self.window = window
            NSLog("[AppDelegate] window created OK")
        } catch {
            NSLog("[AppDelegate] exception creating window: %@", error.localizedDescription)
        }
        // Defer logging to avoid crash in early launch
        DispatchQueue.main.asyncAfter(deadline: .now()+1.0) {
            AppGroupStore.logAction("APP_LAUNCH", details: "Hybrid V2 main.mm active")
        }
        return true
    }
    
    public func applicationDidEnterBackground(_ application: UIApplication) {
        // No logging here to avoid crash
    }
    
    public func applicationWillEnterForeground(_ application: UIApplication) {
    }
}
