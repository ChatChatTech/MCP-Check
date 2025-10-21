import Foundation
import Security
import os.log
import SQLite3

// MARK: - JSON-RPC Message Structure

struct JSONRPCMessage: Codable {
    let jsonrpc: String?
    let method: String?
    let params: AnyCodable?
    let id: AnyCodable?
    let result: AnyCodable?
    let error: AnyCodable?

    var toolName: String? {
        guard method == "tools/call" || method == "tools/use" else { return nil }

        if let params = params?.value as? [String: Any],
           let name = params["name"] as? String {
            return name
        }
        return nil
    }

    var effectiveMethod: String? {
        if let toolName = toolName {
            return "tools/call:\(toolName)"
        }
        return method
    }
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            value = arrayVal.map { $0.value }
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            value = dictVal.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let intVal as Int:
            try container.encode(intVal)
        case let doubleVal as Double:
            try container.encode(doubleVal)
        case let boolVal as Bool:
            try container.encode(boolVal)
        case let stringVal as String:
            try container.encode(stringVal)
        case let arrayVal as [Any]:
            try container.encode(arrayVal.map { AnyCodable($0) })
        case let dictVal as [String: Any]:
            try container.encode(dictVal.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Shared Security Manager

class MCPSecurityManager {
    let serverName: String
    let serverIdentifier: String
    let logPath: String
    private let logger: Logger

    init(serverName: String, serverIdentifier: String, logPath: String) {
        self.serverName = serverName
        self.serverIdentifier = serverIdentifier
        self.logPath = logPath
        self.logger = Logger(subsystem: "com.MCPSnitch.security", category: "MCPSecurityManager")
    }

    // MARK: - Trust Check

    func isServerTrusted() -> Bool {
        logger.info("Checking trust for server: \(self.serverName) with identifier: '\(self.serverIdentifier)'")

        let dbPath = NSHomeDirectory() + "/Library/Application Support/MCPSnitch/trusted_servers.db"
        var db: OpaquePointer?

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            logger.error("Failed to open trust database at \(dbPath)")
            sqlite3_close(db)
            return false
        }

        defer { sqlite3_close(db) }

        let querySQL = "SELECT COUNT(*) FROM trusted_servers WHERE name = ? AND identifier = ?"
        var queryStatement: OpaquePointer?

        guard sqlite3_prepare_v2(db, querySQL, -1, &queryStatement, nil) == SQLITE_OK else {
            logger.error("Failed to prepare trust query")
            return false
        }

        defer { sqlite3_finalize(queryStatement) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(queryStatement, 1, serverName, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(queryStatement, 2, serverIdentifier, -1, SQLITE_TRANSIENT)

        var count: Int32 = 0
        if sqlite3_step(queryStatement) == SQLITE_ROW {
            count = sqlite3_column_int(queryStatement, 0)
        }

        let isTrusted = count > 0
        logger.info("Trust check result for '\(self.serverName)' with identifier '\(self.serverIdentifier)': \(isTrusted)")

        FileHandle.standardError.write("Trust check: name='\(self.serverName)', identifier='\(self.serverIdentifier)', trusted=\(isTrusted)\n".data(using: .utf8)!)

        return isTrusted
    }

    // MARK: - Security Policy Check

    func shouldCheckWithSecurityTools(_ message: JSONRPCMessage) -> Bool {
        let defaults = UserDefaults(suiteName: "com.yourcompany.MCPSnitch") ?? UserDefaults.standard
        let toolMode = defaults.string(forKey: "GuardRailsToolControlMode") ?? "off"
        let securityMode = defaults.string(forKey: "GuardRailsSecurityDetectionMode") ?? "off"

        if toolMode == "off" && securityMode == "off" {
            return false
        }

        guard let method = message.method else {
            return false
        }

        let systemMethods = [
            "initialize", "initialized", "notifications/initialized",
            "ping", "shutdown", "tools/list", "resources/list", "prompts/list"
        ]

        return !systemMethods.contains(method)
    }

    // MARK: - Security Check with MCPSnitch

    func checkWithSecurityTools(_ message: JSONRPCMessage, completion: @escaping (Bool) -> Void) {
        guard let messageString = try? JSONEncoder().encode(message),
              let messageStr = String(data: messageString, encoding: .utf8) else {
            completion(true)
            return
        }

        let notificationName = Notification.Name("MCPProxySecurityCheck")
        let responseNotificationName = Notification.Name("MCPProxySecurityResponse_\(serverName)_\(UUID().uuidString)")

        let semaphore = DispatchSemaphore(value: 0)
        var responseReceived = false
        var allowedResult = true
        var observer: Any?
        var aiAnalysisDetails: [String: Any]?

        FileHandle.standardError.write("Security check: Registering observer for response channel: \(responseNotificationName.rawValue)\n".data(using: .utf8)!)

        observer = DistributedNotificationCenter.default().addObserver(
            forName: responseNotificationName,
            object: nil,
            queue: nil
        ) { notification in
            FileHandle.standardError.write("Security check: Response received on channel: \(responseNotificationName.rawValue)\n".data(using: .utf8)!)

            if let obs = observer {
                DistributedNotificationCenter.default().removeObserver(obs)
                observer = nil
            }

            if let userInfo = notification.userInfo,
               let allowed = userInfo["allowed"] as? Bool {
                allowedResult = allowed
                responseReceived = true
                FileHandle.standardError.write("Security check: Response allowed=\(allowed)\n".data(using: .utf8)!)

                if let analysis = userInfo["aiAnalysis"] as? [String: Any] {
                    aiAnalysisDetails = analysis
                }

                if let reason = userInfo["reason"] as? String {
                    if aiAnalysisDetails == nil {
                        aiAnalysisDetails = [:]
                    }
                    aiAnalysisDetails?["reason"] = reason
                }

                if let decision = userInfo["decision"] as? String {
                    if aiAnalysisDetails == nil {
                        aiAnalysisDetails = [:]
                    }
                    aiAnalysisDetails?["decision"] = decision
                }
            }

            semaphore.signal()
        }

        var userInfo: [String: Any] = [
            "server": serverName,
            "message": messageStr,
            "responseChannel": responseNotificationName.rawValue
        ]

        if let toolName = message.toolName {
            userInfo["toolName"] = toolName
            userInfo["method"] = "tools/call:\(toolName)"
        } else {
            userInfo["method"] = message.method ?? "unknown"
        }

        FileHandle.standardError.write("Security check: Posting notification to MCPSnitch with response channel: \(responseNotificationName.rawValue)\n".data(using: .utf8)!)

        DistributedNotificationCenter.default().post(
            name: notificationName,
            object: nil,
            userInfo: userInfo
        )

        FileHandle.standardError.write("Security check: Waiting for response (30s timeout)...\n".data(using: .utf8)!)

        let timeout = DispatchTime.now() + .seconds(30)
        let result = semaphore.wait(timeout: timeout)

        if let obs = observer {
            DistributedNotificationCenter.default().removeObserver(obs)
        }

        if result == .timedOut {
            FileHandle.standardError.write("Security check: TIMEOUT - no response received on channel: \(responseNotificationName.rawValue)\n".data(using: .utf8)!)
            logAuditEntry(message, decision: "timeout", allowed: false, details: ["error": "Security check timed out after 30 seconds"])
            completion(false)
        } else if responseReceived {
            logAuditEntry(message, decision: allowedResult ? "allowed" : "blocked", allowed: allowedResult, details: aiAnalysisDetails)
            completion(allowedResult)
        } else {
            logAuditEntry(message, decision: "error", allowed: false, details: ["error": "No response received from security check"])
            completion(false)
        }
    }

    // MARK: - Response Analysis

    func shouldAnalyzeResponse(_ response: String) -> Bool {
        let sensitivePatterns = [
            "ssh-rsa", "ssh-ed25519", "PRIVATE KEY",
            "password", "token", "api_key", "secret",
            "/etc/passwd", "/etc/shadow", "root:",
            "AWS_", "GITHUB_", "OPENAI_"
        ]

        let lowercased = response.lowercased()
        return sensitivePatterns.contains { pattern in
            lowercased.contains(pattern.lowercased())
        }
    }

    func analyzeServerResponse(_ response: String) async {
        guard let securityMode = ProcessInfo.processInfo.environment["GUARDRAILS_SECURITY_MODE"],
              securityMode == "block" || securityMode == "approve" else {
            return
        }

        let truncated = String(response.prefix(500))

        let criticalPatterns = [
            ("ssh-rsa", "ssh_private_key"),
            ("PRIVATE KEY", "private_key_exposure"),
            ("/etc/passwd", "system_file_leak"),
            ("password=", "password_leak"),
            ("api_key=", "api_key_exposure")
        ]

        for (pattern, threatType) in criticalPatterns {
            if truncated.contains(pattern) {
                let msg = JSONRPCMessage(
                    jsonrpc: "2.0",
                    method: "response_analysis",
                    params: AnyCodable(["response": truncated, "pattern": pattern]),
                    id: nil,
                    result: nil,
                    error: nil
                )
                logAuditEntry(msg, decision: "data_leak_detected", allowed: true, details: ["type": threatType, "severity": "critical"])
                await sendSecurityAlert(threatType: threatType, content: truncated)
                return
            }
        }
    }

    private func sendSecurityAlert(threatType: String, content: String) async {
        let notification = Notification.Name("MCPSnitchSecurityAlert")
        let userInfo: [String: Any] = [
            "server": serverName,
            "threat": threatType,
            "severity": "critical",
            "content": String(content.prefix(100))
        ]

        DistributedNotificationCenter.default().post(
            name: notification,
            object: nil,
            userInfo: userInfo
        )
    }

    // MARK: - Audit Logging

    func logAuditEntry(_ message: JSONRPCMessage, decision: String, allowed: Bool, details: [String: Any]? = nil, transport: String? = nil) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current

        var auditEntry: [String: Any] = [
            "timestamp": now.timeIntervalSince1970,
            "formattedTimestamp": formatter.string(from: now),
            "server": serverName,
            "decision": decision,
            "allowed": allowed
        ]

        if let transport = transport {
            auditEntry["transport"] = transport
        }

        if let method = message.method {
            auditEntry["method"] = method
        }

        if let toolName = message.toolName {
            auditEntry["toolName"] = toolName
            auditEntry["effectiveMethod"] = "tools/call:\(toolName)"
        }

        if let params = message.params {
            if JSONSerialization.isValidJSONObject(params),
               let paramsData = try? JSONSerialization.data(withJSONObject: params),
               let paramsString = String(data: paramsData, encoding: .utf8) {
                auditEntry["request"] = paramsString
            } else {
                auditEntry["request"] = String(describing: params)
            }
        }

        if let details = details {
            auditEntry["aiAnalysis"] = details

            if let riskLevel = details["riskLevel"] {
                auditEntry["riskLevel"] = riskLevel
            }
            if let concerns = details["concerns"] {
                auditEntry["concerns"] = concerns
            }
            if let recommendation = details["recommendation"] {
                auditEntry["recommendation"] = recommendation
            }
            if let reason = details["reason"] {
                auditEntry["blockReason"] = reason
            }
        }

        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.mcpsnitch.notification.addAuditLogEntry"),
            object: nil,
            userInfo: auditEntry
        )

        logger.info("Audit Log Entry: \(decision) - \(message.effectiveMethod ?? message.method ?? "unknown") - AI Analysis: \(details ?? [:])")
    }

    // MARK: - Message Logging

    func logMessage(_ direction: String, content: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] [\(serverName)] [\(direction)] \(content)\n"

        if let logData = logEntry.data(using: .utf8) {
            let logURL = URL(fileURLWithPath: logPath)

            DispatchQueue.global(qos: .background).async {
                do {
                    if FileManager.default.fileExists(atPath: self.logPath) {
                        if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                            fileHandle.seekToEndOfFile()
                            fileHandle.write(logData)
                            fileHandle.closeFile()
                        }
                    } else {
                        try logData.write(to: logURL)
                    }

                    if let attributes = try? FileManager.default.attributesOfItem(atPath: self.logPath),
                       let fileSize = attributes[.size] as? Int64,
                       fileSize > 10_000_000 {
                        self.rotateLogFile()
                    }
                } catch {
                    self.logger.error("Failed to write to log file: \(error)")
                }
            }
        }

