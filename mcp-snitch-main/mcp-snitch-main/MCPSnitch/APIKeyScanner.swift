import Foundation
import os.log

// MARK: - API Key Scanner
// Detects API keys in configuration files and helps migrate them to Keychain

struct DetectedAPIKey {
    let configPath: String
    let serverName: String
    let keyName: String
    let keyValue: String
    let lineNumber: Int
    let fullLine: String
    let suggestedKeychainName: String
    
    var isLikelyAPIKey: Bool {
        // Check if value looks like an API key
        let patterns = [
            "^sk-[a-zA-Z0-9]{48}",  // OpenAI
            "^ghp_[a-zA-Z0-9]{36}",  // GitHub personal access token
            "^github_pat_[a-zA-Z0-9]{82}", // New GitHub PAT format
            "^ghs_[a-zA-Z0-9]{36}",  // GitHub server token
            "^xoxb-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}", // Slack bot token
            "^xoxp-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}", // Slack user token
            "^[a-f0-9]{32}$",        // Generic 32-char hex (MD5-like)
            "^[a-f0-9]{40}$",        // Generic 40-char hex (SHA1-like)
            "^[a-f0-9]{64}$",        // Generic 64-char hex (SHA256-like)
            "^[A-Za-z0-9+/]{40,}={0,2}$", // Base64 encoded keys
            "^[A-Z0-9_]{20,}$"       // Generic uppercase API key
        ]
        
        for pattern in patterns {
            if let _ = keyValue.range(of: pattern, options: .regularExpression) {
                return true
            }
        }
        
        // Check if the key name suggests it's an API key
        let keyNameIndicators = [
            "key", "token", "secret", "password", "pass", "auth",
            "api", "credential", "access", "private"
        ]
        
        let lowercaseKeyName = keyName.lowercased()
        for indicator in keyNameIndicators {
            if lowercaseKeyName.contains(indicator) && keyValue.count > 10 {
                return true
            }
        }
        
        return false
    }
}

