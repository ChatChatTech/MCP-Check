import SwiftUI
import LocalAuthentication
import AppKit

struct GuardRailsView: View {
    @StateObject private var guardRails = GuardRailsManager.shared
    @State private var securityPrompt: String = GuardRailsManager.shared.securityPrompt
    @State private var toolControlMode: ToolControlMode = GuardRailsManager.shared.toolControlMode
    @State private var securityDetectionMode: SecurityDetectionMode = GuardRailsManager.shared.securityDetectionMode
    @State private var claudeAPIKey: String = GuardRailsManager.shared.claudeAPIKey ?? ""
    @State private var openAIAPIKey: String = GuardRailsManager.shared.openAIAPIKey ?? ""
    @State private var useAI = GuardRailsManager.shared.useAI
    @State private var aiProvider = GuardRailsManager.shared.aiProvider
    @State private var showClaudeKey = false
    @State private var showOpenAIKey = false
    @State private var showSuccessAlert = false
    @State private var isSaved = false
    @State private var selectedTab = "security"
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Guard Rails Configuration")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Configure security policies for MCP server interactions")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // Tab Selection
            Picker("", selection: $selectedTab) {
                Text("Security").tag("security")
                Text("AI Analysis").tag("ai")
                Text("Patterns & Prompt").tag("patterns")
                Text("Whitelist").tag("whitelist")
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            
            Divider()
            
            // Tab Content
            TabView(selection: $selectedTab) {
                // Security Tab
                SecurityTabView(toolControlMode: $toolControlMode, securityDetectionMode: $securityDetectionMode)
                    .tag("security")
                
                // AI Analysis Tab
                AIAnalysisTabView(
                    useAI: $useAI,
                    aiProvider: $aiProvider,
                    claudeAPIKey: $claudeAPIKey,
                    openAIAPIKey: $openAIAPIKey,
                    showClaudeKey: $showClaudeKey,
                    showOpenAIKey: $showOpenAIKey,
                    toolControlMode: toolControlMode
                )
                    .tag("ai")
                
                // Patterns & Prompt Tab
                PatternsPromptTabView(securityPrompt: $securityPrompt)
                    .tag("patterns")
                
                // Whitelist Tab
                WhitelistTabView()
                    .tag("whitelist")
            }
            .tabViewStyle(.automatic)
            
            Divider()
            
            // Action Buttons with Enhanced Visual Feedback
            VStack(spacing: 0) {
                if isSaved {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                        Text("Configuration saved successfully")
                            .foregroundColor(.green)
                            .font(.headline)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green.opacity(0.1))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                HStack(spacing: 12) {
                    Button("View Audit Log") {
                        openAuditLog()
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    if !isSaved {
                        Button("Cancel") {
                            closeWindow()
                        }
                        .keyboardShortcut(.escape)
                        
                        Button("Save Configuration") {
                            saveConfiguration()
                        }
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Done") {
                            closeWindow()
                        }
                        .keyboardShortcut(.return)
                        .buttonStyle(.borderedProminent)
                        .frame(minWidth: 100)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .frame(width: 700, height: 600)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    
    func saveConfiguration() {
        guardRails.securityPrompt = securityPrompt
        guardRails.toolControlMode = toolControlMode
        guardRails.securityDetectionMode = securityDetectionMode
        guardRails.useAI = useAI
        guardRails.aiProvider = aiProvider
        
        // Save API keys securely
        if useAI {
            if aiProvider == .claude && !claudeAPIKey.isEmpty {
                guardRails.saveClaudeAPIKey(claudeAPIKey)
            } else if aiProvider == .openai && !openAIAPIKey.isEmpty {
                guardRails.saveOpenAIAPIKey(openAIAPIKey)
            }
        }
        
        guardRails.saveConfiguration()
        
        // Show success state
        withAnimation {
            isSaved = true
        }
        
        // Auto-dismiss after 2 seconds if desired
        // DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        //     closeWindow()
        // }
    }
    
    func openAuditLog() {
        let logWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        logWindow.title = "Guard Rails Audit Log"
        logWindow.contentView = NSHostingView(rootView: AuditLogView())
        logWindow.center()
        logWindow.isReleasedWhenClosed = false  // Prevent window from being released
        logWindow.level = .floating  // Keep it above other windows
        logWindow.makeKeyAndOrderFront(nil)
    }
    
    func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

// MARK: - Blocked Patterns Editor
struct BlockedPatternsEditor: View {
    @StateObject private var guardRails = GuardRailsManager.shared
    @State private var newPattern = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add patterns to automatically block:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Pattern list
            if !guardRails.blockedPatterns.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(guardRails.blockedPatterns, id: \.self) { pattern in
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                                
                                Text(pattern)
                                    .font(.system(.body, design: .monospaced))
                                
                                Spacer()
                                
                                Button(action: {
                                    guardRails.removeBlockedPattern(pattern)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(4)
                        }
                    }
                }
                .frame(maxHeight: 100)
                
                Divider()
            }
            
            // Add new pattern
            HStack {
                TextField("Add pattern (e.g., rm -rf, eval(), etc.)", text: $newPattern)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button("Add") {
                    if !newPattern.isEmpty {
                        guardRails.addBlockedPattern(newPattern)
                        newPattern = ""
                    }
                }
                .disabled(newPattern.isEmpty)
            }
        }
    }
}

// MARK: - Audit Log View
struct AuditLogView: View {
    @StateObject private var guardRails = GuardRailsManager.shared
    @State private var filterText = ""
    @State private var showOnlyBlocked = false
    
    var filteredEntries: [GuardRailsAuditEntry] {
        guardRails.auditLog.filter { entry in
            let matchesFilter = filterText.isEmpty || 
                entry.message.localizedCaseInsensitiveContains(filterText) ||
                entry.serverName.localizedCaseInsensitiveContains(filterText)
            
            let matchesBlocked = !showOnlyBlocked || entry.wasBlocked
            
            return matchesFilter && matchesBlocked
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Guard Rails Audit Log")
                    .font(.headline)
                
                Spacer()
                
                Toggle("Show blocked only", isOn: $showOnlyBlocked)
                    .toggleStyle(.checkbox)
                
                Button("Export") {
                    exportLog()
                }
                .buttonStyle(.bordered)
                
                Button("Clear Log") {
                    guardRails.clearAuditLog()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // Filter
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter log entries...", text: $filterText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Log entries
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredEntries) { entry in
                        AuditLogRow(entry: entry)
                    }
                }
                .padding()
            }
            .background(Color(NSColor.textBackgroundColor))
            
            // Stats bar
            HStack {
                Label("\(filteredEntries.count) entries", systemImage: "doc.text")
                    .font(.caption)
                Spacer()
                Label("\(guardRails.blockedCount) blocked", systemImage: "xmark.shield")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 900, height: 700)
    }
    
    func exportLog() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "guardrails_audit.json"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            guardRails.exportAuditLog(to: url)
        }
    }
}

