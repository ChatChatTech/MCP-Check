import Foundation
import os.log

class ServerManager: ObservableObject {
    private let protectedServersKey = "ProtectedMCPServers"
    private let userDefaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "ServerManager")
    private let trustDB = TrustDatabase.shared
    private let proxyManager = ProxyManager()
    
    @Published var protectedServers: Set<String> = []
    
    init() {
        loadProtectedServers()
        // Start proxies for already-protected servers
        startProtectedProxies()
    }

    private func startProtectedProxies() {
        logger.info("Starting proxies for protected servers...")

        // Get all servers from all configs
        let scanner = ServerScanner()
        let allServers = scanner.scanForServers()

        for serverName in protectedServers {
            // Find the server config
            if let server = allServers.first(where: { $0.name == serverName }) {
                logger.info("Starting proxy for protected server: \(serverName)")

                // Start the proxy (don't update config - it's already set)
                proxyManager.startProxyForProtectedServer(server)
            } else {
                logger.warning("Protected server \(serverName) not found in configs")
            }
        }
    }
    
    private func loadProtectedServers() {
        if let saved = userDefaults.array(forKey: protectedServersKey) as? [String] {
            protectedServers = Set(saved)
        }
    }
    
    func trustServer(_ server: MCPServer) {
        logger.info("Trusting server: \(server.name)")
        
        // Detect server type from config if possible
        let serverType = detectServerType(for: server)
        
        let trustedServer = TrustedServer(
            name: server.name,
            type: serverType.type,
            identifier: serverType.identifier,
            configPath: server.path.isEmpty ? nil : server.path
        )
        
        if trustDB.addTrustedServer(trustedServer) {
            logger.info("Successfully trusted server: \(server.name)")
        } else {
            logger.error("Failed to trust server: \(server.name)")
        }
    }
    
    func untrustServer(_ server: MCPServer) {
        logger.info("Untrusting server: \(server.name)")
        let serverType = detectServerType(for: server)
        
        if trustDB.removeTrustedServer(name: server.name, identifier: serverType.identifier) {
            logger.info("Successfully untrusted server: \(server.name)")
        } else {
            logger.error("Failed to untrust server: \(server.name)")
        }
    }
    
    private func detectServerType(for server: MCPServer) -> (type: String, identifier: String) {
        logger.info("Detecting type for server: \(server.name) at path: \(server.path)")
        
        // Try to load and parse the config to detect type
        if let configData = loadConfigFile(at: server.path),
           let mcpServers = configData["mcpServers"] {
            
            // Handle object format
            if let serversDict = mcpServers as? [String: Any],
               let serverConfig = serversDict[server.name] as? [String: Any] {
                logger.info("Found server config: \(serverConfig)")
                
                if let detected = TrustDatabase.detectServerType(from: serverConfig) {
                    logger.info("Detected type: \(detected.type), identifier: \(detected.identifier)")
                    return detected
                }
            }
            
            // Handle array format
            if let serversArray = mcpServers as? [[String: Any]] {
                for serverConfig in serversArray {
                    if (serverConfig["name"] as? String) == server.name,
                       let detected = TrustDatabase.detectServerType(from: serverConfig) {
                        logger.info("Detected type: \(detected.type), identifier: \(detected.identifier)")
                        return detected
                    }
                }
            }
        }
        
        // Default to local type if can't detect
        logger.warning("Could not detect type for \(server.name), defaulting to local")
        return ("local", server.path)
    }
    
    func canProtectServer(_ server: MCPServer) -> Bool {
        // Load server config to check if it's a command-based server
        if let configData = loadConfigFile(at: server.path),
           let mcpServers = configData["mcpServers"] {
            
            var serverConfig: [String: Any]?
            
            // Get server config based on format
            if let serversDict = mcpServers as? [String: Any] {
                serverConfig = serversDict[server.name] as? [String: Any]
            } else if let serversArray = mcpServers as? [[String: Any]] {
                serverConfig = serversArray.first { ($0["name"] as? String) == server.name }
            }
            
            if let config = serverConfig {
                // Both URL-based (HTTP) and command-based (stdio) servers can be protected
                // HTTP servers use HTTP proxy, stdio servers use stdin/stdout proxy
                if config["url"] != nil {
                    return true  // HTTP server - can be protected with HTTP proxy
                }
                // Command-based servers can be protected with stdio proxy
                return config["command"] != nil || config["stdio"] != nil
            }
        }
        return false
    }
    
    func protectServer(_ server: MCPServer) {
        logger.info("Protecting server: \(server.name)")
        
        // Load server config
        if let configData = loadConfigFile(at: server.path),
           let mcpServers = configData["mcpServers"] {
            
            var serverConfig: [String: Any]?
            
            // Get server config based on format
            if let serversDict = mcpServers as? [String: Any] {
                serverConfig = serversDict[server.name] as? [String: Any]
            } else if let serversArray = mcpServers as? [[String: Any]] {
                serverConfig = serversArray.first { ($0["name"] as? String) == server.name }
            }
            
            if let config = serverConfig {
                // Set up proxy for the server (supports both stdio and HTTP servers)
                if proxyManager.protectServer(server, config: config) {
                    protectedServers.insert(server.name)
                    saveProtectedServers()
                    logger.info("Successfully protected server with proxy: \(server.name)")
                } else {
                    logger.warning("Could not set up proxy for server: \(server.name)")
                }
            }
        }
    }
    
    func unprotectServer(_ server: MCPServer) {
        logger.info("Unprotecting server: \(server.name)")
        
        // Remove proxy
        if proxyManager.unprotectServer(server) {
            logger.info("Successfully removed proxy for server: \(server.name)")
        }
        
        protectedServers.remove(server.name)
        saveProtectedServers()
    }
    
    func removeServer(_ server: MCPServer) {
        logger.info("Attempting to remove server: \(server.name) from \(server.configFile)")
        
        // Create backup first
        createBackup(of: server.path)
        
        guard let configData = loadConfigFile(at: server.path) else {
            logger.error("Failed to load config file at: \(server.path)")
            return
        }
        
        var success = false
        
        // Check for different config formats
        if server.configFile.contains("Cursor") || server.path.contains(".cursor/mcp.json") {
            success = removeFromObjectFormat(server, configData: configData, path: server.path)
        } else if server.configFile.contains("Claude Desktop") {
            success = removeFromObjectFormat(server, configData: configData, path: server.path)
        } else {
            success = removeFromArrayFormat(server, configData: configData, path: server.path)
        }
        
        if success {
            logger.info("Successfully removed server: \(server.name)")
            // Remove from trust database
            let serverType = detectServerType(for: server)
            _ = trustDB.removeTrustedServer(name: server.name, identifier: serverType.identifier)
            protectedServers.remove(server.name)
            saveProtectedServers()
        } else {
            logger.error("Failed to remove server: \(server.name)")
        }
    }
    
    private func removeFromObjectFormat(_ server: MCPServer, configData: [String: Any], path: String) -> Bool {
        var config = configData
        
        guard var mcpServers = config["mcpServers"] as? [String: Any] else {
            logger.error("mcpServers is not in object format")
            return false
        }
        
        if mcpServers[server.name] != nil {
            logger.info("Removing \(server.name) from object format config")
            mcpServers.removeValue(forKey: server.name)
            config["mcpServers"] = mcpServers
            return saveConfigFile(config, at: path)
        } else {
            logger.warning("Server \(server.name) not found in config")
            return false
        }
    }
    
    private func removeFromArrayFormat(_ server: MCPServer, configData: [String: Any], path: String) -> Bool {
        var config = configData
        
        guard var mcpServers = config["mcpServers"] as? [[String: Any]] else {
            logger.error("mcpServers is not in array format")
            return false
        }
        
        let originalCount = mcpServers.count
        mcpServers.removeAll { dict in
            (dict["name"] as? String) == server.name
        }
        
        if mcpServers.count < originalCount {
            logger.info("Removed \(server.name) from array format config")
            config["mcpServers"] = mcpServers
            return saveConfigFile(config, at: path)
        } else {
            logger.warning("Server \(server.name) not found in config")
            return false
        }
    }
    
    private func loadConfigFile(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
    
    private func saveConfigFile(_ config: [String: Any], at path: String) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
            try data.write(to: URL(fileURLWithPath: path))
            logger.info("Successfully saved config to: \(path)")
            return true
        } catch {
            logger.error("Failed to save config: \(error)")
            return false
        }
    }
    
    private func createBackup(of path: String) {
        let backupPath = path + ".backup-\(Date().timeIntervalSince1970)"
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: path) {
                try fileManager.copyItem(atPath: path, toPath: backupPath)
                logger.info("Created backup at: \(backupPath)")
            }
        } catch {
            logger.error("Failed to create backup: \(error)")
        }
    }
    
    private func saveProtectedServers() {
        userDefaults.set(Array(protectedServers), forKey: protectedServersKey)
    }
    
    func isServerTrusted(_ server: MCPServer) -> Bool {
        let serverType = detectServerType(for: server)
        let isTrusted = trustDB.isTrusted(name: server.name, identifier: serverType.identifier)
        logger.info("Checking trust for \(server.name): type=\(serverType.type), identifier=\(serverType.identifier), trusted=\(isTrusted)")
        return isTrusted
    }
    
    func isServerProtected(_ serverName: String) -> Bool {
        return protectedServers.contains(serverName)
    }
    
    func getAllTrustedServers() -> [TrustedServer] {
        return trustDB.getAllTrustedServers()
    }
    
    func getAllProtectedServers() -> [String] {
        return Array(protectedServers)
    }
}