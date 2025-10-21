import Foundation
import os.log

class ServerScanner: ObservableObject {
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.MCPSnitch", category: "ServerScanner")
    
    private let defaultIDEPaths = [
        "VSCode": "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
        "Cursor": "~/.cursor/mcp.json",
        "Cursor (Alternate)": "~/Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
        "Claude Desktop": "~/Library/Application Support/Claude/claude_desktop_config.json",
        "Claude Desktop (config.json)": "~/Library/Application Support/Claude/config.json",
        "Windsurf": "~/Library/Application Support/Windsurf/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"
    ]
    
    func scanForServers() -> [MCPServer] {
        var servers: [MCPServer] = []
        logger.info("Starting server scan...")
        
        for (ide, path) in defaultIDEPaths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            logger.info("Checking \(ide) at: \(expandedPath)")
            
            if fileManager.fileExists(atPath: expandedPath) {
                logger.info("Found config file for \(ide)")
                if let configServers = parseConfigFile(at: expandedPath, ide: ide) {
                    logger.info("Found \(configServers.count) servers in \(ide)")
                    servers.append(contentsOf: configServers)
                } else {
                    logger.warning("Failed to parse config for \(ide)")
                }
            } else {
                logger.debug("No config file found for \(ide)")
            }
        }
        
        let customPaths = ConfigurationManager().getIDEPaths()
        for (ide, path) in customPaths {
            if !path.isEmpty {
                let expandedPath = NSString(string: path).expandingTildeInPath
                logger.info("Checking custom path for \(ide): \(expandedPath)")
                if fileManager.fileExists(atPath: expandedPath) {
                    if let configServers = parseConfigFile(at: expandedPath, ide: ide) {
                        logger.info("Found \(configServers.count) servers in custom \(ide) config")
                        servers.append(contentsOf: configServers)
                    }
                }
            }
        }
        
        // Deduplicate servers based on name and path
        var uniqueServers: [MCPServer] = []
        var seenServers: Set<String> = []
        
        for server in servers {
            let key = "\(server.name)-\(server.path)"
            if !seenServers.contains(key) {
                seenServers.insert(key)
                uniqueServers.append(server)
            } else {
                logger.info("Skipping duplicate server: \(server.name) at \(server.path)")
            }
        }
        
        logger.info("Scan complete. Found \(uniqueServers.count) unique servers (removed \(servers.count - uniqueServers.count) duplicates)")
        return uniqueServers
    }
    
    private func parseConfigFile(at path: String, ide: String) -> [MCPServer]? {
        logger.info("Parsing config file at: \(path)")
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            logger.error("Failed to read file at: \(path)")
            return nil
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse JSON at: \(path)")
            return nil
        }
        
        var servers: [MCPServer] = []
        
        // Check for mcpServers key (used by most configs)
        if let mcpServers = json["mcpServers"] {
            logger.info("Found mcpServers key in \(ide) config")
            
            // Handle object format (Claude Desktop, Cursor's mcp.json)
            if let mcpServersDict = mcpServers as? [String: Any] {
                logger.info("mcpServers is a dictionary with \(mcpServersDict.count) entries")
                for (serverName, serverConfig) in mcpServersDict {
                    logger.info("Found server: \(serverName)")
                    servers.append(MCPServer(
                        name: serverName,
                        path: path,
                        configFile: ide
                    ))
                }
            }
            // Handle array format (VSCode/Cline)
            else if let mcpServersArray = mcpServers as? [[String: Any]] {
                logger.info("mcpServers is an array with \(mcpServersArray.count) entries")
                for serverConfig in mcpServersArray {
                    if let name = serverConfig["name"] as? String {
                        logger.info("Found server: \(name)")
                        servers.append(MCPServer(
                            name: name,
                            path: path,
                            configFile: ide
                        ))
                    }
                }
            }
        } else {
            logger.warning("No mcpServers key found in \(ide) config")
        }
        
        logger.info("Parsed \(servers.count) servers from \(ide)")
        return servers.isEmpty ? nil : servers
    }
    
    func rescanSpecificIDE(_ ide: String, path: String) -> [MCPServer]? {
        if fileManager.fileExists(atPath: path) {
            return parseConfigFile(at: path, ide: ide)
        }
        return nil
    }
}