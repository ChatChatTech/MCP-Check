import Foundation
import Network
import os.log

// Simple HTTP MCP Proxy - forwards HTTP requests with session management

class MCPHTTPProxy {
    let serverName: String
    let targetURL: URL
    let localPort: UInt16
    let targetHeaders: [String: String]
    let securityManager: MCPSecurityManager

    private let logger = Logger(subsystem: "com.MCPSnitch.httpproxy", category: "MCPHTTPProxy")
    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "com.MCPSnitch.httpproxy.listener")

    // Session management: shared session ID for all connections to same server
    private var mcpSessionID: String?
    private let sessionQueue = DispatchQueue(label: "com.MCPSnitch.httpproxy.session")

    init() {
        // Get configuration from environment variables
        self.serverName = ProcessInfo.processInfo.environment["MCP_SERVER_NAME"] ?? "unknown"

        guard let urlString = ProcessInfo.processInfo.environment["MCP_TARGET_URL"],
              let url = URL(string: urlString) else {
            print("ERROR: MCP_TARGET_URL not provided or invalid")
            exit(1)
        }
        self.targetURL = url

        // Parse local port
        if let portStr = ProcessInfo.processInfo.environment["MCP_LOCAL_PORT"],
           let port = UInt16(portStr) {
            self.localPort = port
        } else {
            self.localPort = 0
        }

        // Parse target headers from JSON
        var headers: [String: String] = [:]
        if let headersJSON = ProcessInfo.processInfo.environment["MCP_TARGET_HEADERS"],
           let headersData = headersJSON.data(using: .utf8),
           let parsedHeaders = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
            headers = parsedHeaders
        }
        self.targetHeaders = headers

        let logPath = ProcessInfo.processInfo.environment["MCP_LOG_PATH"] ?? "/tmp/mcp_http_proxy.log"

        self.securityManager = MCPSecurityManager(
            serverName: serverName,
            serverIdentifier: urlString,
            logPath: logPath
        )

        print("HTTP PROXY: Initialized for \(serverName) -> \(targetURL)")
        print("HTTP PROXY: Target headers: \(targetHeaders.keys.joined(separator: ", "))")
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let port = NWEndpoint.Port(rawValue: localPort) ?? NWEndpoint.Port(integerLiteral: 0)
            let newListener = try NWListener(using: parameters, on: port)
            listener = newListener

            newListener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            newListener.start(queue: listenerQueue)

            // Keep running
            RunLoop.current.run()
        } catch {
            print("HTTP PROXY ERROR: Failed to start listener: \(error)")
            exit(1)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let actualPort = self.listener?.port {
                let portValue = actualPort.rawValue
                print("PROXY_PORT:\(portValue)")
                fflush(stdout)
                print("HTTP PROXY: Listening on port \(portValue)")
            }
        case .failed(let error):
            print("HTTP PROXY ERROR: Listener failed: \(error)")
            exit(1)
        case .cancelled:
            print("HTTP PROXY: Listener cancelled")
        default:
            break
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        print("HTTP PROXY: New connection")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(connection)
            case .failed(let error):
                print("HTTP PROXY: Connection failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: DispatchQueue(label: "com.MCPSnitch.httpproxy.connection"))
    }

    private func receiveRequest(_ connection: NWConnection) {
        // Read the entire HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("HTTP PROXY ERROR: Receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data = data, !data.isEmpty else {
                if isComplete {
                    print("HTTP PROXY: Connection complete, closing")
                    connection.cancel()
                }
                return
            }

            print("HTTP PROXY: Received \(data.count) bytes, isComplete: \(isComplete)")
            self.forwardRequest(data, to: connection, isComplete: isComplete)
        }
    }

    private func forwardRequest(_ requestData: Data, to connection: NWConnection, isComplete: Bool) {
        guard let requestString = String(data: requestData, encoding: .utf8) else {
            self.sendError(to: connection, message: "Invalid encoding")
            return
        }

        print("HTTP PROXY: Request preview: \(requestString.prefix(200))")

        // Extract body from HTTP request
        guard let bodyStart = requestString.range(of: "\r\n\r\n") else {
            print("HTTP PROXY ERROR: Invalid HTTP request format - no body separator")
            self.sendError(to: connection, message: "Invalid request format")
            return
        }

        let bodyString = String(requestString[bodyStart.upperBound...])
        print("HTTP PROXY: Body: \(bodyString.prefix(100))")

        // Log the request
        securityManager.logMessage("CLIENT->PROXY", content: bodyString)

        // Try to parse as JSON-RPC for security checks
        guard let bodyData = bodyString.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: bodyData) else {
            // Not JSON-RPC, just forward
            print("HTTP PROXY: Not JSON-RPC, forwarding without security checks")
            actuallyForwardRequest(bodyString: bodyString, to: connection)
            return
        }

        // Security checks using shared manager
        let systemMethods = ["initialize", "initialized", "notifications/initialized", "ping", "shutdown", "tools/list", "resources/list", "prompts/list"]
        let isSystemMethod = message.method.map { systemMethods.contains($0) } ?? false

        if !isSystemMethod && !securityManager.isServerTrusted() {
            logger.warning("Server is not trusted, blocking request")
            securityManager.logAuditEntry(message, decision: "blocked", allowed: false, details: ["reason": "Server not trusted", "action": "Add server to trusted list in MCPSnitch"], transport: "http")
            sendBlockedHTTPResponse(connection, message: message, reason: "Server is not trusted. Add it to trusted servers in MCPSnitch.")
            return
        }

        // Check with security tools if needed
        if securityManager.shouldCheckWithSecurityTools(message) {
            let checkMethod = message.effectiveMethod ?? message.method ?? "unknown"
            print("HTTP PROXY: Security check required for: \(checkMethod)")
            logger.info("Message requires security check for: \(checkMethod)")

            securityManager.checkWithSecurityTools(message) { [weak self] allowed in
                guard let self = self else { return }
                print("HTTP PROXY: Security check callback received: allowed=\(allowed)")
                let method = message.effectiveMethod ?? message.method ?? "unknown"
                self.logger.info("Security check completed for \(method), allowed: \(allowed)")

                if allowed {
                    self.actuallyForwardRequest(bodyString: bodyString, to: connection)
                } else {
                    self.sendBlockedHTTPResponse(connection, message: message, reason: "Request blocked by security policy")
                }
            }
        } else {
            let skipMethod = message.effectiveMethod ?? message.method ?? "none"
            print("HTTP PROXY: No security check needed for: \(skipMethod)")
            actuallyForwardRequest(bodyString: bodyString, to: connection)
        }
    }

    private func actuallyForwardRequest(bodyString: String, to connection: NWConnection) {
        // Parse HTTP request
        var urlRequest = URLRequest(url: targetURL)
        urlRequest.httpMethod = "POST"  // MCP uses POST
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add target headers (Authorization, etc.)
        for (key, value) in targetHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Add session ID - use saved one or generate random
        let sessionID: String = sessionQueue.sync {
            if let existingSessionID = self.mcpSessionID {
                print("HTTP PROXY: Using saved session ID: \(existingSessionID)")
                return existingSessionID
            } else {
                // Generate a random session ID for first request
                let randomSessionID = UUID().uuidString
                self.mcpSessionID = randomSessionID
                print("HTTP PROXY: Generated random session ID: \(randomSessionID)")
                return randomSessionID
            }
        }
        urlRequest.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")

        // Set body
        urlRequest.httpBody = bodyString.data(using: .utf8)

        // Forward to target
        print("HTTP PROXY: Forwarding to \(targetURL)")
        let task = URLSession.shared.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("HTTP PROXY ERROR: Forward failed: \(error)")
                self.sendError(to: connection, message: "Bad Gateway")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let responseData = data else {
                print("HTTP PROXY ERROR: Invalid response")
                self.sendError(to: connection, message: "Bad Gateway")
                return
            }

            print("HTTP PROXY: Received response: \(httpResponse.statusCode) (\(responseData.count) bytes)")

            // Capture session ID
            if let sessionID = httpResponse.value(forHTTPHeaderField: "mcp-session-id") {
                self.sessionQueue.async {
                    self.mcpSessionID = sessionID
                    print("HTTP PROXY: Captured session ID: \(sessionID)")
                }
            }

            // Log the response
            if let responseString = String(data: responseData, encoding: .utf8) {
                self.securityManager.logMessage("SERVER->PROXY", content: responseString)

                // Analyze response for security issues (async, non-blocking)
                if self.securityManager.shouldAnalyzeResponse(responseString) {
                    Task {
                        await self.securityManager.analyzeServerResponse(responseString)
                    }
                }
            }

            // Forward response to client
            self.sendResponse(to: connection, statusCode: httpResponse.statusCode, headers: httpResponse.allHeaderFields, body: responseData)
        }

        task.resume()
    }

    private func sendResponse(to connection: NWConnection, statusCode: Int, headers: [AnyHashable: Any], body: Data) {
        // Get proper status text
        let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        var responseString = "HTTP/1.1 \(statusCode) \(statusText)\r\n"

        // Forward all headers from the server, but check for Content-Length
        var hasContentLength = false
        for (key, value) in headers {
            if let key = key as? String, let value = value as? String {
                if key.lowercased() == "content-length" {
                    hasContentLength = true
                }
                responseString += "\(key): \(value)\r\n"
            }
        }

        // Add Content-Length if not already present
        if !hasContentLength {
            responseString += "Content-Length: \(body.count)\r\n"
        }

        responseString += "\r\n"

        var responseData = responseString.data(using: .utf8) ?? Data()
        responseData.append(body)

        print("HTTP PROXY: Sending response \(statusCode) with \(body.count) bytes")

        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error = error {
                print("HTTP PROXY ERROR: Failed to send response: \(error)")
            }
            // Always close connection after response for simplicity
            connection.cancel()
        })
    }

    private func sendError(to connection: NWConnection, message: String) {
        let errorJSON = "{\"error\":\"\(message)\"}"
        let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\nContent-Length: \(errorJSON.count)\r\n\r\n\(errorJSON)"

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendBlockedHTTPResponse(_ connection: NWConnection, message: JSONRPCMessage, reason: String) {
        if let responseJSON = securityManager.createBlockedResponseJSON(message, reason: reason),
           let responseData = responseJSON.data(using: .utf8) {

            var responseString = "HTTP/1.1 200 OK\r\n"
            responseString += "Content-Type: application/json\r\n"
            responseString += "Content-Length: \(responseData.count)\r\n"
            responseString += "\r\n"

            var fullResponse = responseString.data(using: .utf8) ?? Data()
            fullResponse.append(responseData)

            securityManager.logMessage("PROXY->CLIENT", content: responseJSON)

            connection.send(content: fullResponse, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            sendError(to: connection, message: "Internal error")
        }
    }
}
