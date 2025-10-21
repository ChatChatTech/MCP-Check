import Foundation
import Security
import os.log
import SQLite3

// Load shared security module (JSON-RPC types, security checks, etc.)

// MARK: - Line Buffer for proper JSON-RPC handling

class LineBuffer {
    private var buffer = Data()
    private let logger = Logger(subsystem: "com.MCPSnitch.proxy", category: "LineBuffer")
    
    func append(_ data: Data) {
        buffer.append(data)
    }
    
    func extractLines() -> [String] {
        var lines: [String] = []
        
        while let newlineIndex = buffer.firstIndex(of: 0x0A) { // \n character
            let lineData = buffer[..<newlineIndex]
            
            // Remove the line from buffer (including the newline)
            buffer.removeSubrange(...newlineIndex)
            
            // Convert to string, trimming any \r if present
            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r")) {
                if !line.isEmpty {
                    lines.append(line)
                }
            }
        }
        
        return lines
    }
    
    func hasPartialData() -> Bool {
        return !buffer.isEmpty
    }
    
    func clear() {
        buffer.removeAll()
    }
}

// Keychain helpers are now in mcp_security_common.swift

// MARK: - Proxy Configuration

class MCPProxy {
    let serverName: String
    let originalCommand: String
    let originalArgs: [String]
    let securityManager: MCPSecurityManager

    private let logger = Logger(subsystem: "com.MCPSnitch.proxy", category: "MCPProxy")
    private var serverProcess: Process?
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()

    // Line buffers for proper message handling
    private let clientBuffer = LineBuffer()
    private let serverBuffer = LineBuffer()

    init() {
        // Get configuration from environment variables
        self.serverName = ProcessInfo.processInfo.environment["MCP_SERVER_NAME"] ?? "unknown"
        self.originalCommand = ProcessInfo.processInfo.environment["MCP_ORIGINAL_COMMAND"] ?? ""

        // Parse args - try base64 first (new format), then JSON (old format)
        if let argsBase64 = ProcessInfo.processInfo.environment["MCP_ORIGINAL_ARGS_B64"],
           let argsData = Data(base64Encoded: argsBase64),
           let args = try? JSONSerialization.jsonObject(with: argsData) as? [String] {
            self.originalArgs = args
        } else if let argsJson = ProcessInfo.processInfo.environment["MCP_ORIGINAL_ARGS"] {
            // Fallback to JSON format for backward compatibility
            if let argsData = argsJson.data(using: .utf8) {
                do {
                    if let args = try JSONSerialization.jsonObject(with: argsData) as? [String] {
                        self.originalArgs = args
                    } else {
                        logger.error("Failed to parse args as string array")
                        self.originalArgs = []
                    }
                } catch {
                    logger.error("Failed to parse JSON args: \(error)")
                    self.originalArgs = []
                }
            } else {
                logger.error("Failed to convert args to data")
                self.originalArgs = []
            }
        } else {
            self.originalArgs = []
        }

        let logPath = ProcessInfo.processInfo.environment["MCP_LOG_PATH"] ?? "/tmp/mcp_proxy.log"

        // Determine server identifier for trust checks
        var serverIdentifier = ""
        if originalCommand == "docker" {
            for arg in self.originalArgs.reversed() {
                let cleanArg = arg.replacingOccurrences(of: "\\", with: "")
                if !cleanArg.starts(with: "-") && (cleanArg.contains("/") || cleanArg.contains(":")) {
                    serverIdentifier = cleanArg
                    break
                }
            }
        } else if originalCommand == "npx" {
            serverIdentifier = "npx " + self.originalArgs.joined(separator: " ")
        } else {
            serverIdentifier = originalCommand
        }

        // Initialize shared security manager
        self.securityManager = MCPSecurityManager(
            serverName: serverName,
            serverIdentifier: serverIdentifier,
            logPath: logPath
        )

        logger.info("MCPProxy initialized for server: \(self.serverName)")
        logger.info("Command: \(self.originalCommand)")
        logger.info("Args: \(self.originalArgs)")
    }
    
