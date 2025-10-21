import SwiftUI

struct TrustedServersView: View {
    @State private var trustedServers: [TrustedServer] = []
    @State private var showingImportDialog = false
    @State private var showingExportDialog = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
                    .font(.title2)
                Text("Trusted MCP Servers")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                
                // Export/Import buttons
                Button(action: exportServers) {
                    Image(systemName: "square.and.arrow.up")
                        .help("Export trusted servers")
                }
                .buttonStyle(PlainButtonStyle())
                
                Button(action: { showingImportDialog = true }) {
                    Image(systemName: "square.and.arrow.down")
                        .help("Import trusted servers")
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Server List
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(filteredServers.enumerated()), id: \.offset) { index, server in
                        if !server.name.isEmpty && !server.identifier.isEmpty {
                            TrustedServerRow(server: server, onRemove: {
                                removeTrustedServer(server)
                            })
                            .onAppear {
                                print("Displaying server \(index): \(server.name)")
                            }
                        }
                    }
                    
                    if filteredServers.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 10) {
                                Image(systemName: "shield.slash")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("No trusted servers")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                Text("Trust servers from the main menu")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(40)
                            Spacer()
                        }
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Footer
            HStack {
                Text("\(trustedServers.count) trusted servers")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh") {
                    loadTrustedServers()
                }
                .buttonStyle(LinkButtonStyle())
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 500, height: 400)
        .onAppear {
            loadTrustedServers()
        }
        .fileImporter(
            isPresented: $showingImportDialog,
            allowedContentTypes: [.json],
            onCompletion: handleImport
        )
    }
    
    private var filteredServers: [TrustedServer] {
        return trustedServers
    }
    
    private func loadTrustedServers() {
        trustedServers = TrustDatabase.shared.getAllTrustedServers()
        print("Loaded \(trustedServers.count) trusted servers")
        for server in trustedServers {
            print("  - \(server.name): type=\(server.type), identifier=\(server.identifier)")
        }
    }
    
    private func removeTrustedServer(_ server: TrustedServer) {
        print("Removing server: \(server.name) with identifier: \(server.identifier)")
        if TrustDatabase.shared.removeTrustedServer(name: server.name, identifier: server.identifier) {
            print("Successfully removed server from database")
            loadTrustedServers()
        } else {
            print("Failed to remove server from database")
        }
    }
    
    private func exportServers() {
        guard let data = TrustDatabase.shared.exportTrustedServers() else { return }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "trusted_servers_\(Date().timeIntervalSince1970).json"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? data.write(to: url)
        }
    }
    
    private func handleImport(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            if let data = try? Data(contentsOf: url) {
                if TrustDatabase.shared.importTrustedServers(from: data) {
                    loadTrustedServers()
                }
            }
        case .failure(let error):
            print("Import error: \(error)")
        }
    }
}

struct TrustedServerRow: View {
    let server: TrustedServer
    let onRemove: () -> Void
    @State private var isHovering = false
    
    init(server: TrustedServer, onRemove: @escaping () -> Void) {
        self.server = server
        self.onRemove = onRemove
        print("TrustedServerRow init - name: \(server.name), type: \(server.type), identifier: \(server.identifier)")
    }
    
    var serverIcon: String {
        switch server.type.lowercased() {
        case "url":
            return "globe"
        case "npx":
            return "terminal"
        case "local":
            return "doc.text.fill"
        case "docker":
            return "shippingbox.fill"
        default:
            return "questionmark.circle"
        }
    }
    
    var serverColor: Color {
        switch server.type.lowercased() {
        case "url":
            return .blue
        case "npx":
            return .orange
        case "local":
            return .green
        case "docker":
            return .purple
        default:
            return .gray
        }
    }
    
    var body: some View {
        HStack {
            Image(systemName: serverIcon)
                .foregroundColor(serverColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .fontWeight(.medium)
                Text(server.identifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text(server.type.uppercased())
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(serverColor.opacity(0.2))
                    .cornerRadius(4)
                
                Text(formatDate(server.trustedAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red.opacity(isHovering ? 1.0 : 0.6))
            }
            .buttonStyle(PlainButtonStyle())
            .help("Remove trust")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    TrustedServersView()
}