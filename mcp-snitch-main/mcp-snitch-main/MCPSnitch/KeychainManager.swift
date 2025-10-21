import Foundation
import Security
import LocalAuthentication
import os.log

// MARK: - Keychain Manager for MCP Keys
// This manages API keys that can be referenced in MCP configurations
// Users can use ${KEYCHAIN:keyname} in their config files

class KeychainManager {
    static let shared = KeychainManager()
    
    private let service = "com.MCPSnitch.APIKeys"
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "KeychainManager")
    
    // MARK: - Key Management
    
    func saveKey(name: String, value: String) -> Bool {
        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Save without biometric requirement for programmatic access
        // The OS will still prompt for keychain access on first use, but will remember the app
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: value.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,  // More permissive for background access
            kSecAttrLabel as String: "MCP API Key: \(name)",
            kSecAttrComment as String: "API key for MCP server configuration",
            kSecAttrSynchronizable as String: false  // Don't sync to iCloud
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            logger.info("Saved key '\(name)' to keychain")
            return true
        } else {
            logger.error("Failed to save key '\(name)': \(status)")
            return false
        }
    }
    
    func getKey(name: String) -> String? {
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
            logger.info("Retrieved key '\(name)' from keychain")
            return value
        } else if status == errSecItemNotFound {
            logger.warning("Key '\(name)' not found in keychain")
            return nil
        } else {
            logger.error("Failed to retrieve key '\(name)': \(status)")
            return nil
        }
    }
    
    // Add a separate method for viewing keys that requires authentication
    func getKeyWithAuthentication(name: String, reason: String) -> String? {
        // Create LAContext for authentication prompt
        let context = LAContext()
        context.localizedReason = reason
        
        // Try Touch ID first if available
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            context.localizedFallbackTitle = "Use Password"
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            logger.info("Retrieved key '\(name)' with authentication")
            return value
        } else if status == errSecUserCanceled {
            logger.info("User canceled authentication for key '\(name)'")
            return nil
        } else {
            logger.error("Failed to retrieve key '\(name)' with auth: \(status)")
            return nil
        }
    }
    
    func deleteKey(name: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            logger.info("Deleted key '\(name)' from keychain")
            return true
        } else {
            logger.error("Failed to delete key '\(name)': \(status)")
            return false
        }
    }
    
    func listKeys() -> [String] {
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
            let keys = items.compactMap { $0[kSecAttrAccount as String] as? String }
            logger.info("Found \(keys.count) keys in keychain")
            return keys
        }
        
        return []
    }
    
    // MARK: - Environment Variable Substitution
    
    func substituteKeychainVariables(in environment: [String: String]) -> [String: String] {
        var result = environment
        
        for (key, value) in environment {
            // Look for ${KEYCHAIN:keyname} pattern
            let pattern = #"\$\{KEYCHAIN:([^}]+)\}"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            
            let nsValue = value as NSString
            let matches = regex.matches(in: value, options: [], range: NSRange(location: 0, length: nsValue.length))
            
            var newValue = value
            // Process matches in reverse to maintain correct string positions
            for match in matches.reversed() {
                if match.numberOfRanges > 1 {
                    let keyNameRange = match.range(at: 1)
                    let keyName = nsValue.substring(with: keyNameRange)
                    
                    if let keyValue = getKey(name: keyName) {
                        let fullMatchRange = match.range(at: 0)
                        newValue = (newValue as NSString).replacingCharacters(in: fullMatchRange, with: keyValue)
                        logger.info("Substituted keychain variable '\(keyName)' in environment variable '\(key)'")
                    } else {
                        logger.warning("Keychain key '\(keyName)' not found for substitution in '\(key)'")
                    }
                }
            }
            
            result[key] = newValue
        }
        
        return result
    }
}

// MARK: - Keychain Key Model

struct KeychainKey: Identifiable, Codable {
    let id = UUID()
    var name: String
    var description: String
    var createdAt: Date
    var lastUsed: Date?
    
    init(name: String, description: String = "") {
        self.name = name
        self.description = description
        self.createdAt = Date()
    }
}