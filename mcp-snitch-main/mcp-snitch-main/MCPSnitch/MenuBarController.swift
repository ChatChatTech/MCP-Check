import SwiftUI
import AppKit
import os.log

class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private let serverScanner = ServerScanner()
    private let serverManager = ServerManager()
    private let securityTools = SecurityTools()
    private let configManager = ConfigurationManager()
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "MenuBar")
    private var guardRailsWindow: NSWindow?
    private var configWindow: NSWindow?
    private var trustedServersWindow: NSWindow?
    private var apiKeysWindow: NSWindow?
    private var proxyMonitorWindows: [String: NSWindow] = [:]
    
    @Published var servers: [MCPServer] = []
    
    init() {
        setupMenuBar()
        
        // Listen for initial scan request
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(performInitialScan),
            name: Notification.Name("PerformInitialServerScan"),
            object: nil
        )
    }
    
    @objc private func performInitialScan() {
        logger.info("Performing automatic initial server scan...")
        Task {
            await MainActor.run {
                servers = serverScanner.scanForServers()
                buildMenu()
                logger.info("Initial scan complete: found \(self.servers.count) server(s)")
            }
        }
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "MCP Snitch")
            button.image?.isTemplate = true
        }
        
        menu = NSMenu()
        statusItem?.menu = menu
        
        buildMenu()
    }
    
    private func buildMenu() {
        guard let menu = menu else { return }
        menu.removeAllItems()
        
        let scanItem = NSMenuItem(title: "Scan Servers", action: #selector(scanServers), keyEquivalent: "")
        scanItem.target = self
        menu.addItem(scanItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let serversMenuItem = NSMenuItem(title: "Servers", action: nil, keyEquivalent: "")
        let serversSubmenu = NSMenu()
        
        if servers.isEmpty {
            let emptyItem = NSMenuItem(title: "No servers found", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            serversSubmenu.addItem(emptyItem)
        } else {
            for server in servers {
                var serverTitle = server.name
                if serverManager.isServerTrusted(server) {
                    serverTitle += " ✓"
                }
                if serverManager.isServerProtected(server.name) {
                    serverTitle += " 🔒"
                }
                
                let serverItem = NSMenuItem(title: serverTitle, action: nil, keyEquivalent: "")
                let serverSubmenu = NSMenu()
                
                let trustItem = NSMenuItem(
                    title: serverManager.isServerTrusted(server) ? "Untrust" : "Trust",
                    action: #selector(toggleTrust(_:)),
                    keyEquivalent: ""
                )
                trustItem.target = self
                trustItem.representedObject = server
                serverSubmenu.addItem(trustItem)
                
                let removeItem = NSMenuItem(title: "Remove", action: #selector(removeServer(_:)), keyEquivalent: "")
                removeItem.target = self
                removeItem.representedObject = server
                serverSubmenu.addItem(removeItem)
                
                let protectItem = NSMenuItem(
                    title: serverManager.isServerProtected(server.name) ? "Unprotect" : "Protect",
                    action: #selector(toggleProtection(_:)),
                    keyEquivalent: ""
                )
                protectItem.target = self
                protectItem.representedObject = server
                serverSubmenu.addItem(protectItem)
                
                // Add GuardRails trust options
                serverSubmenu.addItem(NSMenuItem.separator())
                
                let guardRailsManager = GuardRailsManager.shared
                let isTrustedForTools = guardRailsManager.isServerTrusted(server.name)
                let isBlockedForTools = guardRailsManager.isServerBlocked(server.name)
                
                if isBlockedForTools {
                    let unblockItem = NSMenuItem(
                        title: "Unblock All Tools ✅",
                        action: #selector(unblockAllTools(_:)),
                        keyEquivalent: ""
                    )
                    unblockItem.target = self
                    unblockItem.representedObject = server
                    serverSubmenu.addItem(unblockItem)
                } else if isTrustedForTools {
                    let blockItem = NSMenuItem(
                        title: "Block All Tools 🚫",
                        action: #selector(blockAllTools(_:)),
                        keyEquivalent: ""
                    )
                    blockItem.target = self
                    blockItem.representedObject = server
                    serverSubmenu.addItem(blockItem)
                } else {
                    let trustToolsItem = NSMenuItem(
                        title: "Trust All Tools ✅",
                        action: #selector(trustAllTools(_:)),
                        keyEquivalent: ""
                    )
                    trustToolsItem.target = self
                    trustToolsItem.representedObject = server
                    serverSubmenu.addItem(trustToolsItem)
                    
                    let blockToolsItem = NSMenuItem(
                        title: "Block All Tools 🚫",
                        action: #selector(blockAllTools(_:)),
                        keyEquivalent: ""
                    )
                    blockToolsItem.target = self
                    blockToolsItem.representedObject = server
                    serverSubmenu.addItem(blockToolsItem)
                }
                
                // Add monitor option if server is protected
                if serverManager.isServerProtected(server.name) {
                    serverSubmenu.addItem(NSMenuItem.separator())
                    let monitorItem = NSMenuItem(title: "Monitor Traffic", action: #selector(openProxyMonitor(_:)), keyEquivalent: "")
                    monitorItem.target = self
                    monitorItem.representedObject = server
                    serverSubmenu.addItem(monitorItem)
                }
                
                serverItem.submenu = serverSubmenu
                serversSubmenu.addItem(serverItem)
            }
        }
        
        serversMenuItem.submenu = serversSubmenu
        menu.addItem(serversMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let securityMenuItem = NSMenuItem(title: "Security Tools", action: nil, keyEquivalent: "")
        let securitySubmenu = NSMenu()
        
        let trustedServersItem = NSMenuItem(title: "View Trusted Servers", action: #selector(viewTrustedServers), keyEquivalent: "")
        trustedServersItem.target = self
        securitySubmenu.addItem(trustedServersItem)
        
        let guardrailsItem = NSMenuItem(title: "Configure Guard Rails", action: #selector(configureGuardRails), keyEquivalent: "")
        guardrailsItem.target = self
        securitySubmenu.addItem(guardrailsItem)
        
        securitySubmenu.addItem(NSMenuItem.separator())
        
        let apiKeysItem = NSMenuItem(title: "API Keys Management 🔐", action: #selector(openAPIKeysManagement), keyEquivalent: "K")
        apiKeysItem.target = self
        securitySubmenu.addItem(apiKeysItem)
        
        securityMenuItem.submenu = securitySubmenu
        menu.addItem(securityMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let configItem = NSMenuItem(title: "Config", action: #selector(openConfiguration), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    @objc private func scanServers() {
        Task {
            await MainActor.run {
                servers = serverScanner.scanForServers()
                buildMenu()
                
                let alert = NSAlert()
                alert.messageText = "Scan Complete"
                alert.informativeText = "Found \(servers.count) MCP server(s)"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
    
    @objc private func toggleTrust(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? MCPServer else { return }
        
        if serverManager.isServerTrusted(server) {
            serverManager.untrustServer(server)
            let alert = NSAlert()
            alert.messageText = "Server Untrusted"
            alert.informativeText = "\(server.name) has been removed from trusted servers"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            serverManager.trustServer(server)
            let alert = NSAlert()
            alert.messageText = "Server Trusted"
            alert.informativeText = "\(server.name) has been added to trusted servers"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        
        buildMenu()
    }
    
    @objc private func removeServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? MCPServer else { return }
        
        let alert = NSAlert()
        alert.messageText = "Remove Server?"
        alert.informativeText = "Are you sure you want to remove \(server.name) from its configuration?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            serverManager.removeServer(server)
            servers.removeAll { $0.id == server.id }
            buildMenu()
        }
    }
    
    @objc private func trustAllTools(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? MCPServer else { return }
        
        GuardRailsManager.shared.trustAllToolsFromServer(server.name)
        
        let alert = NSAlert()
        alert.messageText = "Server Trusted"
        alert.informativeText = "All tools from \(server.name) are now trusted and will be allowed without prompting."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        
        buildMenu()
    }
    
    @objc private func blockAllTools(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? MCPServer else { return }
        
        GuardRailsManager.shared.blockAllToolsFromServer(server.name)
        
        let alert = NSAlert()
        alert.messageText = "Server Blocked"
        alert.informativeText = "All tools from \(server.name) are now blocked."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        
        buildMenu()
    }
    
    @objc private func unblockAllTools(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? MCPServer else { return }
        
        // Remove from blacklist
        GuardRailsManager.shared.blacklistedTools = GuardRailsManager.shared.blacklistedTools.filter { 
            $0.serverName != server.name 
        }
        GuardRailsManager.shared.saveConfiguration()
        
        let alert = NSAlert()
        alert.messageText = "Server Unblocked"
        alert.informativeText = "\(server.name) is no longer blocked. Tools will follow normal approval rules."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        
        buildMenu()
    }
    
    @objc private func toggleProtection(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? MCPServer else { return }
        
        if serverManager.isServerProtected(server.name) {
            serverManager.unprotectServer(server)
            let alert = NSAlert()
            alert.messageText = "Server Unprotected"
            alert.informativeText = "\(server.name) is no longer protected"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            // Check if it's protectable first
            if !serverManager.canProtectServer(server) {
                let alert = NSAlert()
                alert.messageText = "Cannot Protect Server"
                alert.informativeText = "\(server.name) cannot be protected. Server must have either a 'command', 'stdio', or 'url' configuration."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            serverManager.protectServer(server)
            
            // Check if protection was successful
            if serverManager.isServerProtected(server.name) {
                let alert = NSAlert()
                alert.messageText = "Server Protected"
                alert.informativeText = "\(server.name) is now protected and will be monitored"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        
        buildMenu()
    }
    
    @objc private func viewTrustedServers() {
        logger.info("Opening trusted servers window")
        
        // Close existing window if it exists
        if trustedServersWindow?.isVisible == true {
            trustedServersWindow?.close()
            trustedServersWindow = nil
        }
        
        // Create new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Trusted MCP Servers"
        window.center()
        
        let trustedServersView = TrustedServersView()
        let hostingController = NSHostingController(rootView: trustedServersView)
        window.contentViewController = hostingController
        
        // Store reference and show window
        trustedServersWindow = window
        window.makeKeyAndOrderFront(nil)
        
        // Ensure window is released when closed
        window.isReleasedWhenClosed = false
    }
    
    @objc private func configureGuardRails() {
        logger.info("Opening Guard Rails configuration window")
        
        // Close existing window if it exists
        if guardRailsWindow?.isVisible == true {
            guardRailsWindow?.close()
            guardRailsWindow = nil
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 750),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Configure Guard Rails"
        window.center()
        
        let guardRailsView = GuardRailsView()
        
        let hostingController = NSHostingController(rootView: guardRailsView)
        window.contentViewController = hostingController
        
        guardRailsWindow = window
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        
        logger.info("Guard Rails window opened successfully")
    }
    
    
    @objc private func openAPIKeysManagement() {
        logger.info("Opening API Keys Management...")
        
        // Close existing window if it exists
        if apiKeysWindow?.isVisible == true {
            apiKeysWindow?.close()
            apiKeysWindow = nil
        }
        
        // Create new window with proper size
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "API Keys Management"
        window.center()
        
        // For now, use inline implementation since view file not in project
        let apiKeysView = APIKeysInlineView()
            .frame(minWidth: 700, idealWidth: 800, maxWidth: .infinity,
                   minHeight: 600, idealHeight: 700, maxHeight: .infinity)
        let hostingController = NSHostingController(rootView: apiKeysView)
        window.contentViewController = hostingController
        
        // Set minimum window size
        window.minSize = NSSize(width: 700, height: 600)
        
        // Store reference and show window
        apiKeysWindow = window
        window.makeKeyAndOrderFront(nil)
        
        // Ensure window is released when closed
        window.isReleasedWhenClosed = false
    }
    
    @objc private func protectAPIKeys() {
        logger.info("Scanning for API keys in config...")
        
        // Create scanner (inline implementation for now)
        let configPath = NSHomeDirectory() + "/Library/Application Support/Claude/claude_desktop_config.json"
        
        // Check if config exists
        guard FileManager.default.fileExists(atPath: configPath) else {
            let alert = NSAlert()
            alert.messageText = "Config Not Found"
            alert.informativeText = "Could not find Claude configuration file at:\n\(configPath)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        
        // Read and parse config
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            let alert = NSAlert()
            alert.messageText = "Config Read Error"
            alert.informativeText = "Failed to read Claude configuration file"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        
        // Scan for API keys
        var detectedKeys: [(server: String, key: String, value: String, keychainName: String)] = []
        
        if let mcpServers = config["mcpServers"] as? [String: Any] {
            for (serverName, serverConfig) in mcpServers {
                if let serverDict = serverConfig as? [String: Any],
                   let env = serverDict["env"] as? [String: String] {
                    
                    for (envKey, envValue) in env {
                        // Skip if already using keychain
                        if envValue.contains("${KEYCHAIN:") {
                            continue
                        }
                        
                        // Check if it looks like an API key
                        if looksLikeAPIKey(key: envKey, value: envValue) {
                            let keychainName = "\(serverName)_\(envKey.lowercased())"
                                .replacingOccurrences(of: "_", with: "-")
                            detectedKeys.append((serverName, envKey, envValue, keychainName))
                        }
                    }
                }
            }
        }
        
        // Show results
        if detectedKeys.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No API Keys Found"
            alert.informativeText = "Great! No plaintext API keys were found in your configuration.\n\nAll sensitive values appear to be already protected."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            let alert = NSAlert()
            alert.messageText = "Found \(detectedKeys.count) API Keys"
            
            var keysList = "The following API keys were found in plaintext:\n\n"
            for key in detectedKeys {
                let maskedValue = String(key.value.prefix(6)) + "..." + String(key.value.suffix(4))
                keysList += "• \(key.server): \(key.key) = \(maskedValue)\n"
            }
            keysList += "\nWould you like to automatically move these to the Keychain?"
            
            alert.informativeText = keysList
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Protect Keys")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                protectDetectedKeys(detectedKeys, configPath: configPath)
            }
        }
    }
    
    private func looksLikeAPIKey(key: String, value: String) -> Bool {
        // Check key name
        let keyIndicators = ["key", "token", "secret", "password", "auth", "api", "credential"]
        let lowercaseKey = key.lowercased()
        for indicator in keyIndicators {
            if lowercaseKey.contains(indicator) && value.count > 10 {
                return true
            }
        }
        
        // Check value patterns
        let patterns = [
            "^sk-[a-zA-Z0-9]{48}",  // OpenAI
            "^ghp_[a-zA-Z0-9]{36}",  // GitHub PAT
            "^github_pat_",          // New GitHub format
            "^xox[bp]-",             // Slack
            "^[a-f0-9]{32,64}$"      // Generic hex
        ]
        
        for pattern in patterns {
            if value.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        return false
    }
    
    private func protectDetectedKeys(_ keys: [(server: String, key: String, value: String, keychainName: String)], configPath: String) {
        // Create backup
        let backupPath = configPath + ".backup.\(Int(Date().timeIntervalSince1970))"
        do {
            try FileManager.default.copyItem(atPath: configPath, toPath: backupPath)
            logger.info("Created backup at: \(backupPath)")
        } catch {
            logger.error("Failed to create backup: \(error)")
        }
        
        // Store keys in keychain
        var successCount = 0
        for key in keys {
            if storeInKeychain(name: key.keychainName, value: key.value) {
                successCount += 1
                logger.info("Stored \(key.key) in keychain as \(key.keychainName)")
            }
        }
        
        // Update config file
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              var config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              var mcpServers = config["mcpServers"] as? [String: Any] else {
            return
        }
        
        // Replace values with keychain references
        for key in keys {
            if var serverConfig = mcpServers[key.server] as? [String: Any],
               var env = serverConfig["env"] as? [String: String] {
                env[key.key] = "${KEYCHAIN:\(key.keychainName)}"
                serverConfig["env"] = env
                mcpServers[key.server] = serverConfig
            }
        }
        
        config["mcpServers"] = mcpServers
        
        // Write updated config
        do {
            let updatedData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
            try updatedData.write(to: URL(fileURLWithPath: configPath))
            
            let alert = NSAlert()
            alert.messageText = "API Keys Protected!"
            alert.informativeText = """
            Successfully protected \(successCount) API key(s).
            
            • Keys have been moved to macOS Keychain
            • Config file updated with secure references
            • Backup created at: \(backupPath.split(separator: "/").last ?? "")
            
            Your API keys are now secure! 🔐
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Great!")
            alert.runModal()
        } catch {
            logger.error("Failed to update config: \(error)")
        }
    }
    
    private func storeInKeychain(name: String, value: String) -> Bool {
        let service = "com.MCPSnitch.APIKeys"
        
        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: value.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }
    
    @objc private func openConfiguration() {
        logger.info("Opening Configuration window")
        
        // Close existing window if it exists
        if configWindow?.isVisible == true {
            configWindow?.close()
            configWindow = nil
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "MCP Configuration"
        window.center()
        
        let configView = ConfigurationView(
            configManager: configManager,
            windowRef: window
        )
        
        let hostingController = NSHostingController(rootView: configView)
        window.contentViewController = hostingController
        
        configWindow = window
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        
        logger.info("Configuration window opened successfully")
    }
    
    @objc private func openProxyMonitor(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? MCPServer else { return }
        
        logger.info("Opening proxy monitor for server: \(server.name)")
        
        // Close existing window if it exists
        if let existingWindow = proxyMonitorWindows[server.name], existingWindow.isVisible {
            existingWindow.close()
        }
        
        // Create new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "MCP Traffic Monitor - \(server.name)"
        window.center()
        
        let monitorView = ProxyMonitorView(serverName: server.name)
        let hostingController = NSHostingController(rootView: monitorView)
        window.contentViewController = hostingController
        
        // Store reference and show window
        proxyMonitorWindows[server.name] = window
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

struct MCPServer: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let configFile: String
    var isTrusted: Bool = false
    var isProtected: Bool = false
}

struct GuardRailsConfigView: View {
    @ObservedObject var securityTools: SecurityTools
    @State private var apiKey = ""
    @State private var selectedProvider = "OpenAI"
    @State private var customPrompt = ""
    
    let providers = ["OpenAI", "Anthropic", "Custom"]
    weak var windowRef: NSWindow?
    
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "GuardRailsView")
    
    init(securityTools: SecurityTools, windowRef: NSWindow?) {
        self.securityTools = securityTools
        self.windowRef = windowRef
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Configure Guard Rails")
                .font(.headline)
            
            Picker("AI Provider:", selection: $selectedProvider) {
                ForEach(providers, id: \.self) { provider in
                    Text(provider)
                }
            }
            .pickerStyle(MenuPickerStyle())
            
            HStack {
                Text("API Key:")
                SecureField("Enter API Key", text: $apiKey)
            }
            
            Text("Custom Security Prompt:")
            TextEditor(text: $customPrompt)
                .frame(height: 100)
                .border(Color.gray.opacity(0.3))
            
            HStack {
                Spacer()
                Button("Cancel") {
                    logger.info("Cancel button pressed")
                    windowRef?.close()
                }
                Button("Save") {
                    logger.info("Save button pressed")
                    securityTools.saveGuardRailsConfig(
                        provider: selectedProvider,
                        apiKey: apiKey,
                        customPrompt: customPrompt
                    )
                    windowRef?.close()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400, height: 300)
        .onAppear {
            logger.info("GuardRailsConfigView appeared")
            let config = securityTools.getGuardRailsConfig()
            selectedProvider = config.provider
            apiKey = config.apiKey
            customPrompt = config.customPrompt
        }
    }
}

struct ConfigurationView: View {
    @ObservedObject var configManager: ConfigurationManager
    @State private var idePaths: [String: String] = [:]
    weak var windowRef: NSWindow?
    
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "ConfigView")
    
    init(configManager: ConfigurationManager, windowRef: NSWindow?) {
        self.configManager = configManager
        self.windowRef = windowRef
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("IDE Configuration Paths")
                .font(.headline)
            
            ForEach(configManager.supportedIDEs, id: \.self) { ide in
                HStack {
                    Text("\(ide):")
                        .frame(width: 100, alignment: .trailing)
                    TextField("Path to MCP config", text: binding(for: ide))
                    Button("Browse") {
                        selectPath(for: ide)
                    }
                }
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Cancel") {
                    logger.info("Config cancel button pressed")
                    windowRef?.close()
                }
                Button("Save") {
                    logger.info("Config save button pressed")
                    configManager.saveIDEPaths(idePaths)
                    windowRef?.close()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 500, height: 400)
        .onAppear {
            idePaths = configManager.getIDEPaths()
        }
    }
    
    private func binding(for ide: String) -> Binding<String> {
        Binding(
            get: { idePaths[ide] ?? "" },
            set: { idePaths[ide] = $0 }
        )
    }
    
    private func selectPath(for ide: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                idePaths[ide] = url.path
            }
        }
    }
}

// MARK: - Inline API Keys Management View

struct APIKeysInlineView: View {
    @State private var protectedKeys: [(name: String, server: String)] = []
    @State private var unprotectedKeys: [(server: String, key: String, value: String, keychainName: String)] = []
    @State private var isScanning = false
    @State private var showSuccessAlert = false
    @State private var successMessage = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Keys Management")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Protect your API keys by moving them to the macOS Keychain")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "key.fill")
                    .font(.largeTitle)
                    .foregroundColor(.blue)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    // How It Works
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("How It Works", systemImage: "info.circle")
                                .font(.headline)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("1. MCPSnitch scans your Claude config for plaintext API keys")
                                Text("2. Click 'Move to Keychain' to automatically protect them")
                                Text("3. Keys are stored securely and replaced with ${KEYCHAIN:name}")
                                Text("4. The MCP proxy automatically substitutes values at runtime")
                            }
                            .font(.caption)
                        }
                    }
                    
                    // Unprotected Keys
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Unprotected Keys", systemImage: "exclamationmark.triangle.fill")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                                
                                Spacer()
                                
                                Button(action: scanForKeys) {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                            }
                            
                            if unprotectedKeys.isEmpty {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("No unprotected keys found - all keys are secure!")
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 8)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(unprotectedKeys, id: \.keychainName) { key in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("\(key.server): \(key.key)")
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                
                                                Text(maskValue(key.value))
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundColor(.orange)
                                                
                                                Text("→ ${KEYCHAIN:\(key.keychainName)}")
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundColor(.green)
                                            }
                                            Spacer()
                                            
                                            Button(action: {
                                                protectSingleKey(key)
                                            }) {
                                                Image(systemName: "lock.fill")
                                                    .foregroundColor(.white)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                            .help("Protect this key")
                                        }
                                        .padding(8)
                                        .background(Color.orange.opacity(0.1))
                                        .cornerRadius(6)
                                    }
                                }
                                
                                Button(action: protectKeys) {
                                    Label("Move All to Keychain", systemImage: "lock.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                        }
                    }
                    
                    // Protected Keys
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Protected Keys", systemImage: "lock.fill")
                                    .font(.headline)
                                    .foregroundColor(.green)
                                
                                Spacer()
                                
                                Button(action: loadProtectedKeys) {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                            }
                            
                            if protectedKeys.isEmpty {
                                HStack {
                                    Image(systemName: "key.slash")
                                        .foregroundColor(.secondary)
                                    Text("No protected keys in Keychain yet")
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 8)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(protectedKeys, id: \.name) { key in
                                        HStack {
                                            Image(systemName: "lock.fill")
                                                .foregroundColor(.green)
                                                .font(.caption)
                                            
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(key.name)
                                                    .font(.system(.caption, design: .monospaced))
                                                
                                                Text("${KEYCHAIN:\(key.name)}")
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            Spacer()
                                        }
                                        .padding(8)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(6)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .onAppear {
            scanForKeys()
            loadProtectedKeys()
        }
        .alert("Success", isPresented: $showSuccessAlert) {
            Button("OK") { }
        } message: {
            Text(successMessage)
        }
    }
    
    // MARK: - Helper Functions
    
    private func maskValue(_ value: String) -> String {
        if value.count > 10 {
            return String(value.prefix(6)) + "..." + String(value.suffix(4))
        }
        return String(repeating: "•", count: value.count)
    }
    
    private func scanForKeys() {
        unprotectedKeys.removeAll()
        
        // Get all MCP server configs using the same logic as the rest of the app
        let serverScanner = ServerScanner()
        let currentServers = serverScanner.scanForServers()
        
        // Get unique config paths
        let uniqueConfigPaths = Set(currentServers.map { $0.path })
        
        print("DEBUG: Found \(uniqueConfigPaths.count) config file(s)")
        
        for configPath in uniqueConfigPaths {
            guard FileManager.default.fileExists(atPath: configPath),
                  let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
                  let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
                  let mcpServers = config["mcpServers"] as? [String: Any] else {
                print("DEBUG: Could not load config at \(configPath)")
                continue
            }
            
            print("DEBUG: Processing \(mcpServers.count) servers from \(configPath)")
            
            for (serverName, serverConfig) in mcpServers {
                if let serverDict = serverConfig as? [String: Any] {
                    print("DEBUG: Scanning server '\(serverName)'")
                    
                    // First check env field if it exists
                    if let env = serverDict["env"] as? [String: String] {
                        print("DEBUG: Server '\(serverName)' has env with \(env.count) variables")
                        
                        for (envKey, envValue) in env {
                            print("DEBUG: Checking env var '\(envKey)' = '\(String(envValue.prefix(10)))...'")
                            
                            // Skip non-secret fields
                            if envKey == "MCP_ORIGINAL_ARGS_B64" {
                                print("DEBUG: Skipping '\(envKey)' - not a secret (base64 args)")
                                continue
                            }
                            
                            if envValue.contains("${KEYCHAIN:") {
                                print("DEBUG: Skipping '\(envKey)' - already protected")
                                continue
                            }
                            
                            if looksLikeAPIKey(key: envKey, value: envValue) {
                                print("DEBUG: DETECTED API KEY in env: '\(envKey)'")
                                let keychainName = "\(serverName)-\(envKey.lowercased())"
                                    .replacingOccurrences(of: "_", with: "-")
                                unprotectedKeys.append((serverName, envKey, envValue, keychainName))
                            } else {
                                print("DEBUG: Not detected as API key: '\(envKey)'")
                            }
                        }
                    }
                    
                    // Also check top-level fields for API keys (like GitHub PAT)
                    for (key, value) in serverDict {
                        // Skip known non-sensitive fields
                        if key == "command" || key == "args" || key == "env" {
                            continue
                        }
                        
                        if let stringValue = value as? String {
                            print("DEBUG: Checking top-level field '\(key)' = '\(String(stringValue.prefix(10)))...'")
                            
                            if stringValue.contains("${KEYCHAIN:") {
                                print("DEBUG: Skipping '\(key)' - already protected")
                                continue
                            }
                            
                            if looksLikeAPIKey(key: key, value: stringValue) {
                                print("DEBUG: DETECTED API KEY at top level: '\(key)'")
                                let keychainName = "\(serverName)-\(key.lowercased())"
                                    .replacingOccurrences(of: "_", with: "-")
                                unprotectedKeys.append((serverName, key, stringValue, keychainName))
                            } else {
                                print("DEBUG: Not detected as API key: '\(key)'")
                            }
                        }
                    }
                }
            }
        }
        
        print("DEBUG: Total unprotected keys found: \(unprotectedKeys.count)")
    }
    
    private func loadProtectedKeys() {
        protectedKeys.removeAll()
        
        let service = "com.MCPSnitch.APIKeys"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                if let account = item[kSecAttrAccount as String] as? String {
                    let parts = account.split(separator: "-", maxSplits: 1)
                    let server = parts.count > 0 ? String(parts[0]) : "unknown"
                    protectedKeys.append((account, server))
                }
            }
        }
    }
    
    private func protectSingleKey(_ key: (server: String, key: String, value: String, keychainName: String)) {
        protectSpecificKeys([key])
    }
    
    private func protectKeys() {
        protectSpecificKeys(unprotectedKeys)
    }
    
    private func protectSpecificKeys(_ keysToProtect: [(server: String, key: String, value: String, keychainName: String)]) {
        guard !keysToProtect.isEmpty else { return }
        
        // Group keys by config file path
        var keysByConfig: [String: [(server: String, key: String, value: String, keychainName: String)]] = [:]
        
        // Get all unique config paths
        let serverScanner = ServerScanner()
        let currentServers = serverScanner.scanForServers()
        
        // Map server names to their config paths
        var serverToConfigPath: [String: String] = [:]
        for server in currentServers {
            serverToConfigPath[server.name] = server.path
        }
        
        // Group keys to protect by their config file
        for key in keysToProtect {
            if let configPath = serverToConfigPath[key.server] {
                if keysByConfig[configPath] == nil {
                    keysByConfig[configPath] = []
                }
                keysByConfig[configPath]?.append(key)
            }
        }
        
        var totalSuccessCount = 0
        var filesUpdated = 0
        
        // Process each config file
        for (configPath, keysToProtect) in keysByConfig {
            // Create backup
            let backupPath = configPath + ".backup.\(Int(Date().timeIntervalSince1970))"
            try? FileManager.default.copyItem(atPath: configPath, toPath: backupPath)
            print("Created backup: \(backupPath)")
            
            // Store keys in keychain
            for key in keysToProtect {
                if storeInKeychain(name: key.keychainName, value: key.value) {
                    totalSuccessCount += 1
                    print("Stored \(key.keychainName) in keychain")
                }
            }
            
            // Update config file
            guard let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
                  var config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
                  var mcpServers = config["mcpServers"] as? [String: Any] else {
                print("ERROR: Could not load config at \(configPath)")
                continue
            }
            
            for key in keysToProtect {
                if var serverConfig = mcpServers[key.server] as? [String: Any] {
                    // Check if key is in env field
                    if var env = serverConfig["env"] as? [String: String], env[key.key] != nil {
                        env[key.key] = "${KEYCHAIN:\(key.keychainName)}"
                        serverConfig["env"] = env
                        print("Updated env.\(key.key) to use keychain")
                    }
                    // Check if key is at top level
                    else if serverConfig[key.key] != nil {
                        serverConfig[key.key] = "${KEYCHAIN:\(key.keychainName)}"
                        print("Updated top-level \(key.key) to use keychain")
                    }
                    
                    mcpServers[key.server] = serverConfig
                }
            }
            
            config["mcpServers"] = mcpServers
            
            if let updatedData = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
                do {
                    try updatedData.write(to: URL(fileURLWithPath: configPath))
                    filesUpdated += 1
                    print("Updated config file: \(configPath)")
                } catch {
                    print("ERROR: Failed to write config: \(error)")
                }
            }
        }
        
        successMessage = "Protected \(totalSuccessCount) API key(s) in \(filesUpdated) config file(s)!"
        showSuccessAlert = true
        
        scanForKeys()
        loadProtectedKeys()
    }
    
    private func looksLikeAPIKey(key: String, value: String) -> Bool {
        // Skip empty values
        if value.isEmpty {
            return false
        }
        
        // Skip if it's already a keychain reference
        if value.contains("${KEYCHAIN:") {
            return false
        }
        
        // ALWAYS detect GitHub PATs (case-insensitive and with debug)
        let lowercaseValue = value.lowercased()
        if lowercaseValue.starts(with: "github_pat_") || lowercaseValue.starts(with: "ghp_") || lowercaseValue.starts(with: "ghs_") {
            print("DEBUG: Detected GitHub token! Value starts with GitHub pattern")
            return true
        }
        
        // Check if key name suggests it's an API key or token
        let keyIndicators = ["key", "token", "secret", "password", "auth", "api", "credential", "access"]
        let lowercaseKey = key.lowercased()
        for indicator in keyIndicators {
            if lowercaseKey.contains(indicator) {
                // Any non-empty value with these key names is likely sensitive
                return true
            }
        }
        
        // Check for common API key patterns
        let patterns = [
            "^sk-[a-zA-Z0-9]{20,}",     // OpenAI and similar
            "^xox[bp]-[a-zA-Z0-9-]+",   // Slack tokens
            "^[a-f0-9]{32}$",           // 32-char hex (MD5-like)
            "^[a-f0-9]{40}$",           // 40-char hex (SHA1-like)
            "^[a-f0-9]{64}$",           // 64-char hex (SHA256-like)
            "^[A-Za-z0-9+/]{20,}={0,2}$", // Base64 encoded
            "^[A-Z0-9_]{20,}$"          // Generic uppercase API key
        ]
        
        for pattern in patterns {
            if value.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        // If value is long and looks random, it might be a key
        if value.count >= 20 && !value.contains(" ") && !value.hasPrefix("http") && !value.hasPrefix("/") {
            // Check if it has a mix of characters that suggests it's a key
            let hasLetters = value.range(of: "[a-zA-Z]", options: .regularExpression) != nil
            let hasNumbers = value.range(of: "[0-9]", options: .regularExpression) != nil
            if hasLetters && hasNumbers {
                return true
            }
        }
        
        return false
    }
    
    private func storeInKeychain(name: String, value: String) -> Bool {
        let service = "com.MCPSnitch.APIKeys"
        
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: value.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }
}