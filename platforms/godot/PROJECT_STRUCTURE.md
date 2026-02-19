# Project Structure

```
godot/
├── 📄 colyseus.gdextension          # GDExtension configuration (tells Godot about the extension)
├── 📄 build.zig                      # Zig build configuration
├── 📄 .gitignore                     # Git ignore patterns
├── 📄 README.md                      # Full documentation
├── 📄 QUICKSTART.md                  # Quick start guide
├── 📄 example.gd                     # Example GDScript usage
├── include/                          # Godot GDExtension headers
│   ├── 📄 gdextension_interface.h   # Godot C interface
│   └── 📄 extension_api.json        # Godot API definitions
└── src/                              # C source code
    ├── 📄 godot_colyseus.h           # Main header with declarations
    ├── 📄 register_types.c           # Extension registration
    ├── 📄 colyseus_client.c          # ColyseusClient implementation
    └── 📄 colyseus_room.c            # ColyseusRoom implementation
```

## File Descriptions

### Configuration Files

- **`colyseus.gdextension`**: The main configuration file that Godot reads to load the extension. Specifies entry points and library paths for different platforms.

- **`build.zig`**: Zig build script that compiles the C code and links against the Colyseus native library. Supports cross-compilation and multiple optimization levels.

- **`build.zig.zon`**: Zig package manifest defining the project metadata and dependencies.

### Documentation

- **`README.md`**: Complete documentation including building, installation, API reference, and architecture.

- **`QUICKSTART.md`**: Condensed quick start guide for getting up and running quickly.

- **`PROJECT_STRUCTURE.md`**: This file! Explains the project structure.

### Examples

- **`example.gd`**: A complete working example showing how to use the extension in GDScript.

### Source Code

#### Main Header (`godot_colyseus.h`)
Central header file that declares all the types and functions for the extension. Contains:
- Forward declarations for ColyseusClient and ColyseusRoom
- GDExtension interface globals
- Function declarations for all exposed methods

#### Registration (`register_types.c`)
Entry point for the extension. Handles:
- Initializing the GDExtension interface
- Registering ColyseusClient and ColyseusRoom classes with Godot
- Setting up signals for room events
- Binding methods to their implementations

#### ColyseusClient (`colyseus_client.c`)
Wraps the C `colyseus_client_t` API. Provides:
- Connection to Colyseus servers
- Endpoint parsing (ws:// and wss://)
- String conversion helpers (Godot String ↔ C string)

#### ColyseusRoom (`colyseus_room.c`)
Wraps the C `colyseus_room_t` API. Handles:
- Sending/receiving messages
- Room lifecycle (join/leave)
- Property accessors (id, session_id, name)

## Architecture

```
┌─────────────────────────────────────────┐
│         Godot Engine (GDScript)         │
│   var client = ColyseusClient.new()    │
└─────────────────┬───────────────────────┘
                  │ GDExtension C API
                  │
┌─────────────────▼───────────────────────┐
│    Pure C Wrapper (this extension)      │
│  - register_types.c (registration)      │
│  - colyseus_client.c (client wrapper)   │
│  - colyseus_room.c (room wrapper)       │
│  - godot_colyseus.h (declarations)      │
└─────────────────┬───────────────────────┘
                  │ C API calls
                  │
┌─────────────────▼───────────────────────┐
│       Colyseus Native SDK (C)           │
│  - colyseus_client_t                    │
│  - colyseus_room_t                      │
│  - WebSocket, HTTP, JSON handling       │
└─────────────────────────────────────────┘
```

## Build Process

```
1. Build Colyseus Native SDK
   └─> Produces: libcolyseus.a (static library)

2. Build GDExtension (this project)
   ├─> Compiles: src/*.c
   ├─> Links: libcolyseus.a 
   └─> Produces: libcolyseus_godot.{platform}.{build_type}.{ext}
       (e.g., libcolyseus_godot.macos.debug.dylib)
```

**No godot-cpp needed!** This extension uses the raw GDExtension C API directly.

## Platform-Specific Outputs

| Platform | Debug | Release |
|----------|-------|---------|
| **macOS** | `bin/libcolyseus_godot.macos.debug.dylib` | `bin/libcolyseus_godot.macos.release.dylib` |
| **Linux** | `bin/libcolyseus_godot.linux.x86_64.debug.so` | `bin/libcolyseus_godot.linux.x86_64.release.so` |
| **Windows** | `bin/libcolyseus_godot.windows.x86_64.debug.dll` | `bin/libcolyseus_godot.windows.x86_64.release.dll` |

## Key Design Decisions

### 1. Pure C Implementation

**Why C instead of C++?**
- No dependency on godot-cpp (which is large and C++)
- Direct use of GDExtension C API (native interface)
- Faster compilation times
- Smaller binary size
- Better interoperability with the Colyseus C SDK

**Trade-offs:**
- More verbose than C++ (manual string handling, etc.)
- No RAII or modern C++ conveniences
- More manual memory management

### 2. Zig Build System

**Why Zig instead of SCons/CMake?**
- Simple `zig build` command
- Built-in cross-compilation
- No external dependencies
- Fast incremental builds
- Consistent with main SDK build system

**Trade-offs:**
- Requires Zig to be installed
- Less familiar to some developers

### 3. Minimal API Surface

This is a **barebones** implementation that exposes only the essential functionality:
- Connection and room joining
- Message sending/receiving
- Basic property access

Advanced features (state sync, schemas, etc.) are left for future implementation.

## What's Implemented

✅ Pure C implementation using GDExtension C API  
✅ Zig build system with cross-compilation  
✅ Basic class structure (ColyseusClient, ColyseusRoom)  
✅ Connection to Colyseus server  
✅ Send/receive messages  
✅ Room lifecycle (join/leave)  
✅ Godot signals for events  
✅ String conversion helpers  

## What's Not Yet Implemented

⏳ Async operations with proper callbacks  
⏳ State synchronization (delta patches)  
⏳ Reconnection logic  
⏳ Complete matchmaking API  
⏳ Error handling for edge cases  
⏳ Schema deserialization  
⏳ Dictionary options parsing  

## Code Organization Patterns

### String Handling
All string conversions go through helpers in `colyseus_client.c`:
```c
char* godot_string_to_utf8(GDExtensionConstStringPtr p_string);
void godot_string_from_utf8(GDExtensionStringPtr r_dest, const char* p_utf8);
```

### Memory Management
- Wrapper structs (ColyseusClient, ColyseusRoom) are malloc'd
- Native SDK objects are owned by wrapper structs
- Destructors free both wrapper and native objects

### Method Binding
All methods follow the GDExtension C API signature:
```c
void method_name(void* p_instance, const GDExtensionConstTypePtr* p_args, GDExtensionTypePtr r_ret);
```

## Contributing

Key areas for contribution:
- Implementing async callbacks
- State synchronization
- Schema support
- Dictionary options parsing
- More comprehensive examples
- Better error handling

The pure C approach keeps the codebase simple and maintainable!
