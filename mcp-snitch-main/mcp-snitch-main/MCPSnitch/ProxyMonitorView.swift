import SwiftUI
import Combine

struct ProxyMonitorView: View {
    let serverName: String
    @StateObject private var monitor = ProxyMonitor()
    @State private var filterText = ""
    @State private var showOnlyBlocked = false
    @State private var autoScroll = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("MCP Traffic Monitor: \(serverName)")
                    .font(.headline)
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Toggle("Blocked only", isOn: $showOnlyBlocked)
                    .toggleStyle(.checkbox)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // Filter bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter messages...", text: $filterText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                if !filterText.isEmpty {
                    Button(action: { filterText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Message list
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredMessages) { message in
                            MessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: monitor.messages.count) { _ in
                    if autoScroll, let lastMessage = filteredMessages.last {
                        withAnimation {
                            scrollProxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Stats bar
            HStack {
                Label("\(filteredMessages.count) messages", systemImage: "envelope")
                    .font(.caption)
                Spacer()
                Label("\(monitor.blockedCount) blocked", systemImage: "xmark.shield")
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
                Button("Clear") {
                    monitor.clearMessages()
                }
                .buttonStyle(.borderless)
                Button("Export") {
                    exportMessages()
                }
                .buttonStyle(.borderless)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 800, height: 600)
        .onAppear {
            monitor.startMonitoring(for: serverName)
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }
    
    var filteredMessages: [ProxyMessage] {
        if filterText.isEmpty && !showOnlyBlocked {
            return monitor.messages
        }
        
        return monitor.messages.filter { message in
            let matchesFilter = filterText.isEmpty || 
                message.content.localizedCaseInsensitiveContains(filterText) ||
                message.method?.localizedCaseInsensitiveContains(filterText) == true
            
            let matchesBlocked = !showOnlyBlocked || message.wasBlocked
            
            return matchesFilter && matchesBlocked
        }
    }
    
    func exportMessages() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "\(serverName)_mcp_traffic.json"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            monitor.exportMessages(to: url)
        }
    }
}

struct MessageRow: View {
    let message: ProxyMessage
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Direction indicator
                Image(systemName: message.direction == .clientToServer ? "arrow.right.circle.fill" : "arrow.left.circle.fill")
                    .foregroundColor(message.direction == .clientToServer ? .blue : .green)
                    .font(.system(size: 12))
                
                // Method or result/error
                Text(message.method ?? (message.isError ? "Error" : "Result"))
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                
                // ID badge
                if let messageId = message.messageId {
                    Text("#\(messageId)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                
                // Blocked indicator
                if message.wasBlocked {
                    Label("Blocked", systemImage: "xmark.shield.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                Spacer()
                
                // Timestamp
                Text(message.timestamp, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Expand/collapse button
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            if isExpanded {
                Text(formatJSON(message.content))
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(message.wasBlocked ? Color.orange.opacity(0.1) : Color.clear)
        )
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

// MARK: - Proxy Monitor Model

class ProxyMonitor: ObservableObject {
    @Published var messages: [ProxyMessage] = []
    @Published var blockedCount = 0
    
    private var cancellables = Set<AnyCancellable>()
    private var serverName: String?
    
    func startMonitoring(for server: String) {
        self.serverName = server
        
        // Load historical logs first
        loadHistoricalLogs(for: server)
        
        // Then listen for new proxy messages
        NotificationCenter.default.publisher(for: Notification.Name("MCPProxyMessageReceived"))
            .sink { [weak self] notification in
                guard let self = self,
                      let userInfo = notification.userInfo,
                      let notificationServer = userInfo["server"] as? String,
                      notificationServer == server,
                      let direction = userInfo["direction"] as? String,
                      let content = userInfo["content"] as? String else {
                    return
                }
                
                self.handleProxyMessage(direction: direction, content: content)
            }
            .store(in: &cancellables)
    }
    
    private func loadHistoricalLogs(for server: String) {
        let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MCPSnitch")
            .appendingPathComponent("logs")
        let logPath = logDir.appendingPathComponent("\(server)_proxy.log")
        
        guard let logContent = try? String(contentsOf: logPath, encoding: .utf8) else {
            return
        }
        
        // Parse log entries
        let lines = logContent.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            // Parse log format: [timestamp] [server] [direction] content
            if let match = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\s+\[([^\]]+)\]\s+\[([^\]]+)\]\s+(.+)"#)
                .firstMatch(in: line, range: NSRange(location: 0, length: line.count)) {
                
                let nsLine = line as NSString
                if match.numberOfRanges == 5 {
                    let timestampStr = nsLine.substring(with: match.range(at: 1))
                    let direction = nsLine.substring(with: match.range(at: 3))
                    let content = nsLine.substring(with: match.range(at: 4))
                    
                    // Parse timestamp
                    let formatter = ISO8601DateFormatter()
                    let timestamp = formatter.date(from: timestampStr) ?? Date()
                    
                    let proxyMessage = ProxyMessage(
                        direction: direction.contains("CLIENT") ? .clientToServer : .serverToClient,
                        content: content,
                        timestamp: timestamp
                    )
                    
                    // Parse JSON to extract method and ID
                    if let data = content.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        proxyMessage.method = json["method"] as? String
                        if let id = json["id"] {
                            proxyMessage.messageId = "\(id)"
                        }
                        if json["error"] != nil {
                            proxyMessage.isError = true
                        }
                    }
                    
                    // Check if it was blocked
                    if direction == "PROXY->CLIENT" && content.contains("blocked by MCP Snitch") {
                        proxyMessage.wasBlocked = true
                        blockedCount += 1
                    }
                    
                    messages.append(proxyMessage)
                }
            }
        }
        
        // Keep only last 1000 messages
        if messages.count > 1000 {
            messages = Array(messages.suffix(1000))
        }
    }
    
    func stopMonitoring() {
        cancellables.removeAll()
    }
    
    func clearMessages() {
        messages.removeAll()
        blockedCount = 0
    }
    
    func exportMessages(to url: URL) {
        let exportData = messages.map { message in
            [
                "timestamp": ISO8601DateFormatter().string(from: message.timestamp),
                "direction": message.direction.rawValue,
                "method": message.method ?? "",
                "id": message.messageId ?? "",
                "content": message.content,
                "wasBlocked": message.wasBlocked
            ]
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted) {
            try? data.write(to: url)
        }
    }
    
    private func handleProxyMessage(direction: String, content: String) {
        let proxyMessage = ProxyMessage(
            direction: direction.contains("CLIENT") ? .clientToServer : .serverToClient,
            content: content,
            timestamp: Date()
        )
        
        // Parse JSON to extract method and ID
        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            proxyMessage.method = json["method"] as? String
            if let id = json["id"] {
                proxyMessage.messageId = "\(id)"
            }
            if json["error"] != nil {
                proxyMessage.isError = true
            }
        }
        
        // Check if it was blocked
        if direction == "PROXY->CLIENT" && content.contains("blocked by MCP Snitch") {
            proxyMessage.wasBlocked = true
            blockedCount += 1
        }
        
        DispatchQueue.main.async {
            self.messages.append(proxyMessage)
            
            // Keep only last 1000 messages
            if self.messages.count > 1000 {
                self.messages.removeFirst(self.messages.count - 1000)
            }
        }
    }
}

// MARK: - Models

class ProxyMessage: Identifiable, ObservableObject {
    let id = UUID()
    let direction: MessageDirection
    var content: String
    let timestamp: Date
    var method: String?
    var messageId: String?
    var wasBlocked = false
    var isError = false
    
    init(direction: MessageDirection, content: String, timestamp: Date) {
        self.direction = direction
        self.content = content
        self.timestamp = timestamp
    }
}

enum MessageDirection: String {
    case clientToServer = "CLIENT->SERVER"
    case serverToClient = "SERVER->CLIENT"
}