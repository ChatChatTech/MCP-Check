// Main entry point for HTTP MCP proxy

@main
struct MCPHTTPProxyMain {
    static func main() {
        let proxy = MCPHTTPProxy()
        proxy.start()
    }
}