// MARK: - Tab Views

struct SecurityTabView: View {
    @Binding var toolControlMode: ToolControlMode
    @Binding var securityDetectionMode: SecurityDetectionMode
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Tool Control System
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "app.badge.checkmark")
                                .font(.title2)
                                .foregroundColor(.blue)
                            Text("Tool Control")
                                .font(.headline)
                            Text("(Whitelist/Blacklist)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Mode", selection: $toolControlMode) {
                                ForEach(ToolControlMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            
                            Text(toolControlMode.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                            
                            if toolControlMode == .approveNew {
                                HStack {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.blue)
                                    Text("You'll be prompted when new tools are used for the first time")
                                        .font(.caption)
                                }
                                .padding(8)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(6)
                            }
                            
                            if toolControlMode == .strict {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundColor(.orange)
                                    Text("Only whitelisted tools will be allowed. All others blocked.")
                                        .font(.caption)
                                }
                                .padding(8)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                
                Divider()
                
                // Security Detection System
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.title2)
                                .foregroundColor(.red)
                            Text("Security Detection")
                                .font(.headline)
                            Text("(Malicious Activity)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Mode", selection: $securityDetectionMode) {
                                ForEach(SecurityDetectionMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            
                            Text(securityDetectionMode.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                            
                            if securityDetectionMode != .off {
                                HStack {
                                    Image(systemName: "brain")
                                        .foregroundColor(.purple)
                                    Text("Uses AI and pattern matching to detect threats")
                                        .font(.caption)
                                }
                                .padding(8)
                                .background(Color.purple.opacity(0.1))
                                .cornerRadius(6)
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                
                // Quick Reference
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "lightbulb.fill")
                                .font(.title2)
                                .foregroundColor(.yellow)
                            Text("How They Work Together")
                                .font(.headline)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Tool Control manages which tools can run", systemImage: "1.circle.fill")
                                .font(.caption)
                            Label("Security Detection analyzes tool behavior for threats", systemImage: "2.circle.fill")
                                .font(.caption)
                            Label("Both can work independently or together", systemImage: "3.circle.fill")
                                .font(.caption)
                        }
                        
                        Divider()
                        
                        Text("Example: You might allow all tools (Tool Control: Off) but still want to detect malicious patterns (Security Detection: Block)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                }
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
            .padding()
        }
    }
    
}

struct AIAnalysisTabView: View {
    @Binding var useAI: Bool
    @Binding var aiProvider: AIProvider
    @Binding var claudeAPIKey: String
    @Binding var openAIAPIKey: String
    @Binding var showClaudeKey: Bool
    @Binding var showOpenAIKey: Bool
    let toolControlMode: ToolControlMode
    
    private func authenticateToViewKey(keyType: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        
        // Check if biometric authentication is available
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            let reason = "Authenticate to view \(keyType) API key"
            
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, authError in
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        } else {
            // Biometric auth not available, just allow
            completion(true)
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "brain")
                                .font(.title2)
                                .foregroundColor(.purple)
                            Text("AI Security Analysis")
                                .font(.headline)
                        }
                        
                        Toggle("Use AI for advanced security analysis", isOn: $useAI)
                        
                        if useAI {
                            Divider()
                            
                            // AI Provider Selection
                            VStack(alignment: .leading, spacing: 8) {
                                Text("AI Provider")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Picker("", selection: $aiProvider) {
                                    ForEach(AIProvider.allCases, id: \.self) { provider in
                                        Text(provider.displayName).tag(provider)
                                    }
                                }
                                .pickerStyle(SegmentedPickerStyle())
                            }
                            
                            // Claude API Key
                            if aiProvider == .claude {
                                Divider()
                                
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Claude API Key")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    HStack {
                                        if showClaudeKey {
                                            TextField("sk-ant-...", text: $claudeAPIKey)
                                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                                .font(.system(.body, design: .monospaced))
                                        } else {
                                            SecureField("sk-ant-...", text: $claudeAPIKey)
                                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                                .font(.system(.body, design: .monospaced))
                                        }
                                        
                                        Button(action: { 
                                            if !showClaudeKey {
                                                authenticateToViewKey(keyType: "Claude") { success in
                                                    if success {
                                                        showClaudeKey = true
                                                    }
                                                }
                                            } else {
                                                showClaudeKey = false
                                            }
                                        }) {
                                            Image(systemName: showClaudeKey ? "eye.slash" : "eye")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    
                                    HStack {
                                        Text("Stored securely in macOS Keychain")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        Spacer()
                                        
                                        Link("Get API Key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                                            .font(.caption)
                                    }
                                    
                                    Text("Using Claude 3 Haiku for fast, cost-effective analysis")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            // OpenAI API Key
                            if aiProvider == .openai {
                                Divider()
                                
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("OpenAI API Key")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    HStack {
                                        if showOpenAIKey {
                                            TextField("sk-...", text: $openAIAPIKey)
                                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                                .font(.system(.body, design: .monospaced))
                                        } else {
                                            SecureField("sk-...", text: $openAIAPIKey)
                                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                                .font(.system(.body, design: .monospaced))
                                        }
                                        
                                        Button(action: { 
                                            if !showOpenAIKey {
                                                authenticateToViewKey(keyType: "OpenAI") { success in
                                                    if success {
                                                        showOpenAIKey = true
                                                    }
                                                }
                                            } else {
                                                showOpenAIKey = false
                                            }
                                        }) {
                                            Image(systemName: showOpenAIKey ? "eye.slash" : "eye")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    
                                    HStack {
                                        Text("Stored securely in macOS Keychain")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        Spacer()
                                        
                                        Link("Get API Key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                                            .font(.caption)
                                    }
                                    
                                    Text("Using GPT-4o Mini for efficient analysis")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
            .padding()
        }
    }
}

struct PatternsPromptTabView: View {
    @Binding var securityPrompt: String
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Security Prompt Editor
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .font(.title2)
                                .foregroundColor(.green)
                            Text("Security Analysis Prompt")
                                .font(.headline)
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Customize the prompt used to analyze MCP requests:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            TextEditor(text: $securityPrompt)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 120)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                            
                            HStack {
                                Button("Reset to Default") {
                                    securityPrompt = GuardRailsManager.defaultPrompt
                                }
                                .buttonStyle(.borderless)
                                
                                Spacer()
                                
                                Text("\(securityPrompt.count) characters")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                
                // Blocked Patterns
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "xmark.shield.fill")
                                .font(.title2)
                                .foregroundColor(.red)
                            Text("Blocked Patterns")
                                .font(.headline)
                        }
                        
                        BlockedPatternsEditor()
                    }
                    .padding(12)
                }
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
            .padding()
        }
    }
}

