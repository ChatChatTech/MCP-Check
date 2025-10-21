import SwiftUI
import os.log

@main
struct MCPSnitchApp: App {
    @StateObject private var menuBarController = MenuBarController()
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "App")
    private let guardRailsManager = GuardRailsManager.shared  // Initialize at app startup
    
    init() {
        logger.info("MCPSnitch starting up...")
        setupExceptionHandling()
        
        // Prevent app from terminating when windows close
        // This is important for menu bar apps
        NSApplication.shared.setActivationPolicy(.accessory)
        
        // Initialize GuardRailsManager to ensure notification observers are registered
        logger.info("Initializing GuardRailsManager...")
        _ = guardRailsManager  // Ensure it's created
        
        // Schedule initial server scan after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NotificationCenter.default.post(name: Notification.Name("PerformInitialServerScan"), object: nil)
        }
    }
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
    
    private func setupExceptionHandling() {
        NSSetUncaughtExceptionHandler { exception in
            let logger = Logger(subsystem: "com.MCPSnitch", category: "CrashHandler")
            logger.critical("Uncaught exception: \(exception.reason ?? "Unknown")")
            logger.critical("Stack trace: \(exception.callStackSymbols.joined(separator: "\n"))")
            
            // Don't terminate the app - just log and continue
            // This prevents the app from exiting on non-fatal exceptions
            print("MCPSnitch Exception: \(exception.reason ?? "Unknown")")
            print("Stack trace: \(exception.callStackSymbols)")
        }
    }
}