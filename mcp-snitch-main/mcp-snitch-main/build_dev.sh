#!/bin/bash

# MCP Snitch Development Build Script
# Quick build for testing (current architecture only)

set -e  # Exit on error

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Building MCP Snitch (Development)...${NC}"

# Build the proxies first
echo -e "${BLUE}Building stdio proxy...${NC}"
(cd MCPProxy && swiftc -o mcp_proxy mcp_security_common.swift mcp_proxy.swift mcp_proxy_main.swift)

echo -e "${BLUE}Building HTTP proxy...${NC}"
(cd MCPProxy && swiftc -framework Network -o mcp_http_proxy mcp_security_common.swift mcp_http_proxy.swift mcp_http_proxy_main.swift)

# Build the app
xcodebuild -scheme MCPSnitch -configuration Debug build

# Find the app location
APP_LOCATION=$(find ~/Library/Developer/Xcode/DerivedData -name "MCPSnitch.app" -type d 2>/dev/null | head -1)

if [ -n "$APP_LOCATION" ]; then
    # Copy proxy binaries to the app bundle
    echo -e "${BLUE}Copying proxy binaries to app bundle...${NC}"
    RESOURCES_DIR="$APP_LOCATION/Contents/Resources"

    cp MCPProxy/mcp_proxy "$RESOURCES_DIR/mcp_proxy"
    chmod +x "$RESOURCES_DIR/mcp_proxy"
    echo -e "${GREEN}✓ Stdio proxy copied${NC}"

    cp MCPProxy/mcp_http_proxy "$RESOURCES_DIR/mcp_http_proxy"
    chmod +x "$RESOURCES_DIR/mcp_http_proxy"
    echo -e "${GREEN}✓ HTTP proxy copied${NC}"
fi

echo -e "${GREEN}✓ Development build complete${NC}"
echo ""
echo "App location: $APP_LOCATION"