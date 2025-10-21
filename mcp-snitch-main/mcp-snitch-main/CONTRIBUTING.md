# Contributing to MCP Snitch

Thank you for your interest in contributing to MCP Snitch! This document provides guidelines for contributing to the project.

## Getting Started

MCP Snitch is an open-source security monitoring tool for Model Context Protocol (MCP) servers. We welcome contributions in the form of:

- Bug reports
- Feature requests
- Documentation improvements
- Code contributions

## Development Setup

### Prerequisites

- macOS 13.0 or later
- Xcode 15.0 or later
- Swift 5.9 or later
- Git

### Building from Source

1. Clone the repository:
```bash
git clone https://github.com/Adversis/mcp-snitch.git
cd mcp-snitch
```

2. Build the app:
```bash
./build.sh
```

3. Run the app:
```bash
./run.sh
```

For debugging:
```bash
./run-debug.sh
```

**Note:** The unsigned build is for personal development use only. Users should download signed releases from the Releases page.

## Project Structure

```
mcp-snitch/
├── MCPSnitch/          # Main macOS app (SwiftUI)
├── MCPProxy/           # Proxy binaries (stdio and HTTP)
├── docs/               # Documentation
├── tests/              # Test files
└── releases/           # Pre-built releases (not in repo)
```

## Release Process

**Note:** Most users should download pre-built releases from the Releases page. Building from source is only necessary for development.

### For Contributors

Use `./build.sh` to create an unsigned development build for personal use.

### For Maintainers (Signed Releases)

Maintainers with Apple Developer credentials can create signed, notarized releases:

1. Create credentials file:
```bash
cp .build-credentials.example .build-credentials
# Edit .build-credentials with your Apple Developer credentials
```

2. Obtain `build_release_signed.sh` from maintainers (not in public repo)

3. Build signed release:
```bash
./build_release_signed.sh
```

This creates a notarized DMG in the `releases/` directory.

## Code Style

- Follow Swift conventions
- Use 4 spaces for indentation
- Add comments for complex logic
- Keep functions focused and small

## Security

If you discover a security vulnerability, please email security@example.com instead of using the issue tracker.

## Contributor License Agreement

By submitting contributions to MCP Snitch, you agree to:

1. License your contributions under the GNU General Public License v3.0 (GPL-3.0)
2. Grant Adversis, LLC the right to relicense your contributions under commercial terms for dual-licensing purposes
3. Certify that you have the right to submit the contributions under these terms

This dual-licensing model allows the project to remain open source and free for the community while providing commercial licensing options for proprietary use cases.

Your contributions help make MCP Snitch better for everyone!

## Questions?

Feel free to open an issue for any questions about contributing.
