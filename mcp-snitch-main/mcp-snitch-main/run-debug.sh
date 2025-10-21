#!/bin/bash

# Kill any existing MCPSnitch processes
echo "Stopping existing MCPSnitch instances..."
pkill -f MCPSnitch 2>/dev/null

# Compile the MCP proxies first
echo "Compiling stdio proxy..."
(cd MCPProxy && swiftc -o mcp_proxy mcp_security_common.swift mcp_proxy.swift mcp_proxy_main.swift)
if [ $? -ne 0 ]; then
    echo "Error: Failed to compile stdio proxy!"
    exit 1
fi
echo "Stdio proxy compiled successfully."

echo "Compiling HTTP proxy..."
(cd MCPProxy && swiftc -framework Network -o mcp_http_proxy mcp_security_common.swift mcp_http_proxy.swift mcp_http_proxy_main.swift)
if [ $? -ne 0 ]; then
    echo "Error: Failed to compile HTTP proxy!"
    exit 1
fi
echo "HTTP proxy compiled successfully."

echo "Building MCPSnitch..."
xcodebuild -project MCPSnitch.xcodeproj -scheme MCPSnitch -configuration Debug build 2>&1 | tee build.log

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo "Build successful!"

    # Copy the proxies to the app bundle
    echo "Copying proxy binaries to app bundle..."
    APP_RESOURCES_PATH=$(ls -d ~/Library/Developer/Xcode/DerivedData/MCPSnitch-*/Build/Products/Debug/MCPSnitch.app/Contents/Resources 2>/dev/null | head -1)
    if [ -n "$APP_RESOURCES_PATH" ]; then
        cp MCPProxy/mcp_proxy "$APP_RESOURCES_PATH/"
        chmod +x "$APP_RESOURCES_PATH/mcp_proxy"
        echo "Stdio proxy copied to app bundle."

        cp MCPProxy/mcp_http_proxy "$APP_RESOURCES_PATH/"
        chmod +x "$APP_RESOURCES_PATH/mcp_http_proxy"
        echo "HTTP proxy copied to app bundle."
    else
        echo "Warning: Could not find app Resources directory!"
    fi

    echo "Launching app with console output..."

    # Run the app directly (not through 'open') to capture stdout/stderr
    APP_PATH="~/Library/Developer/Xcode/DerivedData/MCPSnitch-*/Build/Products/Debug/MCPSnitch.app/Contents/MacOS/MCPSnitch"

    # Find the actual path
    APP_PATH=$(ls -d ~/Library/Developer/Xcode/DerivedData/MCPSnitch-*/Build/Products/Debug/MCPSnitch.app/Contents/MacOS/MCPSnitch 2>/dev/null | head -1)
    
    if [ -n "$APP_PATH" ]; then
        echo "Running: $APP_PATH"
        echo "Console output will appear below (press Ctrl+C to stop):"
        echo "----------------------------------------"
        "$APP_PATH" 2>&1 | tee runtime.log
    else
        echo "Error: Could not find built app!"
        exit 1
    fi
else
    echo "Build failed! Check build.log for errors."
    exit 1
fi