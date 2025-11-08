# Game Maker Extension Build System - Summary

This directory contains a complete build system for compiling the Colyseus Native SDK as a Game Maker extension.

## What's Included

### Build Files

1. **build.zig** - Main Zig build script
   - Compiles the Colyseus SDK as a shared library
   - Supports cross-compilation for Windows, macOS (Intel & Apple Silicon), and Linux
   - Organizes output by platform for easy Game Maker integration
   - Handles all dependencies (wslay, cJSON, sds, etc.)

2. **build.sh** - Unix/Linux/macOS build script
   - Convenient wrapper around `zig build`
   - Supports `--all` flag for building all platforms
   - Supports `--optimize` flag for different optimization levels

3. **build.bat** - Windows build script
   - Same functionality as build.sh for Windows users

### Documentation

1. **README.md** - Build instructions and overview
   - Prerequisites and dependencies
   - Build commands and options
   - Cross-compilation notes
   - Troubleshooting guide

2. **INTEGRATION.md** - Game Maker integration guide
   - Step-by-step setup instructions
   - External function definitions
   - Complete usage examples
   - Callback handling
   - Platform-specific considerations

3. **API_REFERENCE.md** - Complete API reference
   - All available functions with signatures
   - GML external function definitions
   - Parameter descriptions
   - Usage examples
   - Covers: Client, Room, Auth, Messaging, State, and Utility functions

4. **SUMMARY.md** (this file) - Project overview

### Configuration

1. **.gitignore** - Excludes build artifacts
   - zig-out/, zig-cache/ directories
   - Compiled libraries (.dll, .dylib, .so)
   - IDE files

## Key Features

### Cross-Platform Support
The build system creates libraries for all Game Maker target platforms:
- **Windows x64** (.dll)
- **macOS Intel x64** (.dylib)
- **macOS Apple Silicon ARM64** (.dylib)
- **Linux x64** (.so)

### Optimized Output
- Builds as shared libraries (.dynamic linkage)
- Multiple optimization levels supported:
  - `ReleaseFast` - Maximum speed (default)
  - `ReleaseSmall` - Minimum size
  - `ReleaseSafe` - Safety checks enabled
  - `Debug` - Full debugging info

### Clean Organization
Output structure mirrors Game Maker's extension layout:
```
zig-out/lib/
├── windows/x64/
├── macos/x64/
├── macos/arm64/
└── linux/x64/
```

## Build Results

A successful build produces:
- Shared library files with all Colyseus API functions
- Properly versioned libraries (e.g., libcolyseus.0.1.0.dylib)
- Symlinks for easy linking (libcolyseus.dylib → libcolyseus.0.dylib)
- Size: ~137KB (with ReleaseSmall optimization)

## API Coverage

The compiled libraries export the complete Colyseus C API:

### Client Functions
- Create/destroy clients
- Connect to servers
- Join/create rooms
- Room discovery

### Room Functions  
- Join, leave, reconnect
- Send/receive messages
- State synchronization
- Event polling

### Authentication
- Email/password auth
- Anonymous auth
- Token management
- Password reset

### Utilities
- Base64 encoding/decoding
- JSON handling
- String utilities
- SHA1 hashing

## Usage Workflow

1. **Build the libraries:**
   ```bash
   ./build.sh --all --optimize=ReleaseSmall
   ```

2. **Create Game Maker extension:**
   - Add libraries for target platforms
   - Define external functions

3. **Use in Game Maker:**
   - Create client in Create event
   - Poll room in Step event
   - Send messages in response to game events
   - Clean up in Destroy event

## Technical Details

### Dependencies
The build system automatically handles:
- **wslay**: WebSocket library (built from source)
- **cJSON**: JSON parsing (included)
- **sds**: String library (included)
- **uthash**: Hash tables (header-only)
- **libcurl**: System library (must be installed)

### Build Process
1. Configures wslay for target platform
2. Compiles wslay as static library
3. Compiles Colyseus sources
4. Links wslay, third-party libs, and system libs
5. Outputs to platform-specific directories

### Platform-Specific Linking
- **Windows**: ws2_32 (Windows Sockets)
- **macOS**: CoreFoundation, Security frameworks
- **Linux**: pthread, math library
- **All**: libcurl for HTTP/WebSocket

## Advantages of This Approach

1. **Single Build System**: One build.zig for all platforms
2. **No Manual Dependency Management**: Everything handled automatically
3. **Cross-Compilation Ready**: Build for any platform from any platform (with proper SDK)
4. **Optimized Binaries**: Zig's optimization produces compact, fast libraries
5. **Easy Maintenance**: Simple to update and extend
6. **Well Documented**: Complete docs for builders and users

## Development Notes

### Modifying the Build
Edit `build.zig` to:
- Add new source files
- Change compiler flags
- Adjust linking options
- Add new target platforms

### Testing Changes
```bash
# Clean build
rm -rf zig-out zig-cache

# Build with verbose output
zig build --verbose

# Check exported symbols (macOS/Linux)
nm -g zig-out/lib/*/x64/*.dylib | grep colyseus
```

### Version Management
Update version numbers in:
- `build.zig` (line 126): `.version = .{ .major = 0, .minor = 1, .patch = 0 }`

## Future Enhancements

Potential improvements:
1. Add automated testing
2. CI/CD pipeline for automatic builds
3. Code signing for macOS/Windows
4. Pre-built binary releases
5. Game Maker Studio marketplace package
6. Additional platform support (iOS, Android, HTML5)

## Troubleshooting

### Build Fails
- Ensure Zig 0.15.0+ is installed
- Check system dependencies (libcurl)
- Verify all git submodules are initialized

### Cross-Compilation Issues
- Some platforms require target SDK
- libcurl must be available for target platform
- May need platform-specific toolchains

### Runtime Issues
- Verify library is correctly added to Game Maker extension
- Check external function signatures match
- Ensure platform target is set correctly in extension

## Support

For issues:
1. Check documentation in this directory
2. Review main SDK docs in repository root
3. Check Colyseus documentation at docs.colyseus.io
4. File issues on GitHub repository

## License

Same license as the main Colyseus Native SDK. See LICENSE in repository root.

---

**Built with:** Zig build system
**Target:** Game Maker Studio 2 / Game Maker Studio 2023+
**SDK Version:** 0.1.0
**Last Updated:** November 2024