    func start() {
        // Start the actual MCP server process
        startServerProcess()
        
        // Set up proxy pipes with line buffering
        setupProxyPipes()
        
        // Keep the proxy running
        RunLoop.current.run()
    }
    
    private func startServerProcess() {
        serverProcess = Process()
        
        // Find the command in PATH if it's not an absolute path
        let commandPath: String
        if originalCommand.hasPrefix("/") {
            commandPath = originalCommand
        } else {
            // Search for command in PATH
            let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            if let foundPath = searchPaths.first(where: { FileManager.default.fileExists(atPath: "\($0)/\(originalCommand)") }) {
                commandPath = "\(foundPath)/\(originalCommand)"
            } else {
                // Try to find it using /usr/bin/which
                let whichProcess = Process()
                whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                whichProcess.arguments = [originalCommand]
                let pipe = Pipe()
                whichProcess.standardOutput = pipe
                whichProcess.standardError = Pipe()
                
                do {
                    try whichProcess.run()
                    whichProcess.waitUntilExit()
                    
                    if let data = try? pipe.fileHandleForReading.readToEnd(),
                       let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !path.isEmpty {
                        commandPath = path
                    } else {
                        commandPath = originalCommand
                    }
                } catch {
                    commandPath = originalCommand
                }
            }
        }
        
        serverProcess?.executableURL = URL(fileURLWithPath: commandPath)
        serverProcess?.arguments = originalArgs
        
        // Pass through environment variables (important for Docker, npm, etc.)
        var environment = ProcessInfo.processInfo.environment
        // Remove our proxy-specific variables
        environment.removeValue(forKey: "MCP_SERVER_NAME")
        environment.removeValue(forKey: "MCP_ORIGINAL_COMMAND")
        environment.removeValue(forKey: "MCP_ORIGINAL_ARGS")
        environment.removeValue(forKey: "MCP_ORIGINAL_ARGS_B64")
        environment.removeValue(forKey: "MCP_LOG_PATH")
        environment.removeValue(forKey: "MCP_BLOCK_LIST")
        
        // Substitute keychain variables
        environment = substituteKeychainVariables(in: environment)
        
        serverProcess?.environment = environment
        
        // Log to stderr for debugging
        FileHandle.standardError.write("Starting server: \(originalCommand) \(originalArgs.joined(separator: " "))\n".data(using: .utf8)!)
        
        // Connect pipes
        serverProcess?.standardInput = inputPipe
        serverProcess?.standardOutput = outputPipe
        serverProcess?.standardError = errorPipe
        
        // Start the server
        do {
            try serverProcess?.run()
            logger.info("Started MCP server process: \(self.originalCommand) with args: \(self.originalArgs)")
            FileHandle.standardError.write("Server started successfully\n".data(using: .utf8)!)
        } catch {
            logger.error("Failed to start server process: \(error)")
            FileHandle.standardError.write("ERROR: Failed to start server: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    
    private func setupProxyPipes() {
        // Handle client -> proxy -> server with line buffering
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            if data.count > 0 {
                self.clientBuffer.append(data)
                
                // Process complete lines
                let lines = self.clientBuffer.extractLines()
                for line in lines {
                    self.handleClientMessage(line)
                }
            }
        }
        
        // Handle server -> proxy -> client with line buffering
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.count > 0 {
                self.serverBuffer.append(data)
                
                // Process complete lines
                let lines = self.serverBuffer.extractLines()
                for line in lines {
                    self.handleServerMessage(line)
                }
            }
        }
        
        // Handle server errors (pass through directly)
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.count > 0 {
                FileHandle.standardError.write(data)
                if let errorString = String(data: data, encoding: .utf8) {
                    self.securityManager.logMessage("ERROR", content: errorString)
                }
            }
        }
    }
    
