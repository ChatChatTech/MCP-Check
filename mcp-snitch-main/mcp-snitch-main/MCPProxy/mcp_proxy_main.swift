// Main entry point for stdio MCP proxy

@main
struct MCPProxyMain {
    static func main() {
        let proxy = MCPProxy()
        proxy.start()
    }
}
