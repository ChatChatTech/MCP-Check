import Foundation

class ConfigurationManager: ObservableObject {
    private let idePathsKey = "CustomIDEPaths"
    private let userDefaults = UserDefaults.standard
    
    let supportedIDEs = [
        "VSCode",
        "Cursor",
        "Claude Desktop",
        "Windsurf",
        "Zed",
        "Sublime Text",
        "IntelliJ IDEA",
        "WebStorm",
        "Other"
    ]
    
    @Published var customIDEPaths: [String: String] = [:]
    
    init() {
        loadIDEPaths()
    }
    
    private func loadIDEPaths() {
        if let saved = userDefaults.dictionary(forKey: idePathsKey) as? [String: String] {
            customIDEPaths = saved
        } else {
            setDefaultPaths()
        }
    }
    
    private func setDefaultPaths() {
        customIDEPaths = [
            "VSCode": "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
            "Cursor": "~/Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
            "Claude Desktop": "~/Library/Application Support/Claude/claude_desktop_config.json",
            "Windsurf": "~/Library/Application Support/Windsurf/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
            "Zed": "",
            "Sublime Text": "",
            "IntelliJ IDEA": "",
            "WebStorm": "",
            "Other": ""
        ]
    }
    
    func getIDEPaths() -> [String: String] {
        return customIDEPaths
    }
    
    func saveIDEPaths(_ paths: [String: String]) {
        customIDEPaths = paths
        userDefaults.set(paths, forKey: idePathsKey)
    }
    
    func getPathForIDE(_ ide: String) -> String? {
        return customIDEPaths[ide]
    }
    
    func updatePathForIDE(_ ide: String, path: String) {
        customIDEPaths[ide] = path
        saveIDEPaths(customIDEPaths)
    }
    
    func resetToDefaults() {
        setDefaultPaths()
        saveIDEPaths(customIDEPaths)
    }
    
    func validatePath(_ path: String) -> Bool {
        let expandedPath = NSString(string: path).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expandedPath)
    }
    
    func expandPath(_ path: String) -> String {
        return NSString(string: path).expandingTildeInPath
    }
    
    func getAllConfiguredPaths() -> [(ide: String, path: String)] {
        return customIDEPaths.compactMap { key, value in
            guard !value.isEmpty else { return nil }
            return (ide: key, path: value)
        }
    }
    
    func exportConfiguration() -> Data? {
        let config = [
            "version": "1.0",
            "idePaths": customIDEPaths,
            "exportDate": Date().timeIntervalSince1970
        ] as [String: Any]
        
        return try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
    }
    
    func importConfiguration(from data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = json["idePaths"] as? [String: String] else {
            return false
        }
        
        customIDEPaths = paths
        saveIDEPaths(customIDEPaths)
        return true
    }
    
    // Get the first available config path (for API key scanning)
    func getConfigPath() -> String? {
        // Try Claude Desktop first
        if let claudePath = customIDEPaths["Claude Desktop"], !claudePath.isEmpty {
            let expandedPath = expandPath(claudePath)
            if validatePath(claudePath) {
                return expandedPath
            }
        }
        
        // Then try other IDEs
        for (_, path) in customIDEPaths where !path.isEmpty {
            if validatePath(path) {
                return expandPath(path)
            }
        }
        
        // Try to auto-detect common locations
        let commonPaths = [
            "~/Library/Application Support/Claude/claude_desktop_config.json",
            "~/.claude_desktop_config.json",
            "~/claude_desktop_config.json",
            "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
            "~/Library/Application Support/Cursor/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
            "~/.config/claude/config.json",
            "~/.mcp/config.json"
        ]
        
        for path in commonPaths {
            if validatePath(path) {
                print("Auto-detected config at: \(path)")
                return expandPath(path)
            }
        }
        
        return nil
    }
}