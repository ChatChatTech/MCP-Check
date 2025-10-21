import SwiftUI
import LocalAuthentication
import os.log

struct APIKeysManagementView: View {
    @State private var protectedKeys: [(name: String, server: String)] = []
    @State private var unprotectedKeys: [(server: String, key: String, value: String, keychainName: String)] = []
    @State private var isScanning = false
    @State private var showSuccessAlert = false
    @State private var successMessage = ""
    @State private var selectedProtectedKey: String?
    @State private var showKeyValue = false
    @State private var keyValue = ""
    
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "APIKeysManagement")
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HeaderView()
            
            Divider()
            
            ScrollView {
                VStack(spacing: 20) {
                    // How It Works Section
                    HowItWorksSection()
                    
                    // Unprotected Keys Section
                    UnprotectedKeysSection(
                        unprotectedKeys: $unprotectedKeys,
                        onProtect: protectKeys,
                        onRefresh: scanForKeys
                    )
                    
                    // Protected Keys Section
                    ProtectedKeysSection(
                        protectedKeys: $protectedKeys,
                        onView: viewProtectedKey,
                        onDelete: deleteProtectedKey,
                        onRefresh: loadProtectedKeys
                    )
                }
                .padding()
            }
        }
        .frame(width: 700, height: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            scanForKeys()
            loadProtectedKeys()
        }
        .alert("Success", isPresented: $showSuccessAlert) {
            Button("OK") { }
        } message: {
            Text(successMessage)
        }
        .sheet(item: $selectedProtectedKey) { key in
            ViewKeySheet(keyName: key, keyValue: keyValue)
        }
    }
    
    // MARK: - Actions
    
    private func scanForKeys() {
        isScanning = true
        unprotectedKeys.removeAll()
        
        let configPath = NSHomeDirectory() + "/Library/Application Support/Claude/claude_desktop_config.json"
        
        guard FileManager.default.fileExists(atPath: configPath),
              let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let mcpServers = config["mcpServers"] as? [String: Any] else {
            isScanning = false
            return
        }
        
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
                        let keychainName = "\(serverName)-\(envKey.lowercased())"
                            .replacingOccurrences(of: "_", with: "-")
                        unprotectedKeys.append((serverName, envKey, envValue, keychainName))
                    }
                }
            }
        }
        
        isScanning = false
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
                    // Parse server name from account (format: "server-keyname")
                    let parts = account.split(separator: "-", maxSplits: 1)
                    let server = parts.count > 0 ? String(parts[0]) : "unknown"
                    protectedKeys.append((account, server))
                }
            }
        }
    }
    
    private func protectKeys() {
        guard !unprotectedKeys.isEmpty else { return }
        
        let configPath = NSHomeDirectory() + "/Library/Application Support/Claude/claude_desktop_config.json"
        
        // Create backup
        let backupPath = configPath + ".backup.\(Int(Date().timeIntervalSince1970))"
        try? FileManager.default.copyItem(atPath: configPath, toPath: backupPath)
        
        // Store keys in keychain
        var successCount = 0
        for key in unprotectedKeys {
            if storeInKeychain(name: key.keychainName, value: key.value) {
                successCount += 1
            }
        }
        
        // Update config file
        guard let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              var config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
              var mcpServers = config["mcpServers"] as? [String: Any] else {
            return
        }
        
        // Replace values with keychain references
        for key in unprotectedKeys {
            if var serverConfig = mcpServers[key.server] as? [String: Any],
               var env = serverConfig["env"] as? [String: String] {
                env[key.key] = "${KEYCHAIN:\(key.keychainName)}"
                serverConfig["env"] = env
                mcpServers[key.server] = serverConfig
            }
        }
        
        config["mcpServers"] = mcpServers
        
        // Write updated config
        if let updatedData = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
            try? updatedData.write(to: URL(fileURLWithPath: configPath))
            
            successMessage = "Protected \(successCount) API key(s) successfully!"
            showSuccessAlert = true
            
            // Refresh lists
            scanForKeys()
            loadProtectedKeys()
        }
    }
    
    private func viewProtectedKey(_ keyName: String) {
        authenticateToView { success in
            if success {
                if let value = getFromKeychain(name: keyName) {
                    keyValue = value
                    selectedProtectedKey = keyName
                }
            }
        }
    }
    
    private func deleteProtectedKey(_ keyName: String) {
        let service = "com.MCPSnitch.APIKeys"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyName
        ]
        
        if SecItemDelete(query as CFDictionary) == errSecSuccess {
            loadProtectedKeys()
        }
    }
    
    // MARK: - Helpers
    
    private func looksLikeAPIKey(key: String, value: String) -> Bool {
        let keyIndicators = ["key", "token", "secret", "password", "auth", "api", "credential"]
        let lowercaseKey = key.lowercased()
        for indicator in keyIndicators {
            if lowercaseKey.contains(indicator) && value.count > 10 {
                return true
            }
        }
        
        let patterns = [
            "^sk-[a-zA-Z0-9]{48}",
            "^ghp_[a-zA-Z0-9]{36}",
            "^github_pat_",
            "^xox[bp]-",
            "^[a-f0-9]{32,64}$"
        ]
        
        for pattern in patterns {
            if value.range(of: pattern, options: .regularExpression) != nil {
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
    
    private func getFromKeychain(name: String) -> String? {
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
    
    private func authenticateToView(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            let reason = "Authenticate to view API key"
            
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, authError in
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        } else {
            completion(true)
        }
    }
}

// MARK: - Components

struct HeaderView: View {
    var body: some View {
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
    }
}

struct HowItWorksSection: View {
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("How It Works", systemImage: "info.circle")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text("1.")
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                        Text("MCPSnitch scans your Claude config for plaintext API keys")
                    }
                    
                    HStack(alignment: .top) {
                        Text("2.")
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                        Text("Click 'Move to Keychain' to automatically protect them")
                    }
                    
                    HStack(alignment: .top) {
                        Text("3.")
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                        Text("Keys are stored securely and replaced with ${KEYCHAIN:name} variables")
                    }
                    
                    HStack(alignment: .top) {
                        Text("4.")
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                        Text("The MCP proxy automatically substitutes values at runtime")
                    }
                }
                .font(.caption)
            }
        }
    }
}

