import Foundation
import SQLite3
import os.log
import Combine

struct TrustedServer {
    let id: Int?
    let name: String
    let type: String  // "url", "npx", "local", "docker"
    let identifier: String  // URL, command, path, or container ID
    let configPath: String?
    let trustedAt: Date
    let notes: String?
    
    init(id: Int? = nil, name: String, type: String, identifier: String, configPath: String? = nil, trustedAt: Date = Date(), notes: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.identifier = identifier
        self.configPath = configPath
        self.trustedAt = trustedAt
        self.notes = notes
    }
}

class TrustDatabase: ObservableObject {
    static let shared = TrustDatabase()
    
    private var db: OpaquePointer?
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "TrustDB")
    private let dbPath: String
    
    init() {
        // Create database in Application Support
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Could not find Application Support directory")
        }
        let appDir = appSupport.appendingPathComponent("MCPSnitch", isDirectory: true)
        
        // Create directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create app directory: \(error.localizedDescription)")
        }
        
        dbPath = appDir.appendingPathComponent("trusted_servers.db").path
        logger.info("Database path: \(self.dbPath)")
        
        openDatabase()
        createTables()
    }
    
    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            logger.error("Unable to open database at \(self.dbPath)")
        } else {
            logger.info("Successfully opened database")
        }
    }
    
    private func createTables() {
        let createTableString = """
            CREATE TABLE IF NOT EXISTS trusted_servers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                type TEXT NOT NULL,
                identifier TEXT NOT NULL,
                config_path TEXT,
                trusted_at REAL NOT NULL,
                notes TEXT,
                UNIQUE(name, identifier)
            );
            """
        
        var createTableStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &createTableStatement, nil) == SQLITE_OK {
            if sqlite3_step(createTableStatement) == SQLITE_DONE {
                logger.info("Trusted servers table created successfully")
            } else {
                logger.error("Failed to create trusted servers table")
            }
        } else {
            logger.error("CREATE TABLE statement could not be prepared")
        }
        sqlite3_finalize(createTableStatement)
    }
    
    // MARK: - CRUD Operations
    
    func addTrustedServer(_ server: TrustedServer) -> Bool {
        logger.info("Adding trusted server: \(server.name), type: \(server.type), identifier: \(server.identifier)")
        
        let insertSQL = """
            INSERT OR REPLACE INTO trusted_servers (name, type, identifier, config_path, trusted_at, notes)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        
        var insertStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK {
            // Use SQLITE_TRANSIENT to ensure strings are copied
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            
            sqlite3_bind_text(insertStatement, 1, server.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStatement, 2, server.type, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insertStatement, 3, server.identifier, -1, SQLITE_TRANSIENT)
            
            if let configPath = server.configPath {
                sqlite3_bind_text(insertStatement, 4, configPath, -1, nil)
            } else {
                sqlite3_bind_null(insertStatement, 4)
            }
            
            sqlite3_bind_double(insertStatement, 5, server.trustedAt.timeIntervalSince1970)
            
            if let notes = server.notes {
                sqlite3_bind_text(insertStatement, 6, notes, -1, nil)
            } else {
                sqlite3_bind_null(insertStatement, 6)
            }
            
            if sqlite3_step(insertStatement) == SQLITE_DONE {
                logger.info("Successfully added trusted server: \(server.name)")
                sqlite3_finalize(insertStatement)
                return true
            } else {
                logger.error("Failed to add trusted server: \(server.name)")
            }
        } else {
            logger.error("INSERT statement could not be prepared")
        }
        sqlite3_finalize(insertStatement)
        return false
    }
    
    func removeTrustedServer(name: String, identifier: String) -> Bool {
        logger.info("Attempting to remove server: name='\(name)', identifier='\(identifier)'")
        let deleteSQL = "DELETE FROM trusted_servers WHERE name = ? AND identifier = ?"
        
        var deleteStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(deleteStatement, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(deleteStatement, 2, identifier, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(deleteStatement) == SQLITE_DONE {
                let changes = sqlite3_changes(db)
                logger.info("Removed \(changes) trusted server(s) - name: '\(name)', identifier: '\(identifier)'")
                sqlite3_finalize(deleteStatement)
                return changes > 0
            } else {
                let errorMsg = String(cString: sqlite3_errmsg(db))
                logger.error("Failed to remove trusted server: \(errorMsg)")
            }
        } else {
            logger.error("Failed to prepare DELETE statement")
        }
        sqlite3_finalize(deleteStatement)
        return false
    }
    
    func isTrusted(name: String, identifier: String) -> Bool {
        let querySQL = "SELECT COUNT(*) FROM trusted_servers WHERE name = ? AND identifier = ?"
        
        var queryStatement: OpaquePointer?
        var count: Int32 = 0
        
        if sqlite3_prepare_v2(db, querySQL, -1, &queryStatement, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(queryStatement, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(queryStatement, 2, identifier, -1, SQLITE_TRANSIENT)
            
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                count = sqlite3_column_int(queryStatement, 0)
            }
        }
        sqlite3_finalize(queryStatement)
        
        logger.info("Trust check for name='\(name)', identifier='\(identifier)': count=\(count)")
        return count > 0
    }
    
    func getAllTrustedServers() -> [TrustedServer] {
        let querySQL = "SELECT * FROM trusted_servers ORDER BY trusted_at DESC"
        var servers: [TrustedServer] = []
        var queryStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, querySQL, -1, &queryStatement, nil) == SQLITE_OK {
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(queryStatement, 0))
                
                guard let nameCString = sqlite3_column_text(queryStatement, 1),
                      let typeCString = sqlite3_column_text(queryStatement, 2),
                      let identifierCString = sqlite3_column_text(queryStatement, 3) else {
                    logger.error("Failed to read required fields from database")
                    continue
                }
                
                let name = String(cString: nameCString)
                let type = String(cString: typeCString)
                let identifier = String(cString: identifierCString)
                
                var configPath: String? = nil
                if let configPathCString = sqlite3_column_text(queryStatement, 4) {
                    configPath = String(cString: configPathCString)
                }
                
                let trustedAt = Date(timeIntervalSince1970: sqlite3_column_double(queryStatement, 5))
                
                var notes: String? = nil
                if let notesCString = sqlite3_column_text(queryStatement, 6) {
                    notes = String(cString: notesCString)
                }
                
                let server = TrustedServer(
                    id: id,
                    name: name,
                    type: type,
                    identifier: identifier,
                    configPath: configPath,
                    trustedAt: trustedAt,
                    notes: notes
                )
                servers.append(server)
            }
        } else {
            logger.error("SELECT statement could not be prepared")
        }
        sqlite3_finalize(queryStatement)
        
        return servers
    }
    
    func getTrustedServersByType(_ type: String) -> [TrustedServer] {
        let querySQL = "SELECT * FROM trusted_servers WHERE type = ? ORDER BY name"
        var servers: [TrustedServer] = []
        var queryStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, querySQL, -1, &queryStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(queryStatement, 1, type, -1, nil)
            
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(queryStatement, 0))
                
                guard let nameCString = sqlite3_column_text(queryStatement, 1),
                      let typeCString = sqlite3_column_text(queryStatement, 2),
                      let identifierCString = sqlite3_column_text(queryStatement, 3) else {
                    logger.error("Failed to read required fields from database")
                    continue
                }
                
                let name = String(cString: nameCString)
                let type = String(cString: typeCString)
                let identifier = String(cString: identifierCString)
                
                var configPath: String? = nil
                if let configPathCString = sqlite3_column_text(queryStatement, 4) {
                    configPath = String(cString: configPathCString)
                }
                
                let trustedAt = Date(timeIntervalSince1970: sqlite3_column_double(queryStatement, 5))
                
                var notes: String? = nil
                if let notesCString = sqlite3_column_text(queryStatement, 6) {
                    notes = String(cString: notesCString)
                }
                
                let server = TrustedServer(
                    id: id,
                    name: name,
                    type: type,
                    identifier: identifier,
                    configPath: configPath,
                    trustedAt: trustedAt,
                    notes: notes
                )
                servers.append(server)
            }
        }
        sqlite3_finalize(queryStatement)
        
        return servers
    }
    
    // MARK: - Server Type Detection
    
    static func detectServerType(from config: [String: Any]) -> (type: String, identifier: String)? {
        // Check for URL-based server
        if let url = config["url"] as? String {
            return ("url", url)
        }
        
        // Check for original values first (when server is protected with proxy)
        let command = (config["_original_command"] as? String) ?? (config["command"] as? String)
        let args = (config["_original_args"] as? [String]) ?? (config["args"] as? [String])
        
        // Check for original stdio format
        if let originalStdio = config["_original_stdio"] as? [String: Any] {
            if let stdioCommand = originalStdio["command"] as? String {
                if stdioCommand == "npx", let stdioArgs = originalStdio["args"] as? [String] {
                    return ("npx", "npx " + stdioArgs.joined(separator: " "))
                }
                if stdioCommand == "docker", let stdioArgs = originalStdio["args"] as? [String] {
                    // Look for docker image in args - it's the last non-flag argument
                    if let runIndex = stdioArgs.firstIndex(of: "run") {
                        // Start from the end to find the image (it's usually the last argument)
                        for i in stride(from: stdioArgs.count - 1, through: runIndex + 1, by: -1) {
                            let arg = stdioArgs[i]
                            // Docker images typically contain / or : and don't start with -
                            if !arg.starts(with: "-") && (arg.contains("/") || arg.contains(":")) {
                                return ("docker", arg)
                            }
                        }
                    }
                }
                return ("local", stdioCommand)
            }
        }
        
        // Check for NPX command
        if let command = command {
            if command == "npx", let args = args {
                return ("npx", "npx " + args.joined(separator: " "))
            }
            if command == "docker", let args = args {
                // Look for docker image in args - check from the end since image is usually last
                if let runIndex = args.firstIndex(of: "run") {
                    for i in stride(from: args.count - 1, through: runIndex + 1, by: -1) {
                        let arg = args[i]
                        // Docker images typically contain / or : and don't start with -
                        if !arg.starts(with: "-") && (arg.contains("/") || arg.contains(":")) {
                            return ("docker", arg)
                        }
                    }
                }
            }
            // Skip proxy binary - it's not the real server
            if !command.contains("mcp_proxy") {
                return ("local", command)
            }
        }
        
        // Check for Docker config format
        if let docker = config["docker"] as? [String: Any],
           let image = docker["image"] as? String {
            return ("docker", image)
        }
        
        // Check for stdio/pipe (local binary)
        if let stdio = config["stdio"] as? [String: Any],
           let command = stdio["command"] as? String {
            if command == "npx", let args = stdio["args"] as? [String] {
                return ("npx", "npx " + args.joined(separator: " "))
            }
            if command == "docker", let args = stdio["args"] as? [String] {
                // Look for docker image in args - check from the end since image is usually last
                if let runIndex = args.firstIndex(of: "run") {
                    for i in stride(from: args.count - 1, through: runIndex + 1, by: -1) {
                        let arg = args[i]
                        // Docker images typically contain / or : and don't start with -
                        if !arg.starts(with: "-") && (arg.contains("/") || arg.contains(":")) {
                            return ("docker", arg)
                        }
                    }
                }
            }
            // Skip proxy binary
            if !command.contains("mcp_proxy") {
                return ("local", command)
            }
        }
        
        return nil
    }
    
    // MARK: - Export/Import
    
    func exportTrustedServers() -> Data? {
        let servers = getAllTrustedServers()
        let exportData = servers.map { server in
            [
                "name": server.name,
                "type": server.type,
                "identifier": server.identifier,
                "configPath": server.configPath ?? "",
                "trustedAt": server.trustedAt.timeIntervalSince1970,
                "notes": server.notes ?? ""
            ]
        }
        
        return try? JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted)
    }
    
    func importTrustedServers(from data: Data) -> Bool {
        guard let importData = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        
        for serverData in importData {
            guard let name = serverData["name"] as? String,
                  let type = serverData["type"] as? String,
                  let identifier = serverData["identifier"] as? String else {
                continue
            }
            
            let server = TrustedServer(
                name: name,
                type: type,
                identifier: identifier,
                configPath: serverData["configPath"] as? String,
                trustedAt: Date(timeIntervalSince1970: serverData["trustedAt"] as? Double ?? Date().timeIntervalSince1970),
                notes: serverData["notes"] as? String
            )
            
            _ = addTrustedServer(server)
        }
        
        return true
    }
}