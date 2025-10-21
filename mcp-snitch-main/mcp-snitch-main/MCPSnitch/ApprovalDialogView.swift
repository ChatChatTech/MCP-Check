import SwiftUI
import AppKit

// MARK: - Tool Approval Dialog

enum ToolApprovalDecision {
    case approveOnce
    case approveAlways
    case block
    case blockAlways
}

struct ToolApprovalDialogView: View {
    let serverName: String
    let toolName: String
    let onDecision: (ToolApprovalDecision) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 12) {
            // Compact Header
            HStack {
                Image(systemName: "questionmark.app.fill")
                    .font(.title)
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tool Approval Required")
                        .font(.headline)
                        .fontWeight(.bold)
                    
                    Text("First use of this tool")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.1))
            
            // Tool Details
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Server:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .frame(width: 60, alignment: .trailing)
                        Text(serverName)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.blue)
                        Spacer()
                    }
                    
                    HStack {
                        Text("Tool:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .frame(width: 60, alignment: .trailing)
                        Text(toolName)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.purple)
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal)
            
            Spacer()
            
            // Action Buttons - More compact
            VStack(spacing: 10) {
                // Approval options
                HStack(spacing: 10) {
                    Button(action: {
                        onDecision(.approveOnce)
                    }) {
                        Label("Once", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    
                    Button(action: {
                        onDecision(.approveAlways)
                    }) {
                        Label("Always", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(.green)
                }
                
                // Block options
                HStack(spacing: 10) {
                    Button(action: {
                        onDecision(.block)
                    }) {
                        Label("Block", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.orange)
                    
                    Button(action: {
                        onDecision(.blockAlways)
                    }) {
                        Label("Never", systemImage: "xmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.red)
                }
            }
            .padding()
        }
        .frame(width: 400, height: 260)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Security Approval Dialog (existing)

struct ApprovalDialogView: View {
    let serverName: String
    let message: ProxyMessage
    let onDecision: (Bool) -> Void
    
    @State private var showFullMessage = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "hand.raised.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading) {
                    Text("Security Approval Required")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Review and approve this MCP request")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            
            // Request Details
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    DetailRow(label: "Server", value: serverName, color: .blue)
                    
                    if let method = message.method {
                        DetailRow(label: "Method", value: method, color: .purple)
                    }
                    
                    DetailRow(
                        label: "Direction",
                        value: message.direction == .clientToServer ? "Client → Server" : "Server → Client",
                        color: message.direction == .clientToServer ? .blue : .green
                    )
                    
                    if let messageId = message.messageId {
                        DetailRow(label: "Request ID", value: "#\(messageId)", color: .gray)
                    }
                }
            }
            
            // Message Content
            GroupBox(label: Label("Message Content", systemImage: "doc.text")) {
                VStack(alignment: .leading) {
                    if showFullMessage {
                        ScrollView {
                            Text(formatJSON(message.content))
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 200)
                    } else {
                        Text(message.content.prefix(200) + "...")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    Button(showFullMessage ? "Show Less" : "Show Full Message") {
                        showFullMessage.toggle()
                    }
                    .buttonStyle(.link)
                }
            }
            
            // Risk Analysis
            if let risks = analyzeRisks() {
                GroupBox(label: Label("Risk Analysis", systemImage: "exclamationmark.shield")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(risks, id: \.self) { risk in
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                
                                Text(risk)
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color.orange.opacity(0.05))
            }
            
            Spacer()
            
            // Action Buttons
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Block This Request") {
                        onDecision(false)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.escape)
                    
                    Button("Allow This Request") {
                        onDecision(true)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return)
                }
                
                HStack(spacing: 12) {
                    Button("Always Allow from \(serverName)") {
                        // Add to trusted list
                        GuardRailsManager.shared.addTrustedForGuardRails(serverName)
                        onDecision(true)
                        dismiss()
                    }
                    .buttonStyle(.link)
                    
                    Button("Block & Add Pattern") {
                        // Extract pattern and add to block list
                        if let method = message.method {
                            GuardRailsManager.shared.addBlockedPattern(method)
                        }
                        onDecision(false)
                        dismiss()
                    }
                    .buttonStyle(.link)
                    .foregroundColor(.red)
                }
                .font(.caption)
            }
            .padding()
        }
        .frame(width: 600, height: 650)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    func analyzeRisks() -> [String]? {
        var risks: [String] = []
        
        let content = message.content.lowercased()
        
        // Check for dangerous operations
        if content.contains("rm ") || content.contains("delete") {
            risks.append("File deletion operation detected")
        }
        
        if content.contains("eval") || content.contains("exec") {
            risks.append("Code execution detected")
        }
        
        if content.contains("password") || content.contains("token") || content.contains("secret") {
            risks.append("Potential credential exposure")
        }
        
        if content.contains("../") || content.contains("..\\") {
            risks.append("Path traversal attempt detected")
        }
        
        if content.contains("/etc/") || content.contains("/system/") || content.contains("c:\\windows") {
            risks.append("Access to system directories")
        }
        
        return risks.isEmpty ? nil : risks
    }
    
    func formatJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
              let result = String(data: formatted, encoding: .utf8) else {
            return json
        }
        return result
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(color)
            
            Spacer()
        }
    }
}

// Extension to GuardRailsManager for trusted servers
extension GuardRailsManager {
    private var trustedForGuardRailsKey: String { "GuardRailsTrustedServers" }
    
    func addTrustedForGuardRails(_ serverName: String) {
        var trusted = UserDefaults.standard.array(forKey: trustedForGuardRailsKey) as? [String] ?? []
        if !trusted.contains(serverName) {
            trusted.append(serverName)
            UserDefaults.standard.set(trusted, forKey: trustedForGuardRailsKey)
        }
    }
    
    func isTrustedForGuardRails(_ serverName: String) -> Bool {
        let trusted = UserDefaults.standard.array(forKey: trustedForGuardRailsKey) as? [String] ?? []
        return trusted.contains(serverName)
    }
}