    private func handleClientMessage(_ messageString: String) {
        // Log the raw message using shared security manager
        securityManager.logMessage("CLIENT->SERVER", content: messageString)

        // Parse the message
        if let jsonData = messageString.data(using: .utf8) {
            do {
                let message = try JSONDecoder().decode(JSONRPCMessage.self, from: jsonData)

                // Debug output
                FileHandle.standardError.write("Decoded message with method: \(message.method ?? "none")\n".data(using: .utf8)!)

                // Check if server is trusted first (but allow system methods through)
                let systemMethods = ["initialize", "initialized", "notifications/initialized", "ping", "shutdown", "tools/list", "resources/list", "prompts/list"]
                let isSystemMethod = message.method.map { systemMethods.contains($0) } ?? false

                if !isSystemMethod && !securityManager.isServerTrusted() {
                    logger.warning("Server is not trusted, blocking request")
                    securityManager.logAuditEntry(message, decision: "blocked", allowed: false, details: ["reason": "Server not trusted", "action": "Add server to trusted list in MCPSnitch"], transport: "stdio")
                    sendBlockedResponse(message, reason: "Server is not trusted. Add it to trusted servers in MCPSnitch.")
                    return
                }

                // Check with security tools if needed
                if securityManager.shouldCheckWithSecurityTools(message) {
                    let checkMethod = message.effectiveMethod ?? message.method ?? "unknown"
                    FileHandle.standardError.write("Security check required for: \(checkMethod)\n".data(using: .utf8)!)
                    logger.info("Message requires security check for: \(checkMethod)")
                    FileHandle.standardError.write("Calling checkWithSecurityTools...\n".data(using: .utf8)!)
                    securityManager.checkWithSecurityTools(message) { allowed in
                        FileHandle.standardError.write("Security check callback received: allowed=\(allowed)\n".data(using: .utf8)!)
                        let method = message.effectiveMethod ?? message.method ?? "unknown"
                        self.logger.info("Security check completed for \(method), allowed: \(allowed)")
                        if allowed {
                            // Forward to server with newline
                            let dataToSend = (messageString + "\n").data(using: .utf8)!
                            self.inputPipe.fileHandleForWriting.write(dataToSend)
                        } else {
                            self.sendBlockedResponse(message)
                        }
                    }
                } else {
                    let skipMethod = message.effectiveMethod ?? message.method ?? "none"
                    FileHandle.standardError.write("No security check needed for: \(skipMethod)\n".data(using: .utf8)!)
                    // Forward to server with newline
                    let dataToSend = (messageString + "\n").data(using: .utf8)!
                    inputPipe.fileHandleForWriting.write(dataToSend)
                }
            } catch {
                // Failed to decode as JSON-RPC, just forward with newline
                FileHandle.standardError.write("Failed to decode JSON-RPC: \(error)\n".data(using: .utf8)!)
                let dataToSend = (messageString + "\n").data(using: .utf8)!
                inputPipe.fileHandleForWriting.write(dataToSend)
            }
        } else {
            // Not JSON, just forward with newline
            let dataToSend = (messageString + "\n").data(using: .utf8)!
            inputPipe.fileHandleForWriting.write(dataToSend)
        }
    }
    
    private func handleServerMessage(_ messageString: String) {
        // Log the response using shared security manager
        securityManager.logMessage("SERVER->CLIENT", content: messageString)

        // Analyze response for potential data leakage (async, non-blocking)
        if securityManager.shouldAnalyzeResponse(messageString) {
            Task {
                await securityManager.analyzeServerResponse(messageString)
            }
        }

        // Forward to client with newline
        let dataToSend = (messageString + "\n").data(using: .utf8)!
        FileHandle.standardOutput.write(dataToSend)
        fflush(stdout)
    }
    
    // All security functions now delegated to shared MCPSecurityManager

    private func sendBlockedResponse(_ message: JSONRPCMessage, reason: String? = nil) {
        if let responseString = securityManager.createBlockedResponseJSON(message, reason: reason) {
            securityManager.logMessage("PROXY->CLIENT", content: responseString)
            // Send with newline
            let dataToSend = (responseString + "\n").data(using: .utf8)!
            FileHandle.standardOutput.write(dataToSend)
            fflush(stdout)
        }
    }
}

