# ZodoLlama Documentation

Welcome to the ZodoLlama documentation. This guide will help you understand, use, and contribute to the project.

## Quick Links

- [Main README](../README.md) - Project overview and quick start
- [CHANGELOG](../CHANGELOG.md) - Version history and recent changes

## User Guide

New to ZodoLlama? Start here:

- [Installation](user-guide/installation.md) - Building from source and setup
- [Configuration](user-guide/configuration.md) - Customizing ZodoLlama
- [Features](user-guide/features.md) - Complete feature guide

## Development

Contributing to ZodoLlama:

- [Deployment](development/deployment.md) - Release and deployment process
- [Zig HTTP Client](development/zig-http-client.md) - Working with Zig's HTTP client
- [Contributing](development/contributing.md) - How to contribute

## Architecture

Understanding how ZodoLlama works:

- [Overview](architecture/overview.md) - High-level architecture
- [Tool Calling System](architecture/tool-calling.md) - How tool calling works
- [Task Management](architecture/task-management.md) - Scratch space and task tracking
- [Master Loop & Graph RAG](architecture/master-loop-graphrag.md) - Agentic behavior and future plans

## Archive

Historical documentation and implementation notes:

- [Tool Calling Fixes](archive/tool-calling-fixes.md) - Historical fix documentation
- [Tool Calling Actual Fix](archive/tool-calling-actual-fix.md) - The real fix details
- [Before/After Flow](archive/before-after-flow.md) - Flow comparison
- [Task Tools Fix](archive/task-tools-fix.md) - Task system fixes (outdated)
- [Initial Planning](archive/initial-planning.md) - Early planning notes

## Project Structure

```
zodollama/
├── README.md              # Main documentation (start here!)
├── CHANGELOG.md           # Version history
├── build.zig              # Build configuration
├── main.zig               # Entry point
├── app.zig                # Core application
├── ui.zig                 # Terminal UI
├── ollama.zig             # Ollama API client
├── tools.zig              # Tool definitions
├── permission.zig         # Permission system
└── docs/                  # Additional documentation (you are here)
    ├── user-guide/        # User-facing guides
    ├── development/       # Developer guides
    ├── architecture/      # Technical architecture
    └── archive/           # Historical documentation
```

## Getting Help

- **Issues:** https://github.com/humanjesse/zodollama/issues
- **Discussions:** Use GitHub Discussions for questions
- **Contributing:** See [Contributing Guide](development/contributing.md)
