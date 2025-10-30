# Building Local Harness from Source

This guide covers building Local Harness from source for development or if pre-built binaries don't work on your system.

## Prerequisites

### Required
- **Zig compiler** (version 0.15.2 or later)
- **Ollama** - must be running locally
- **POSIX-compatible system** (Linux or macOS)

### Installing Zig

#### Linux
```bash
# Download Zig 0.15.2
wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
tar -xf zig-linux-x86_64-0.15.2.tar.xz
sudo mv zig-linux-x86_64-0.15.2 /opt/zig

# Add to PATH (add to ~/.bashrc or ~/.zshrc)
export PATH=$PATH:/opt/zig
```

#### macOS
```bash
# Using Homebrew
brew install zig

# Or download directly
wget https://ziglang.org/download/0.15.2/zig-macos-x86_64-0.15.2.tar.xz
# (for Intel)
# or
wget https://ziglang.org/download/0.15.2/zig-macos-aarch64-0.15.2.tar.xz
# (for Apple Silicon)
```

#### Verify Installation
```bash
zig version
# Should output: 0.15.2 or later
```

### Installing Ollama

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model (e.g., llama3.2)
ollama pull llama3.2

# Start Ollama server
ollama serve
```

## Building

### 1. Clone the Repository
```bash
git clone https://github.com/humanjesse/localharness.git
cd localharness
```

### 2. Build the Project

#### Debug Build (for development)
```bash
zig build
```

The binary will be at: `zig-out/bin/localharness`

#### Release Build (optimized)
```bash
zig build -Doptimize=ReleaseSafe
```

Or for maximum optimization:
```bash
zig build -Doptimize=ReleaseFast
```

### 3. Run
```bash
./zig-out/bin/localharness
```

## Build Options

### Optimization Levels

- **Debug** (default): No optimization, includes debug symbols
  ```bash
  zig build
  ```

- **ReleaseSafe**: Optimized with safety checks
  ```bash
  zig build -Doptimize=ReleaseSafe
  ```

- **ReleaseFast**: Maximum optimization, minimal safety checks
  ```bash
  zig build -Doptimize=ReleaseFast
  ```

- **ReleaseSmall**: Optimize for binary size
  ```bash
  zig build -Doptimize=ReleaseSmall
  ```

## Installation

### Install to Local User Directory
```bash
# Build release version
zig build -Doptimize=ReleaseSafe

# Copy to local bin
mkdir -p ~/.local/bin
cp zig-out/bin/localharness ~/.local/bin/

# Ensure ~/.local/bin is in your PATH
echo 'export PATH=$PATH:~/.local/bin' >> ~/.bashrc  # or ~/.zshrc
source ~/.bashrc
```

### System-wide Installation (requires sudo)
```bash
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/localharness /usr/local/bin/
```

## Development

### Project Structure
```
localharness/
├── build.zig           # Build configuration
├── main.zig            # Entry point, app logic, config
├── ui.zig              # Terminal UI, input handling, drawing
├── markdown.zig        # Markdown parser and renderer
├── ollama.zig          # Ollama API client
└── lexer.zig           # Markdown lexer
```

### Running Tests
```bash
zig build test
```

### Clean Build Artifacts
```bash
rm -rf zig-cache/ zig-out/
```

## Troubleshooting

### Build Errors

#### "zig: command not found"
- Ensure Zig is installed and in your PATH
- Verify: `which zig`

#### Version Mismatch
- Local Harness requires Zig 0.15.2+
- Check: `zig version`
- Download correct version from: https://ziglang.org/download/

#### C Library Not Found
Local Harness uses C libraries for terminal control:
```bash
# Ubuntu/Debian
sudo apt-get install libc6-dev

# Fedora
sudo dnf install glibc-devel

# Arch
sudo pacman -S glibc
```

### Runtime Errors

#### "Connection refused" when running
- Ensure Ollama is running: `ollama serve`
- Check if port 11434 is available: `curl http://localhost:11434`

#### Terminal rendering issues
- Ensure your terminal supports ANSI escape codes
- Try a modern terminal: kitty, alacritty, iTerm2, Ghostty

#### "Model not found"
- Pull the model first: `ollama pull llama3.2`
- Or configure a different model in `~/.config/localharness/config.json`

## Cross-Compilation

Zig supports cross-compilation. To build for a different target:

### Build for Linux x86_64 (from any platform)
```bash
zig build -Dtarget=x86_64-linux
```

### Build for macOS (from any platform)
```bash
# Intel Mac
zig build -Dtarget=x86_64-macos

# Apple Silicon
zig build -Dtarget=aarch64-macos
```

**Note:** Cross-compilation may require system libraries for the target platform.

## Contributing

When contributing, please:
1. Test your changes with `zig build test`
2. Ensure code builds without warnings
3. Follow the existing code style
4. Test on your platform and document any platform-specific issues

## Getting Help

- **Issues:** https://github.com/humanjesse/localharness/issues
- **Zig Documentation:** https://ziglang.org/documentation/
- **Ollama Documentation:** https://docs.ollama.com/

## License

MIT License - see LICENSE file for details.