        DistributedNotificationCenter.default().post(
            name: Notification.Name("MCPProxyMessage"),
            object: nil,
            userInfo: [
                "server": serverName,
                "direction": direction,
                "content": content,
                "timestamp": timestamp
            ]
        )
    }

    private func rotateLogFile() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let archivePath = "\(logPath).\(timestamp)"

        do {
            try FileManager.default.moveItem(atPath: logPath, toPath: archivePath)
            cleanOldLogs()
        } catch {
            logger.error("Failed to rotate log file: \(error)")
        }
    }

    private func cleanOldLogs() {
        let logDir = URL(fileURLWithPath: logPath).deletingLastPathComponent()
        let logName = URL(fileURLWithPath: logPath).lastPathComponent

        do {
            let files = try FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.creationDateKey])
            let logFiles = files.filter { $0.lastPathComponent.hasPrefix(logName) && $0.lastPathComponent != logName }
                .sorted { (url1, url2) in
                    let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                    return date1 > date2
                }

            if logFiles.count > 5 {
                for fileToDelete in logFiles[5...] {
                    try FileManager.default.removeItem(at: fileToDelete)
                }
            }
        } catch {
            logger.error("Failed to clean old logs: \(error)")
        }
    }

    // MARK: - Helper: Create blocked response JSON

    func createBlockedResponseJSON(_ message: JSONRPCMessage, reason: String? = nil) -> String? {
        let blockedMethod = message.effectiveMethod ?? message.method ?? "unknown"
        let errorMessage = reason ?? "MCPSnitch blocked request: '\(blockedMethod)' - Check MCPSnitch GuardRails settings"

        let errorResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "id": message.id?.value ?? NSNull(),
            "error": [
                "code": -32001,
                "message": errorMessage
            ]
        ]

        if let responseData = try? JSONSerialization.data(withJSONObject: errorResponse),
           let responseString = String(data: responseData, encoding: .utf8) {
            return responseString
        }

        return nil
    }
}

// MARK: - Keychain Helper

func getKeychainValue(name: String) -> String? {
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

func substituteKeychainVariables(in environment: [String: String]) -> [String: String] {
    var result = environment

    for (key, value) in environment {
        let pattern = #"\$\{KEYCHAIN:([^}]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            continue
        }

        let nsValue = value as NSString
        let matches = regex.matches(in: value, options: [], range: NSRange(location: 0, length: nsValue.length))

        var newValue = value
        for match in matches.reversed() {
            if match.numberOfRanges > 1 {
                let keyNameRange = match.range(at: 1)
                let keyName = nsValue.substring(with: keyNameRange)

                if let keyValue = getKeychainValue(name: keyName) {
                    let fullMatchRange = match.range(at: 0)
                    newValue = (newValue as NSString).replacingCharacters(in: fullMatchRange, with: keyValue)
                    FileHandle.standardError.write("Substituted keychain variable '\(keyName)' in environment variable '\(key)'\n".data(using: .utf8)!)
                } else {
                    FileHandle.standardError.write("WARNING: Keychain key '\(keyName)' not found for substitution in '\(key)'\n".data(using: .utf8)!)
                }
            }
        }

        result[key] = newValue
    }

    return result
}
