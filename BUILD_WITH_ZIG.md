# Building with Zig

This project can now be built using Zig's build system as an alternative to CMake/Make!

## Why Zig?

- **Simpler build files**: `build.zig` is written in Zig code (readable like a modern language)
- **Cross-compilation made easy**: Build for different platforms without separate toolchains
- **Built-in C compiler**: Zig bundles Clang, no need to install a C compiler separately
- **Better dependency management**: Cleaner handling of C dependencies
- **Faster builds**: Often faster than traditional Make builds

## Prerequisites

### Install Zig

Download and install Zig from the official website: https://ziglang.org/download/

Or using package managers:

**macOS:**
```bash
brew install zig
```

**Linux (snap):**
```bash
snap install zig --classic --beta
```

**Verify installation:**
```bash
zig version
```

### System Dependencies

You still need `libcurl` installed on your system:

**macOS:**
```bash
brew install curl
```

**Linux (Debian/Ubuntu):**
```bash
sudo apt-get install libcurl4-openssl-dev
```

**Linux (Fedora/RHEL):**
```bash
sudo dnf install libcurl-devel
```

## Building the Project

### Basic Build

Build the library and examples:

```bash
zig build
```

Output will be in `zig-out/`:
- `zig-out/lib/libcolyseus.a` - Static library
- `zig-out/bin/simple_example` - Example executable
- `zig-out/include/` - Header files

### Build Options

Show all available options:

```bash
zig build --help
```

#### Build as Shared Library

```bash
zig build -Dshared=true
```

#### Optimize for Release

```bash
zig build -Doptimize=ReleaseFast
```

Other optimization modes:
- `Debug` - No optimizations, debug symbols (default)
- `ReleaseSafe` - Optimizations + safety checks
- `ReleaseFast` - Maximum optimizations
- `ReleaseSmall` - Optimize for size

#### Skip Building Examples

```bash
zig build -Dexamples=false
```

### Cross-Compilation

One of Zig's best features is easy cross-compilation!

**Build for Windows from macOS/Linux:**
```bash
zig build -Dtarget=x86_64-windows
```

**Build for Linux from macOS:**
```bash
zig build -Dtarget=x86_64-linux
```

**Build for macOS ARM64:**
```bash
zig build -Dtarget=aarch64-macos
```

**Build for Linux ARM64 (Raspberry Pi, etc):**
```bash
zig build -Dtarget=aarch64-linux
```

See all available targets:
```bash
zig targets
```

## Running the Example

### Build and Run

```bash
zig build run-example
```

Or run the built executable directly:

```bash
./zig-out/bin/simple_example
```

## Development Workflow

### Clean Build

```bash
rm -rf zig-out .zig-cache
zig build
```

Zig's caching is very efficient, so rebuilds are fast!

### Verbose Build Output

```bash
zig build --verbose
```

### Build in Watch Mode

```bash
zig build --watch
```

This will rebuild automatically when source files change!

## Project Structure

```
.
├── build.zig              # Zig build configuration
├── include/               # Public headers
├── src/                   # Source code
├── examples/              # Example programs
├── third_party/           # Dependencies (cJSON, sds, uthash, wslay)
├── zig-out/               # Build output (created by zig build)
│   ├── bin/              # Executables
│   ├── lib/              # Libraries
│   └── include/          # Installed headers
└── .zig-cache/           # Build cache (can be deleted)
```

## Using the Library in Your Project

### As a Static Library

After building, you can link against the library:

```bash
cc your_program.c \
   -I zig-out/include \
   -L zig-out/lib \
   -lcolyseus \
   -lcurl \
   -lpthread
```

### Integrating with Zig Projects

If your project uses Zig's build system, you can add this as a dependency:

```zig
const colyseus = b.dependency("colyseus", .{
    .target = target,
    .optimize = optimize,
});

exe.linkLibrary(colyseus.artifact("colyseus"));
```

## Comparison with CMake

| Feature | CMake | Zig |
|---------|-------|-----|
| Configuration | CMakeLists.txt (DSL) | build.zig (Zig code) |
| Cross-compilation | Complex, needs toolchains | Simple `-Dtarget` flag |
| C Compiler | System-dependent | Bundled with Zig |
| Build speed | Good | Excellent |
| Caching | Via ccache | Built-in |
| Dependency management | External (vcpkg, etc) | Native support |

## Both Build Systems Supported

This project maintains both CMake and Zig build systems:

**Use CMake if you:**
- Need to integrate with existing CMake projects
- Require specific CMake features
- Are more familiar with CMake

**Use Zig if you:**
- Want faster builds
- Need easy cross-compilation
- Prefer simpler, more readable build scripts
- Want built-in caching

## Troubleshooting

### "zig: command not found"

Make sure Zig is installed and in your PATH:
```bash
which zig
```

### "libcurl not found"

Install curl development libraries (see Prerequisites section above).

### Build Cache Issues

If you encounter strange build errors, try cleaning the cache:
```bash
rm -rf .zig-cache zig-out
```

### Permission Errors

On some systems, you may need to make the binary executable:
```bash
chmod +x zig-out/bin/simple_example
```

## Advanced: Custom Build Options

You can modify `build.zig` to add custom options. For example, to add a debug flag:

```zig
const enable_debug = b.option(bool, "debug-logging", "Enable debug logging") orelse false;
```

Then use it in your build:
```bash
zig build -Ddebug-logging=true
```

## Contributing

When contributing to this project:

1. Make sure both CMake and Zig builds work
2. Test cross-compilation if you modify build files
3. Update this document if you add new build options

## Resources

- [Zig Build System Documentation](https://ziglang.org/learn/build-system/)
- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [Zig Community](https://github.com/ziglang/zig/wiki/Community)

## License

Same as the main project.

