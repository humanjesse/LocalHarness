# Local Harness Documentation

Welcome to the Local Harness documentation. This guide will help you understand, use, and contribute to the project.

## Quick Links

- [Main README](../README.md) - Project overview and quick start
- [CHANGELOG](../CHANGELOG.md) - Version history and recent changes

## User Guide

New to Local Harness? Start here:

- [Installation](user-guide/installation.md) - Building from source and setup
- [Features](user-guide/features.md) - Complete feature guide
- [Commands](user-guide/commands.md) - **NEW** Quick reference for all commands
- [Configuration](user-guide/configuration.md) - Config file and `/config` editor

## Development

Contributing to Local Harness:

- [Deployment](development/deployment.md) - Release and deployment process
- [Zig HTTP Client](development/zig-http-client.md) - Working with Zig's HTTP client

## Architecture

Understanding how Local Harness works:

- [Overview](architecture/overview.md) - High-level architecture
- [Config Editor](architecture/config-editor.md) - **NEW** Full-screen TUI config editor architecture
- [Config Editor Data Flow](architecture/config-editor-flow.md) - **NEW** Detailed flow examples
- [Tool Calling System](architecture/tool-calling.md) - How tool calling works
- [GraphRAG](architecture/graphrag.md) - Context compression system
- [Unified Read File](architecture/unified-read-file.md) - Smart file reading with agent curation

## Archive

Historical documentation and implementation notes:

- [Tool Calling Fixes](archive/tool-calling-fixes.md) - Historical fix documentation
- [Tool Calling Actual Fix](archive/tool-calling-actual-fix.md) - The real fix details
- [Before/After Flow](archive/before-after-flow.md) - Flow comparison
- [Task Tools Fix](archive/task-tools-fix.md) - Task system fixes (outdated)
- [Initial Planning](archive/initial-planning.md) - Early planning notes

## Project Structure

```
localharness/
├── README.md              # Main documentation (start here!)
├── CHANGELOG.md           # Version history
├── build.zig              # Build configuration
├── main.zig               # Entry point
├── app.zig                # Core application
├── ui.zig                 # Terminal UI
├── ollama.zig             # Ollama API client
├── lmstudio.zig           # LM Studio API client
├── llm_provider.zig       # Provider abstraction layer
├── tools.zig              # Tool definitions
├── permission.zig         # Permission system
└── docs/                  # Additional documentation (you are here)
    ├── user-guide/        # User-facing guides
    ├── development/       # Developer guides
    ├── architecture/      # Technical architecture
    └── archive/           # Historical documentation
```

## Getting Help

- **Issues:** Report bugs and request features via GitHub Issues
- **Discussions:** Use GitHub Discussions for questions
