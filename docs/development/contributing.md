# Contributing to ZodoLlama

Thank you for your interest in contributing to ZodoLlama! This guide will help you get started.

## Getting Started

### Prerequisites

- **Zig** 0.15.2 or later
- **Ollama** running locally
- Git for version control
- A POSIX-compatible system (Linux or macOS)

### Setting Up Development Environment

1. **Clone the repository:**
   ```bash
   git clone https://github.com/humanjesse/zodollama.git
   cd zodollama
   ```

2. **Build the project:**
   ```bash
   zig build
   ```

3. **Run ZodoLlama:**
   ```bash
   ./zig-out/bin/zodollama
   ```

4. **Make changes and rebuild:**
   ```bash
   zig build
   ```

## Project Structure

```
zodollama/
├── main.zig            # Entry point (56 lines)
├── app.zig             # Core application (2006 lines)
├── ui.zig              # Terminal UI (559 lines)
├── markdown.zig        # Markdown parser/renderer (1502 lines)
├── ollama.zig          # Ollama API client (423 lines)
├── tools.zig           # Tool system (643 lines)
├── permission.zig      # Permission system (684 lines)
├── config.zig          # Configuration (344 lines)
├── types.zig           # Shared types (44 lines)
├── state.zig           # Task state (69 lines)
├── context.zig         # Tool context (18 lines)
├── render.zig          # Text utilities (252 lines)
├── tree.zig            # File tree (365 lines)
├── lexer.zig           # Markdown lexer (194 lines)
├── build.zig           # Build configuration
└── docs/               # Documentation
```

## Development Workflow

### 1. Find an Issue or Create One

Check the [issue tracker](https://github.com/humanjesse/zodollama/issues) for:
- `good first issue` - Beginner-friendly tasks
- `help wanted` - Looking for contributors
- `bug` - Something isn't working
- `enhancement` - New feature requests

Or create a new issue to discuss your idea.

### 2. Create a Branch

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/bug-description
```

### 3. Make Your Changes

Follow the coding conventions below and test your changes thoroughly.

### 4. Test Your Changes

```bash
# Build
zig build

# Run
./zig-out/bin/zodollama

# Test various scenarios:
# - Basic chat
# - Tool calling
# - Permission system
# - Markdown rendering
# - Scroll behavior
```

### 5. Commit Your Changes

Follow conventional commit format:

```bash
git add .
git commit -m "feat: add syntax highlighting for code blocks"
# or
git commit -m "fix: resolve crash when terminal resizes during streaming"
```

**Commit types:**
- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `style:` - Code formatting (no logic change)
- `refactor:` - Code restructuring (no functionality change)
- `perf:` - Performance improvements
- `test:` - Adding tests
- `chore:` - Maintenance tasks

### 6. Push and Create Pull Request

```bash
git push -u origin feature/your-feature-name
```

Then create a pull request on GitHub with:
- Clear description of changes
- Reference to related issue (if applicable)
- Screenshots (for UI changes)
- Testing performed

## Coding Conventions

### Zig Style

Follow Zig's standard style:

```zig
// Use camelCase for function names
pub fn handleUserInput() void { }

// Use PascalCase for types
pub const MyStruct = struct { };

// Use snake_case for variables
const user_input = readInput();

// Use 4 spaces for indentation (Zig standard)
if (condition) {
    doSomething();
}
```

### Code Organization

- Keep functions focused and small
- Add comments for complex logic
- Use meaningful variable names
- Prefer explicit over implicit
- Handle errors properly with `try` and `catch`

### Memory Management

```zig
// Always pair allocations with deallocations
const buffer = try allocator.alloc(u8, size);
defer allocator.free(buffer);

// Use errdefer for error cleanup
const resource = try allocate();
errdefer deallocate(resource);

// Prefer arena allocators for temporary data
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const temp = arena.allocator();
```

### Error Handling

```zig
// Use explicit error types
pub fn readFile(path: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return err;  // Propagate specific error
    };
    defer file.close();
    // ...
}