class APIKeyScanner {
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "APIKeyScanner")
    private let configManager = ConfigurationManager()
    private let keychainManager = KeychainManager.shared
    
    // MARK: - Scan for API Keys
    
    func scanForAPIKeys(configPath: String? = nil) -> [DetectedAPIKey] {
        var detectedKeys: [DetectedAPIKey] = []
        
        // Get config path - use provided one or try to find it
        let path = configPath ?? configManager.getConfigPath()
        guard let configPath = path else {
            logger.error("Could not find config file")
            return []
        }
        
        // Read the config file
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            logger.error("Failed to read config file")
            return []
        }
        
        // Scan MCP servers configuration
        if let mcpServers = config["mcpServers"] as? [String: Any] {
            for (serverName, serverConfig) in mcpServers {
                if let serverDict = serverConfig as? [String: Any] {
                    logger.info("Scanning server: \(serverName)")
                    
                    // First check for env field (newer format)
                    if let env = serverDict["env"] as? [String: String] {
                        logger.info("Found env field in \(serverName)")
                        for (envKey, envValue) in env {
                            // Skip non-secret fields
                            if envKey == "MCP_ORIGINAL_ARGS_B64" {
                                logger.info("Skipping \(envKey) - not a secret")
                                continue
                            }
                            
                            // Skip if already using keychain variable
                            if envValue.contains("${KEYCHAIN:") {
                                continue
                            }
                            
                            let detectedKey = DetectedAPIKey(
                                configPath: configPath,
                                serverName: serverName,
                                keyName: envKey,
                                keyValue: envValue,
                                lineNumber: 0,
                                fullLine: "\"\(envKey)\": \"\(envValue)\"",
                                suggestedKeychainName: "\(serverName)_\(envKey.lowercased().replacingOccurrences(of: "_", with: "-"))"
                            )
                            
                            if detectedKey.isLikelyAPIKey {
                                detectedKeys.append(detectedKey)
                                logger.info("Found potential API key in env: \(envKey) in server: \(serverName)")
                            }
                        }
                    }
                    
                    // Also check top-level fields for API keys (older/alternate format)
                    // This handles cases like GitHub server where the token is directly in the server config
                    for (key, value) in serverDict {
                        // Skip known non-sensitive fields
                        if key == "command" || key == "args" || key == "env" {
                            continue
                        }
                        
                        // Check if this looks like an API key field
                        if let stringValue = value as? String {
                            // Skip if already using keychain variable
                            if stringValue.contains("${KEYCHAIN:") {
                                continue
                            }
                            
                            logger.info("Checking top-level field: \(key) = \(stringValue.prefix(20))...")
                            
                            let detectedKey = DetectedAPIKey(
                                configPath: configPath,
                                serverName: serverName,
                                keyName: key,
                                keyValue: stringValue,
                                lineNumber: 0,
                                fullLine: "\"\(key)\": \"\(stringValue)\"",
                                suggestedKeychainName: "\(serverName)_\(key.lowercased().replacingOccurrences(of: "_", with: "-"))"
                            )
                            
                            if detectedKey.isLikelyAPIKey {
                                detectedKeys.append(detectedKey)
                                logger.info("Found potential API key at top level: \(key) in server: \(serverName)")
                            }
                        }
                    }
                }
            }
        }
        
        logger.info("Total detected keys: \(detectedKeys.count)")
        return detectedKeys
    }
    
    // MARK: - Migrate Keys to Keychain
    
    func migrateToKeychain(_ keys: [DetectedAPIKey]) -> Bool {
        var allSuccess = true
        
        for key in keys {
            // Store in keychain
            let success = keychainManager.saveKey(
                name: key.suggestedKeychainName,
                value: key.keyValue
            )
            
            if success {
                logger.info("Migrated key '\(key.keyName)' to keychain as '\(key.suggestedKeychainName)'")
            } else {
                logger.error("Failed to migrate key '\(key.keyName)'")
                allSuccess = false
            }
        }
        
        // Update config file if all keys migrated successfully
        if allSuccess {
            return updateConfigFile(keys)
        }
        
        return false
    }
    
    // MARK: - Update Config File
    
    private func updateConfigFile(_ keys: [DetectedAPIKey]) -> Bool {
        guard let configPath = configManager.getConfigPath() else {
            return false
        }
        
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              var config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              var mcpServers = config["mcpServers"] as? [String: Any] else {
            return false
        }
        
        // Update each server's configuration
        for key in keys {
            if var serverConfig = mcpServers[key.serverName] as? [String: Any] {
                
                // Check if the key is in env field
                if var env = serverConfig["env"] as? [String: String], env[key.keyName] != nil {
                    // Replace with keychain variable in env
                    env[key.keyName] = "${KEYCHAIN:\(key.suggestedKeychainName)}"
                    serverConfig["env"] = env
                } else if serverConfig[key.keyName] != nil {
                    // Replace with keychain variable at top level
                    serverConfig[key.keyName] = "${KEYCHAIN:\(key.suggestedKeychainName)}"
                }
                
                mcpServers[key.serverName] = serverConfig
            }
        }
        
        config["mcpServers"] = mcpServers
        
        // Write back to file
        do {
            let updatedData = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
            try updatedData.write(to: URL(fileURLWithPath: configPath))
            logger.info("Successfully updated config file with keychain variables")
            return true
        } catch {
            logger.error("Failed to update config file: \(error)")
            return false
        }
    }
    
    // MARK: - Backup Config
    
    func backupConfig() -> String? {
        guard let configPath = configManager.getConfigPath() else {
            return nil
        }
        
        let backupPath = configPath + ".backup.\(Date().timeIntervalSince1970)"
        
        do {
            let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
            try configData.write(to: URL(fileURLWithPath: backupPath))
            logger.info("Created config backup at: \(backupPath)")
            return backupPath
        } catch {
            logger.error("Failed to create backup: \(error)")
            return nil
        }
    }
    
    // MARK: - Validate Migration
    
    func validateMigration() -> Bool {
        // Check if all detected keys are now in keychain format
        let currentKeys = scanForAPIKeys()
        return currentKeys.isEmpty  // No plaintext keys means successful migration
    }
}