// MARK: - Whitelist Tab View

struct WhitelistTabView: View {
    @StateObject private var guardRails = GuardRailsManager.shared
    @State private var selectedSection = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Section Selector
            Picker("", selection: $selectedSection) {
                Text("Whitelisted Tools").tag(0)
                Text("Blacklisted Tools").tag(1)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding()
            
            Divider()
            
            if selectedSection == 0 {
                // Whitelisted Tools
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if guardRails.whitelistedTools.isEmpty {
                            Text("No whitelisted tools yet")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        } else {
                            ForEach(Array(guardRails.whitelistedTools).sorted(by: { $0.identifier < $1.identifier }), id: \.self) { entry in
                                HStack {
                                    Image(systemName: "checkmark.shield.fill")
                                        .foregroundColor(.green)
                                    
                                    VStack(alignment: .leading) {
                                        Text(entry.identifier)
                                            .font(.system(.body, design: .monospaced))
                                        Text("Added: \(entry.addedAt, style: .date)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Button("Remove") {
                                        guardRails.removeFromWhitelist(
                                            serverName: entry.serverName,
                                            toolName: entry.toolName
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(8)
                                .background(Color.green.opacity(0.05))
                                .cornerRadius(8)
                            }
                        }
                        
                        Button("Clear All Whitelisted") {
                            guardRails.clearWhitelist()
                        }
                        .buttonStyle(.bordered)
                        .disabled(guardRails.whitelistedTools.isEmpty)
                        .padding(.top)
                    }
                    .padding()
                }
            } else {
                // Blacklisted Tools
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if guardRails.blacklistedTools.isEmpty {
                            Text("No blacklisted tools yet")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        } else {
                            ForEach(Array(guardRails.blacklistedTools).sorted(by: { $0.identifier < $1.identifier }), id: \.self) { entry in
                                HStack {
                                    Image(systemName: "xmark.shield.fill")
                                        .foregroundColor(.red)
                                    
                                    VStack(alignment: .leading) {
                                        Text(entry.identifier)
                                            .font(.system(.body, design: .monospaced))
                                        Text("Added: \(entry.addedAt, style: .date)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Button("Remove") {
                                        guardRails.removeFromBlacklist(
                                            serverName: entry.serverName,
                                            toolName: entry.toolName
                                        )
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(8)
                                .background(Color.red.opacity(0.05))
                                .cornerRadius(8)
                            }
                        }
                        
                        Button("Clear All Blacklisted") {
                            guardRails.clearBlacklist()
                        }
                        .buttonStyle(.bordered)
                        .disabled(guardRails.blacklistedTools.isEmpty)
                        .padding(.top)
                    }
                    .padding()
                }
            }
        }
    }
}

struct AuditLogRow: View {
    let entry: GuardRailsAuditEntry
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Severity indicator
                Image(systemName: entry.wasBlocked ? "xmark.shield.fill" : "checkmark.shield")
                    .foregroundColor(entry.wasBlocked ? .red : .green)
                
                // Server name
                Text(entry.serverName)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                
                // Action
                Text(entry.action)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.2))
                    .cornerRadius(4)
                
                // Risk level
                if let riskLevel = entry.riskLevel {
                    Text(riskLevel)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(riskColor(for: riskLevel).opacity(0.2))
                        .cornerRadius(4)
                }
                
                Spacer()
                
                // Timestamp
                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Expand button
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Message:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .textSelection(.enabled)
                    
                    if let reason = entry.blockReason {
                        Text("Block Reason:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(reason)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(4)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(4)
                    }
                    
                    // Show AI Analysis info if available
                    if let aiAnalysis = entry.aiAnalysis {
                        Text("AI Analysis:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(aiAnalysis)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.blue)
                            .padding(4)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(entry.wasBlocked ? Color.red.opacity(0.05) : Color.clear)
        )
    }
    
    func riskColor(for level: String) -> Color {
        switch level.lowercased() {
        case "high": return .red
        case "medium": return .orange
        case "low": return .yellow
        default: return .gray
        }
    }
}