struct UnprotectedKeysSection: View {
    @Binding var unprotectedKeys: [(server: String, key: String, value: String, keychainName: String)]
    let onProtect: () -> Void
    let onRefresh: () -> Void
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Unprotected Keys", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundColor(.orange)
                    
                    Spacer()
                    
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
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
                            UnprotectedKeyRow(
                                server: key.server,
                                keyName: key.key,
                                value: key.value,
                                keychainName: key.keychainName
                            )
                        }
                    }
                    
                    Button(action: onProtect) {
                        Label("Move All to Keychain", systemImage: "lock.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }
}

struct UnprotectedKeyRow: View {
    let server: String
    let keyName: String
    let value: String
    let keychainName: String
    
    private var maskedValue: String {
        if value.count > 10 {
            return String(value.prefix(6)) + "..." + String(value.suffix(4))
        }
        return String(repeating: "•", count: value.count)
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(server)
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(keyName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(maskedValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.orange)
                
                Text("→ ${KEYCHAIN:\(keychainName)}")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)
            }
            
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(6)
    }
}

struct ProtectedKeysSection: View {
    @Binding var protectedKeys: [(name: String, server: String)]
    let onView: (String) -> Void
    let onDelete: (String) -> Void
    let onRefresh: () -> Void
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Protected Keys", systemImage: "lock.fill")
                        .font(.headline)
                        .foregroundColor(.green)
                    
                    Spacer()
                    
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
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
                            ProtectedKeyRow(
                                name: key.name,
                                server: key.server,
                                onView: { onView(key.name) },
                                onDelete: { onDelete(key.name) },
                                onCopy: {
                                    let usage = "${KEYCHAIN:\(key.name)}"
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(usage, forType: .string)
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

struct ProtectedKeyRow: View {
    let name: String
    let server: String
    let onView: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "lock.fill")
                .foregroundColor(.green)
                .font(.caption)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                
                Text("${KEYCHAIN:\(name)}")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy usage")
            
            Button(action: onView) {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("View key")
            
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete key")
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct ViewKeySheet: View {
    let keyName: String
    let keyValue: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("API Key Value")
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 8) {
                Text(keyName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ScrollView {
                    Text(keyValue)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
                .frame(height: 100)
            }
            
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(keyValue, forType: .string)
                }
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 500)
    }
}

extension String: Identifiable {
    public var id: String { self }
}