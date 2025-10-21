import Foundation
import Security
import os.log

class ProxyManager: ObservableObject {
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "ProxyManager")
    private let proxyPath: String
    private let httpProxyPath: String
    @Published var activeProxies: [String: ProxyInfo] = [:]

    struct ProxyInfo {
        let serverName: String
        let originalCommand: String
        let originalArgs: [String]
        let logPath: String
        let configPath: String
        let isHTTP: Bool
        let originalURL: String?
        let localProxyPort: Int?
    }
    
    init() {
        // Get the path to stdio proxy in the app bundle
        if let bundledProxy = Bundle.main.path(forResource: "mcp_proxy", ofType: nil) {
            proxyPath = bundledProxy
            logger.info("Found stdio proxy at: \(bundledProxy)")
        } else {
            // Fallback to build directory during development
            let bundlePath = Bundle.main.bundlePath
            let fallbackPath = "\(bundlePath)/Contents/Resources/mcp_proxy"
            proxyPath = fallbackPath
            logger.warning("Using fallback stdio proxy path: \(fallbackPath)")
        }

        // Get the path to HTTP proxy in the app bundle
        if let bundledHTTPProxy = Bundle.main.path(forResource: "mcp_http_proxy", ofType: nil) {
            httpProxyPath = bundledHTTPProxy
            logger.info("Found HTTP proxy at: \(bundledHTTPProxy)")
        } else {
            // Fallback to build directory during development
            let bundlePath = Bundle.main.bundlePath
            let fallbackPath = "\(bundlePath)/Contents/Resources/mcp_http_proxy"
            httpProxyPath = fallbackPath
            logger.warning("Using fallback HTTP proxy path: \(fallbackPath)")
        }

        // Load saved proxy ports
        loadProxyPorts()

        // Listen for proxy messages
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleProxyMessage(_:)),
            name: Notification.Name("MCPProxyMessage"),
            object: nil
        )
    }
    
    func protectServer(_ server: MCPServer, config: [String: Any]) -> Bool {
        logger.info("Protecting server: \(server.name) with config keys: \(config.keys)")

        // Check if this server is already protected
        if activeProxies[server.name] != nil {
            logger.warning("Server \(server.name) is already protected")
            return true
        }

        // Create log directory
        let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MCPSnitch")
            .appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let logPath = logDir.appendingPathComponent("\(server.name)_proxy.log").path

        // Check if this is an HTTP/URL-based server
        if let url = config["url"] as? String {
            logger.info("Server \(server.name) is HTTP-based (url: \(url))")
            let headers = config["headers"] as? [String: String] ?? [:]
            return protectHTTPServer(server, url: url, headers: headers, logPath: logPath)
        }

        // Otherwise, handle as stdio-based server
        var originalCommand = ""
        var originalArgs: [String] = []

        if let command = config["command"] as? String {
            // Check if this server is already proxied (command points to mcp_proxy)
            if command.contains("mcp_proxy") || command.contains("mcp_http_proxy") {
                logger.warning("Server \(server.name) is already proxied (command: \(command))")
                logger.warning("This server needs to be properly unprotected first")
                return false
            }

            originalCommand = command
            originalArgs = (config["args"] as? [String]) ?? []
            logger.info("Found command-based server: command=\(command), args=\(originalArgs)")
        } else if let stdio = config["stdio"] as? [String: Any],
                  let command = stdio["command"] as? String {
            // Check if already proxied
            if command.contains("mcp_proxy") || command.contains("mcp_http_proxy") {
                logger.warning("Server \(server.name) is already proxied (stdio command: \(command))")
                logger.warning("This server needs to be properly unprotected first")
                return false
            }

            originalCommand = command
            originalArgs = (stdio["args"] as? [String]) ?? []
            logger.info("Found stdio-based server: command=\(command), args=\(originalArgs)")
        } else {
            logger.error("No command or URL found in server config")
            return false
        }

        // Store proxy info for stdio
        let proxyInfo = ProxyInfo(
            serverName: server.name,
            originalCommand: originalCommand,
            originalArgs: originalArgs,
            logPath: logPath,
            configPath: server.path,
            isHTTP: false,
            originalURL: nil,
            localProxyPort: nil
        )
        activeProxies[server.name] = proxyInfo

        // Update the config to use our stdio proxy
        return updateConfigForProxy(server, proxyInfo: proxyInfo)
    }

    private func protectHTTPServer(_ server: MCPServer, url: String, headers: [String: String], logPath: String) -> Bool {
        // Check if proxy is already running for this server
        if let existingProxy = activeProxies[server.name], existingProxy.isHTTP {
            logger.info("HTTP proxy already running for \(server.name), updating config only")

            // Just update the config to point to the existing proxy
            let proxyInfo = ProxyInfo(
                serverName: server.name,
                originalCommand: "",
                originalArgs: [],
                logPath: logPath,
                configPath: server.path,
                isHTTP: true,
                originalURL: url,
                localProxyPort: existingProxy.localProxyPort
            )
            return updateConfigForHTTPProxy(server, proxyInfo: proxyInfo)
        }

        // Start the HTTP proxy process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: httpProxyPath)

        // Set up environment for HTTP proxy
        var environment = ProcessInfo.processInfo.environment
        environment["MCP_SERVER_NAME"] = server.name
        environment["MCP_TARGET_URL"] = url
        environment["MCP_LOG_PATH"] = logPath

        // Try to reuse saved port, otherwise let OS assign
        if let savedPort = getSavedProxyPort(serverName: server.name) {
            environment["MCP_LOCAL_PORT"] = String(savedPort)
            logger.info("Reusing saved port \(savedPort) for server: \(server.name)")
        } else {
            environment["MCP_LOCAL_PORT"] = "0" // Let OS assign a port
        }

        // Pass headers as JSON
        if let headersJSON = try? JSONSerialization.data(withJSONObject: headers),
           let headersString = String(data: headersJSON, encoding: .utf8) {
            environment["MCP_TARGET_HEADERS"] = headersString
        }

        // Pass GuardRails configuration
        let guardRailsManager = GuardRailsManager.shared
        environment["GUARDRAILS_TOOL_MODE"] = guardRailsManager.toolControlMode.rawValue
        environment["GUARDRAILS_SECURITY_MODE"] = guardRailsManager.securityDetectionMode.rawValue

        process.environment = environment

        // Capture stdout to read the assigned port
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            logger.info("Started HTTP proxy process for server: \(server.name)")

            // Read the assigned port from stdout (proxy will output "PROXY_PORT:12345")
            // Give it a moment to start and output the port
            let stdoutHandle = stdoutPipe.fileHandleForReading

            var portFound = false
            var port = 0

            // Try reading with a timeout
            for attempt in 1...10 {
                if let data = try? stdoutHandle.availableData,
                   !data.isEmpty,
                   let output = String(data: data, encoding: .utf8) {
                    logger.info("HTTP proxy output (attempt \(attempt)): \(output)")

                    if let portLine = output.components(separatedBy: "\n").first(where: { $0.hasPrefix("PROXY_PORT:") }),
                       let portString = portLine.components(separatedBy: ":").last,
                       let foundPort = Int(portString) {
                        port = foundPort
                        portFound = true
                        break
                    }
                }

                // Wait a bit before next attempt
                Thread.sleep(forTimeInterval: 0.1)
            }

            if portFound {
                logger.info("HTTP proxy listening on port: \(port)")

                // Save the port for reuse
                saveProxyPort(serverName: server.name, port: port)

                // Store proxy info
                let proxyInfo = ProxyInfo(
                    serverName: server.name,
                    originalCommand: "",
                    originalArgs: [],
                    logPath: logPath,
                    configPath: server.path,
                    isHTTP: true,
                    originalURL: url,
                    localProxyPort: port
                )
                activeProxies[server.name] = proxyInfo

                // Update config to use local proxy URL
                return updateConfigForHTTPProxy(server, proxyInfo: proxyInfo)
            } else {
                logger.error("Failed to read proxy port from HTTP proxy process after 10 attempts")
                logger.error("Process is running: \(process.isRunning)")
                process.terminate()
                return false
            }
        } catch {
            logger.error("Failed to start HTTP proxy process: \(error)")
            return false
        }
    }
    
    func startProxyForProtectedServer(_ server: MCPServer) {
        logger.info("Starting proxy for already-protected server: \(server.name)")

        // Read the server's current config
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: server.path)),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let mcpServers = config["mcpServers"] as? [String: Any],
              let serverConfig = mcpServers[server.name] as? [String: Any] else {
            logger.error("Failed to read config for server: \(server.name)")
            return
        }

        // Check if this is an HTTP server
        if let currentURL = serverConfig["url"] as? String,
           let originalURL = serverConfig["_original_url"] as? String {
            // This is a protected HTTP server
            logger.info("Server \(server.name) is HTTP-based (current: \(currentURL), original: \(originalURL))")

            let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("MCPSnitch/logs")
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let logPath = logDir.appendingPathComponent("\(server.name)_proxy.log").path

            let headers = serverConfig["headers"] as? [String: String] ?? [:]

            // Start the proxy process WITHOUT updating config (it's already updated)
            startHTTPProxyProcess(server: server, targetURL: originalURL, headers: headers, logPath: logPath)
        } else if serverConfig["_original_command"] != nil {
            // This is a protected stdio server
            logger.info("Server \(server.name) is stdio-based, proxy already managed by Claude")
            // Stdio servers are started by Claude, we don't need to do anything
        }
    }

    private func startHTTPProxyProcess(server: MCPServer, targetURL: String, headers: [String: String], logPath: String) {
        logger.info("Starting HTTP proxy process for: \(server.name)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: httpProxyPath)

        var environment = ProcessInfo.processInfo.environment
        environment["MCP_SERVER_NAME"] = server.name
        environment["MCP_TARGET_URL"] = targetURL
        environment["MCP_LOG_PATH"] = logPath

        // Try to reuse saved port
        if let savedPort = getSavedProxyPort(serverName: server.name) {
            environment["MCP_LOCAL_PORT"] = String(savedPort)
            logger.info("Reusing saved port \(savedPort) for server: \(server.name)")
        } else {
            environment["MCP_LOCAL_PORT"] = "0"
        }

        // Pass headers as JSON
        if let headersJSON = try? JSONSerialization.data(withJSONObject: headers),
           let headersString = String(data: headersJSON, encoding: .utf8) {
            environment["MCP_TARGET_HEADERS"] = headersString
        }

        // Pass GuardRails configuration
        let guardRailsManager = GuardRailsManager.shared
        environment["GUARDRAILS_TOOL_MODE"] = guardRailsManager.toolControlMode.rawValue
        environment["GUARDRAILS_SECURITY_MODE"] = guardRailsManager.securityDetectionMode.rawValue

        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            logger.info("Started HTTP proxy process for server: \(server.name)")

            // Store in active proxies
            let proxyInfo = ProxyInfo(
                serverName: server.name,
                originalCommand: "",
                originalArgs: [],
                logPath: logPath,
                configPath: server.path,
                isHTTP: true,
                originalURL: targetURL,
                localProxyPort: getSavedProxyPort(serverName: server.name)
            )
            activeProxies[server.name] = proxyInfo
        } catch {
            logger.error("Failed to start HTTP proxy process: \(error)")
        }
    }

    func unprotectServer(_ server: MCPServer) -> Bool {
        logger.info("Unprotecting server: \(server.name)")

        guard let proxyInfo = activeProxies[server.name] else {
            logger.warning("No proxy info found for server: \(server.name)")
            return false
        }

        // Restore original config
        let result = restoreOriginalConfig(server, proxyInfo: proxyInfo)

        // Remove from active proxies
        activeProxies.removeValue(forKey: server.name)

        // Keep the saved port (don't remove) so it can be reused next time

        return result
    }
    
    private func updateConfigForHTTPProxy(_ server: MCPServer, proxyInfo: ProxyInfo) -> Bool {
        logger.info("Updating config for HTTP proxy: \(server.name) at path: \(server.path)")

        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: server.path)) else {
            logger.error("Failed to read config data from: \(server.path)")
            return false
        }

        guard var config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            logger.error("Failed to parse config JSON")
            return false
        }

        guard var mcpServers = config["mcpServers"] else {
            logger.error("No mcpServers key found in config")
            return false
        }

        // Create backup
        let backupPath = "\(server.path).backup"
        try? configData.write(to: URL(fileURLWithPath: backupPath))

        if var serversDict = mcpServers as? [String: Any] {
            guard var serverConfig = serversDict[server.name] as? [String: Any] else {
                logger.error("Server \(server.name) not found in config dictionary")
                return false
            }

            // Store original URL
            if let originalURL = serverConfig["url"] as? String {
                serverConfig["_original_url"] = originalURL
            }

            // Update URL to point to local proxy
            if let port = proxyInfo.localProxyPort {
                serverConfig["url"] = "http://localhost:\(port)"
                logger.info("Updated server URL to: http://localhost:\(port)")
            } else {
                logger.error("No local proxy port available")
                return false
            }

            // Update the config
            serversDict[server.name] = serverConfig
            config["mcpServers"] = serversDict

            // Write back
            if let updatedData = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
                do {
                    try updatedData.write(to: URL(fileURLWithPath: server.path))
                    logger.info("Successfully updated config for HTTP proxy at: \(server.path)")
                    return true
                } catch {
                    logger.error("Failed to write config: \(error)")
                    return false
                }
            } else {
                logger.error("Failed to serialize config to JSON")
            }
        } else {
            logger.error("mcpServers is not a dictionary")
        }

        return false
    }

    private func updateConfigForProxy(_ server: MCPServer, proxyInfo: ProxyInfo) -> Bool {
        logger.info("Updating config for proxy: \(server.name) at path: \(server.path)")
        
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: server.path)) else {
            logger.error("Failed to read config data from: \(server.path)")
            return false
        }
        
        guard var config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            logger.error("Failed to parse config JSON")
            return false
        }
        
        guard var mcpServers = config["mcpServers"] else {
            logger.error("No mcpServers key found in config")
            return false
        }
        
        // Create backup
        let backupPath = "\(server.path).backup"
        try? configData.write(to: URL(fileURLWithPath: backupPath))
        
        // Update the server configuration
        logger.info("mcpServers type: \(type(of: mcpServers))")
        
        if var serversDict = mcpServers as? [String: Any] {
            logger.info("mcpServers is a dictionary with keys: \(serversDict.keys)")
            
            guard var serverConfig = serversDict[server.name] as? [String: Any] else {
                logger.error("Server \(server.name) not found in config dictionary")
                return false
            }
            
            logger.info("Found server config for \(server.name): \(serverConfig)")
            
            // Store original config
            if let stdio = serverConfig["stdio"] as? [String: Any] {
                // Store stdio format for restoration
                serverConfig["_original_stdio"] = stdio
                serverConfig.removeValue(forKey: "stdio")
            } else if let command = serverConfig["command"] as? String {
                serverConfig["_original_command"] = command
            } else if let url = serverConfig["url"] as? String {
                // URL-based servers need different handling
                logger.warning("Server \(server.name) is URL-based (url: \(url)), cannot proxy stdin/stdout")
                return false
            }
            
            if let args = serverConfig["args"] {
                serverConfig["_original_args"] = args
            }
            
            // Set proxy as the command
            serverConfig["command"] = proxyPath
            serverConfig["args"] = []
            
            // Preserve existing environment variables and add proxy-specific ones
            var env = (serverConfig["env"] as? [String: String]) ?? [:]
            
            // Also check for top-level string values that look like environment variables
            // (e.g., GITHUB_PERSONAL_ACCESS_TOKEN at the top level of the config)
            for (key, value) in serverConfig {
                // Skip known non-env keys
                if key == "command" || key == "args" || key == "env" || key == "stdio" || 
                   key == "_original_command" || key == "_original_args" || key == "_original_stdio" {
                    continue
                }
                
                // If it's a string value, add it to the environment
                if let stringValue = value as? String {
                    env[key] = stringValue
                    logger.info("Adding top-level config value to environment: \(key)")
                }
            }
            
            // Add proxy-specific environment variables
            env["MCP_SERVER_NAME"] = server.name
            env["MCP_ORIGINAL_COMMAND"] = proxyInfo.originalCommand
            
            // Encode args as base64-encoded JSON to avoid escaping issues
            if let argsData = try? JSONSerialization.data(withJSONObject: proxyInfo.originalArgs, options: []) {
                env["MCP_ORIGINAL_ARGS_B64"] = argsData.base64EncodedString()
            } else {
                env["MCP_ORIGINAL_ARGS_B64"] = Data("[]".utf8).base64EncodedString()
            }
            
            env["MCP_LOG_PATH"] = proxyInfo.logPath
            
            // Pass GuardRails configuration to proxy
            let guardRailsManager = GuardRailsManager.shared
            env["GUARDRAILS_TOOL_MODE"] = guardRailsManager.toolControlMode.rawValue
            env["GUARDRAILS_SECURITY_MODE"] = guardRailsManager.securityDetectionMode.rawValue
            
            serverConfig["env"] = env
            
            // Update the config
            serversDict[server.name] = serverConfig
            config["mcpServers"] = serversDict
            
            // Write back
            if let updatedData = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
                do {
                    try updatedData.write(to: URL(fileURLWithPath: server.path))
                    logger.info("Successfully updated config for proxy at: \(server.path)")
                    
                    // Verify the write
                    if let verifyData = try? Data(contentsOf: URL(fileURLWithPath: server.path)),
                       let verifyConfig = try? JSONSerialization.jsonObject(with: verifyData) as? [String: Any],
                       let verifyServers = verifyConfig["mcpServers"] as? [String: Any],
                       let verifyServer = verifyServers[server.name] as? [String: Any] {
                        logger.info("Verified config write. Server config now has command: \(verifyServer["command"] as? String ?? "nil")")
                    }
                    
                    return true
                } catch {
                    logger.error("Failed to write config: \(error)")
                    return false
                }
            } else {
                logger.error("Failed to serialize config to JSON")
            }
        } else {
            logger.error("mcpServers is not a dictionary - it might be array format")
        }
        
        return false
    }
    
    private func restoreOriginalConfig(_ server: MCPServer, proxyInfo: ProxyInfo) -> Bool {
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: server.path)),
              var config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              var mcpServers = config["mcpServers"] else {
            return false
        }

        if var serversDict = mcpServers as? [String: Any],
           var serverConfig = serversDict[server.name] as? [String: Any] {

            // Handle HTTP server restoration
            if proxyInfo.isHTTP {
                if let originalURL = serverConfig["_original_url"] as? String {
                    serverConfig["url"] = originalURL
                    serverConfig.removeValue(forKey: "_original_url")
                    logger.info("Restored original URL for HTTP server: \(originalURL)")
                } else if let originalURL = proxyInfo.originalURL {
                    // Fallback to proxy info
                    serverConfig["url"] = originalURL
                    logger.info("Restored original URL from proxy info: \(originalURL)")
                }
            } else {
                // Handle stdio server restoration
                // Restore original command and args
                if let originalCommand = serverConfig["_original_command"] as? String {
                    // Check if the "original" is actually still a proxy (broken state)
                    if originalCommand.contains("mcp_proxy") || originalCommand.contains("mcp_http_proxy") {
                        logger.error("Stored original command is also a proxy path: \(originalCommand)")
                        logger.error("Server config is corrupted. Cannot restore automatically.")
                        logger.error("Please manually edit the config file at: \(server.path)")
                        return false
                    }

                    serverConfig["command"] = originalCommand
                    serverConfig.removeValue(forKey: "_original_command")
                } else {
                    // If no original command stored, it might be a docker command
                    // Try to restore from known patterns
                    if proxyInfo.originalCommand == "docker" {
                        serverConfig["command"] = "docker"
                    } else if proxyInfo.originalCommand == "npx" {
                        serverConfig["command"] = "npx"
                    } else if !proxyInfo.originalCommand.isEmpty {
                        // Use the proxy info as fallback
                        serverConfig["command"] = proxyInfo.originalCommand
                    }
                }

                if let originalArgs = serverConfig["_original_args"] {
                    serverConfig["args"] = originalArgs
                    serverConfig.removeValue(forKey: "_original_args")
                } else if !proxyInfo.originalArgs.isEmpty {
                    // Restore from proxy info if not stored
                    serverConfig["args"] = proxyInfo.originalArgs
                }

                // Handle stdio format restoration if needed
                if let originalStdio = serverConfig["_original_stdio"] as? [String: Any] {
                    serverConfig["stdio"] = originalStdio
                    serverConfig.removeValue(forKey: "_original_stdio")
                    // Remove command/args if we're restoring stdio
                    serverConfig.removeValue(forKey: "command")
                    serverConfig.removeValue(forKey: "args")
                }
                }

            // Process environment variables (only for stdio servers)
            if !proxyInfo.isHTTP, var env = serverConfig["env"] as? [String: String] {
                // Remove proxy-specific variables
                env.removeValue(forKey: "MCP_SERVER_NAME")
                env.removeValue(forKey: "MCP_ORIGINAL_COMMAND")
                env.removeValue(forKey: "MCP_ORIGINAL_ARGS")
                env.removeValue(forKey: "MCP_ORIGINAL_ARGS_B64")
                env.removeValue(forKey: "MCP_LOG_PATH")
                env.removeValue(forKey: "MCP_BLOCK_LIST")
                env.removeValue(forKey: "GUARDRAILS_TOOL_MODE")
                env.removeValue(forKey: "GUARDRAILS_SECURITY_MODE")
                
                // Restore keychain references to plain text values
                for (key, value) in env {
                    if value.hasPrefix("${KEYCHAIN:") && value.hasSuffix("}") {
                        // Extract keychain key name
                        let startIndex = value.index(value.startIndex, offsetBy: 11) // Length of "${KEYCHAIN:"
                        let endIndex = value.index(value.endIndex, offsetBy: -1)
                        let keychainName = String(value[startIndex..<endIndex])
                        
                        // Get the actual value from keychain
                        if let actualValue = getKeyFromKeychain(name: keychainName) {
                            env[key] = actualValue
                            logger.info("Restored plain text value for \(key) from keychain")
                        } else {
                            logger.warning("Could not retrieve value for \(key) from keychain: \(keychainName)")
                        }
                    }
                }
                
                // Keep env if there are remaining variables
                if !env.isEmpty {
                    serverConfig["env"] = env
                } else {
                    serverConfig.removeValue(forKey: "env")
                }
            }
            
            // Also check for top-level keychain references (like GITHUB_PERSONAL_ACCESS_TOKEN)
            for (key, value) in serverConfig {
                if let stringValue = value as? String,
                   stringValue.hasPrefix("${KEYCHAIN:") && stringValue.hasSuffix("}") {
                    // Extract keychain key name
                    let startIndex = stringValue.index(stringValue.startIndex, offsetBy: 11)
                    let endIndex = stringValue.index(stringValue.endIndex, offsetBy: -1)
                    let keychainName = String(stringValue[startIndex..<endIndex])
                    
                    // Get the actual value from keychain
                    if let actualValue = getKeyFromKeychain(name: keychainName) {
                        serverConfig[key] = actualValue
                        logger.info("Restored plain text value for top-level \(key) from keychain")
                    } else {
                        logger.warning("Could not retrieve value for top-level \(key) from keychain: \(keychainName)")
                    }
                }
            }
            
            // Update the config
            serversDict[server.name] = serverConfig
            config["mcpServers"] = serversDict
            
            // Write back
            if let updatedData = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
                do {
                    try updatedData.write(to: URL(fileURLWithPath: server.path))
                    logger.info("Successfully restored original config with plain text secrets")
                    return true
                } catch {
                    logger.error("Failed to write restored config: \(error)")
                    return false
                }
            }
        }
        
        return false
    }
    
    @objc private func handleProxyMessage(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let serverName = userInfo["server"] as? String,
              let direction = userInfo["direction"] as? String,
              let content = userInfo["content"] as? String else {
            return
        }
        
        logger.info("Proxy message from \(serverName): \(direction)")
        
        // Post to main app for UI update
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name("MCPProxyMessageReceived"),
                object: nil,
                userInfo: [
                    "server": serverName,
                    "direction": direction,
                    "content": content
                ]
            )
        }
    }
    
    func getProxyLog(for serverName: String) -> String? {
        guard let proxyInfo = activeProxies[serverName] else { return nil }
        return try? String(contentsOfFile: proxyInfo.logPath, encoding: .utf8)
    }
    
    // Helper function to get key from keychain
    private func getKeyFromKeychain(name: String) -> String? {
        let service = "com.MCPSnitch.APIKeys"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        
        return nil
    }

    // MARK: - Persistent Port Storage

    private func proxyPortsFilePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let mcpSnitchDir = appSupport.appendingPathComponent("MCPSnitch")
        try? FileManager.default.createDirectory(at: mcpSnitchDir, withIntermediateDirectories: true)
        return mcpSnitchDir.appendingPathComponent("proxy_ports.json").path
    }

    private func loadProxyPorts() {
        let path = proxyPortsFilePath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let ports = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return
        }

        logger.info("Loaded saved proxy ports: \(ports)")
    }

    private func saveProxyPort(serverName: String, port: Int) {
        let path = proxyPortsFilePath()
        var ports: [String: Int] = [:]

        // Load existing
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            ports = existing
        }

        // Update
        ports[serverName] = port

        // Save
        if let data = try? JSONSerialization.data(withJSONObject: ports, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: path))
            logger.info("Saved proxy port for \(serverName): \(port)")
        }
    }

    private func getSavedProxyPort(serverName: String) -> Int? {
        let path = proxyPortsFilePath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let ports = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return nil
        }
        return ports[serverName]
    }

    private func removeSavedProxyPort(serverName: String) {
        let path = proxyPortsFilePath()
        var ports: [String: Int] = [:]

        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            ports = existing
        }

        ports.removeValue(forKey: serverName)

        if let data = try? JSONSerialization.data(withJSONObject: ports, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}