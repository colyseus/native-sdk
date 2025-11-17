# Colyseus Native SDK

Native SDK for the [Colyseus](https://colyseus.io/) multiplayer game server.

## 🚀 Building the Project

This project supports **two build systems**: CMake (traditional) and Zig (modern). Choose the one that fits your workflow!

### Option 1: Build with Zig (Recommended) ⚡

**Quick Start:**
```bash
# Install dependencies
git submodule update --init --recursive

# Build with Zig
zig build

# Run example
zig build run-example
```

**Why Zig?**
- ✨ Simple, readable build files
- 🌍 Easy cross-compilation
- ⚡ Faster builds with built-in caching
- 📦 No separate C compiler needed

See [BUILD_WITH_ZIG.md](BUILD_WITH_ZIG.md) for detailed documentation.

### Option 2: Build with CMake (Traditional) 🔧

```bash
# Install dependencies
git submodule update --init --recursive

# Build with CMake
mkdir -p build
cd build
cmake ..
cmake --build .

# Run example
./bin/simple_example
```

## 📚 Quick Reference

| Task | Zig | CMake |
|------|-----|-------|
| **Build** | `zig build` | `cmake --build build/` |
| **Release build** | `zig build -Doptimize=ReleaseFast` | `cmake -DCMAKE_BUILD_TYPE=Release ..` |
| **Shared library** | `zig build -Dshared=true` | `cmake -DBUILD_SHARED_LIBS=ON ..` |
| **Skip examples** | `zig build -Dexamples=false` | `cmake -DBUILD_EXAMPLES=OFF ..` |
| **Cross-compile** | `zig build -Dtarget=x86_64-windows` | (Complex, needs toolchain) |
| **Run example** | `zig build run-example` | `./build/bin/simple_example` |
| **Clean** | `rm -rf zig-out .zig-cache` | `rm -rf build/` |

## 📂 Project Structure

```
native-sdk/
├── build.zig              # Zig build configuration
├── CMakeLists.txt         # CMake build configuration  
├── include/               # Public API headers
├── src/                   # Implementation
├── examples/              # Example programs
└── third_party/           # Dependencies (cJSON, sds, uthash, wslay)
```

## 🔧 Dependencies

- **libcurl** - HTTP client library
- **cJSON** - JSON parser (included)
- **sds** - String library (included)
- **uthash** - Hash table library (included)
- **wslay** - WebSocket library (included)

## 📖 Documentation

- [Building with Zig](BUILD_WITH_ZIG.md) - Comprehensive Zig build guide
- [Windows Compilation](WINDOWS_COMPILATION.md) - Building on Windows with MinGW
- [Colyseus Documentation](https://docs.colyseus.io/) - Server documentation

## ⚠️ Status

Work in progress. API is subject to change.

## 📝 License

See LICENSE file for details.
