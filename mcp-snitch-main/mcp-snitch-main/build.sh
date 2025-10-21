#!/bin/bash

# Simple Build Script for MCP Snitch
# Creates an unsigned development build for personal use

set -e

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}Building MCP Snitch...${NC}"

# Build proxies
echo -e "${BLUE}Building stdio proxy...${NC}"
cd MCPProxy
swiftc -o mcp_proxy mcp_proxy.swift mcp_proxy_main.swift mcp_security_common.swift
echo -e "${GREEN}✓ Stdio proxy built${NC}"

echo -e "${BLUE}Building HTTP proxy...${NC}"
swiftc -o mcp_http_proxy mcp_http_proxy.swift mcp_http_proxy_main.swift mcp_security_common.swift
echo -e "${GREEN}✓ HTTP proxy built${NC}"

cd ..

# Build app
echo -e "${BLUE}Building app with Xcode...${NC}"
xcodebuild -scheme MCPSnitch -configuration Debug build

echo -e "${GREEN}✓ Build complete${NC}"
echo ""
echo "App location: $(pwd)/build/Debug/MCPSnitch.app"
echo ""
echo "To run: open build/Debug/MCPSnitch.app"
echo "Or use: ./run.sh"