// Provide context for errors
return error.InvalidFormat; // Not just 'error'
```

## Areas to Contribute

### Easy Wins

- **Documentation:** Improve/expand docs
- **Examples:** Add usage examples
- **Bug fixes:** Fix reported issues
- **Tests:** Add unit tests (currently lacking)

### Medium Difficulty

- **UI Improvements:** Better rendering, colors, layouts
- **Tool additions:** New tools for file operations, git, etc.
- **Configuration:** More config options
- **Platform support:** macOS testing and fixes

### Advanced

- **Graph RAG:** Implement code graph and semantic search (see plan)
- **Performance:** Optimize rendering, memory usage
- **Architecture:** Refactoring for maintainability
- **Multi-language support:** Parser for Python, JS, etc.

## Testing

### Manual Testing Checklist

Before submitting a PR, test:

- [ ] Basic chat functionality
- [ ] Tool calling (get_file_tree, read_file)
- [ ] Task management (add, list, update)
- [ ] Permission system prompts
- [ ] Markdown rendering (headers, lists, tables, code)
- [ ] Scrolling (mouse wheel, auto-scroll)
- [ ] Thinking blocks (expand/collapse)
- [ ] Configuration loading
- [ ] Multiple conversations (send several messages)

### Future: Automated Tests

We plan to add:
- Unit tests for core components
- Integration tests for tool system
- End-to-end tests

## Documentation

When adding features:

1. **Update relevant docs:**
   - User guides for user-facing features
   - Architecture docs for internal changes
   - Configuration guide for new config options

2. **Add code comments:**
   - Document complex algorithms
   - Explain non-obvious design decisions
   - Add examples for public APIs

3. **Update CHANGELOG.md:**
   - Add entry under `[Unreleased]`
   - Follow conventional commit format

## Pull Request Guidelines

### PR Description

Include:
- **What**: Brief summary of changes
- **Why**: Reason for the change
- **How**: Implementation approach (for complex changes)
- **Testing**: How you tested it
- **Screenshots**: For UI changes

### Example PR Description

```markdown
## What
Add syntax highlighting for code blocks in markdown rendering

## Why
Improves readability of code samples in AI responses

## How
- Integrated tree-sitter for Zig language parsing
- Added color mapping for syntax tokens
- Updated markdown renderer to apply highlighting

## Testing
- Tested with code blocks in various languages
- Verified color output in different terminals
- Checked performance with large code blocks

## Screenshots
[Screenshot of highlighted code]
```

### Review Process

1. Maintainer reviews code
2. Feedback provided (if needed)
3. You address feedback
4. Approved and merged

## Code Review Checklist

Reviewers will check for:

- [ ] Code follows Zig conventions
- [ ] Memory is properly managed (no leaks)
- [ ] Errors are handled appropriately
- [ ] Changes are tested
- [ ] Documentation is updated
- [ ] Commit messages follow conventions
- [ ] No breaking changes (or documented if necessary)

## Release Process

See [Deployment Guide](deployment.md) for:
- Creating releases
- Semantic versioning
- Tag management
- Release notes

## Getting Help

**Questions about contributing:**
- Open a discussion on GitHub
- Ask in issues before starting large changes
- Request clarification on existing issues

**Technical questions:**
- Zig documentation: https://ziglang.org/documentation/
- Ollama API docs: https://docs.ollama.com/

**Project-specific:**
- Read architecture docs: [Architecture Overview](../architecture/overview.md)
- Check implementation details: Various docs in `docs/architecture/`

## Code of Conduct

### Our Standards

- Be respectful and welcoming
- Accept constructive criticism
- Focus on what's best for the project
- Show empathy towards others

### Unacceptable Behavior

- Harassment or discrimination
- Trolling or insulting comments
- Publishing others' private information
- Other unprofessional conduct

### Enforcement

Report unacceptable behavior to project maintainers. All complaints will be reviewed and investigated.

## Recognition

Contributors will be:
- Listed in release notes (for significant contributions)
- Credited in documentation (where applicable)
- Acknowledged in the project README

## License

By contributing, you agree that your contributions will be licensed under the MIT License, the same license as the project.

---

## Quick Start for First-Time Contributors

```bash
# 1. Fork and clone
git clone https://github.com/humanjesse/zodollama.git
cd zodollama

# 2. Create branch
git checkout -b fix/my-first-contribution

# 3. Make a small change (e.g., fix typo in README)
# Edit files...

# 4. Test
zig build
./zig-out/bin/zodollama

# 5. Commit
git add .
git commit -m "docs: fix typo in README"

# 6. Push
git push -u origin fix/my-first-contribution

# 7. Create PR on GitHub
```

Welcome aboard, and happy coding! 🚀
