import SwiftUI
import LocalAuthentication

struct KeychainKeysView: View {
    @StateObject private var keychainManager = KeychainManager.shared
    @State private var keys: [String] = []
    @State private var showAddKey = false
    @State private var newKeyName = ""
    @State private var newKeyValue = ""
    @State private var newKeyDescription = ""
    @State private var selectedKey: String?
    @State private var showKeyValue = false
    @State private var keyValue = ""
    @State private var showDeleteConfirmation = false
    @State private var keyToDelete: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keychain API Keys")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Securely store API keys that can be referenced in MCP configurations")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { showAddKey = true }) {
                    Label("Add Key", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Instructions
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("How to use Keychain keys in MCP configs:", systemImage: "info.circle")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Text("Replace hardcoded API keys in your Claude config with:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("${KEYCHAIN:keyname}")
                        .font(.system(.caption, design: .monospaced))
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                    
                    Text("Example: \"GITHUB_PERSONAL_ACCESS_TOKEN\": \"${KEYCHAIN:github_token}\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            
            // Keys List
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(keys, id: \.self) { key in
                        KeyRow(
                            keyName: key,
                            onView: { viewKey(key) },
                            onDelete: { confirmDelete(key) },
                            onCopy: { copyUsage(key) }
                        )
                    }
                    
                    if keys.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "key.slash")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            
                            Text("No API keys stored")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            
                            Text("Add API keys to use them in MCP server configurations")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
                .padding()
            }
        }
        .frame(width: 600, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { loadKeys() }
        .sheet(isPresented: $showAddKey) {
            AddKeyView(
                keyName: $newKeyName,
                keyValue: $newKeyValue,
                keyDescription: $newKeyDescription,
                onSave: saveNewKey,
                onCancel: { showAddKey = false }
            )
        }
        .sheet(item: $selectedKey) { key in
            ViewKeySheet(keyName: key, keyValue: keyValue)
        }
        .alert("Delete Key?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let key = keyToDelete {
                    deleteKey(key)
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(keyToDelete ?? "")'? This action cannot be undone.")
        }
    }
    
    private func loadKeys() {
        keys = keychainManager.listKeys()
    }
    
    private func saveNewKey() {
        guard !newKeyName.isEmpty, !newKeyValue.isEmpty else { return }
        
        if keychainManager.saveKey(name: newKeyName, value: newKeyValue) {
            loadKeys()
            newKeyName = ""
            newKeyValue = ""
            newKeyDescription = ""
            showAddKey = false
        }
    }
    
    private func viewKey(_ key: String) {
        authenticateToView { success in
            if success, let value = keychainManager.getKey(name: key) {
                keyValue = value
                selectedKey = key
            }
        }
    }
    
    private func confirmDelete(_ key: String) {
        keyToDelete = key
        showDeleteConfirmation = true
    }
    
    private func deleteKey(_ key: String) {
        if keychainManager.deleteKey(name: key) {
            loadKeys()
        }
    }
    
    private func copyUsage(_ key: String) {
        let usage = "${KEYCHAIN:\(key)}"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(usage, forType: .string)
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

struct KeyRow: View {
    let keyName: String
    let onView: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "key.fill")
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(keyName)
                    .font(.system(.body, design: .monospaced))
                
                Text("${KEYCHAIN:\(keyName)}")
                    .font(.caption)
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
            .help("View key value")
            
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete key")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct AddKeyView: View {
    @Binding var keyName: String
    @Binding var keyValue: String
    @Binding var keyDescription: String
    let onSave: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Add API Key to Keychain")
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., github_token", text: $keyName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.system(.body, design: .monospaced))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key Value")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("API key value", text: $keyValue)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.system(.body, design: .monospaced))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage in Config")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("${KEYCHAIN:\(keyName.isEmpty ? "keyname" : keyName)}")
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                }
            }
            
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Save to Keychain", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(keyName.isEmpty || keyValue.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 400)
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