# Colyseus GameMaker Extension - HTML5 Setup Guide

This guide explains how to configure the Colyseus extension to work with HTML5/GX.Games builds.

## Why HTML5 Requires Special Setup

GameMaker **cannot compile native C extensions to WebAssembly** for HTML5 builds. Therefore, you need to provide a JavaScript implementation that uses the [colyseus.js](https://github.com/colyseus/colyseus.js) client library.

The extension provides two implementations:
- **Native C** (`gamemaker_export.c`) - for Windows, macOS, Linux, iOS, Android
- **JavaScript** (`gamemaker_export_html5.js`) - for HTML5/GX.Games

## Setup Instructions

### 1. Add JavaScript File to Extension

In your GameMaker project, configure the Colyseus extension to include the JavaScript file:

1. Open your project in GameMaker Studio
2. Navigate to **Extensions** → **Colyseus_SDK**
3. Right-click on the extension → **Properties**
4. Click **Add File**
5. Select `gamemaker_export_html5.js`
6. Set the file properties:
   - **Kind**: `Javascript`
   - **Platform Filter**: Check only `HTML5`
   - **Copy to Targets**: Yes

### 2. Include colyseus.js Library

The JavaScript implementation requires the colyseus.js client library. You need to inject it into your HTML5 build.

#### Option A: CDN (Recommended for Quick Setup)

Add the following to your HTML5 export template:

1. Go to **Game Options** → **HTML5** → **HTML5 Options**
2. In the **HTML Template** section, add this to the `<head>` section:

```html
<script src="https://unpkg.com/colyseus.js@^0.15.0/dist/colyseus.js"></script>
```

#### Option B: Local File (Recommended for Production)

1. Download colyseus.js from: https://unpkg.com/colyseus.js@0.15.0/dist/colyseus.js
2. Place it in your project's **Included Files** (drag and drop into IDE)
3. In your HTML template, add:

```html
<script src="colyseus.js"></script>
```

### 3. Modify HTML Template (if needed)

If you're using a custom HTML template, ensure the colyseus.js script is loaded **before** GameMaker's generated JavaScript.

Example custom template snippet:

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8" />
    <title>My Game</title>
    
    <!-- Load Colyseus.js FIRST -->
    <script src="https://unpkg.com/colyseus.js@^0.15.0/dist/colyseus.js"></script>
    
    <!-- GameMaker scripts will be inserted here -->
</head>
<body>
    <!-- Game canvas and other content -->
</body>
</html>
```

### 4. Update Extension Configuration File

Your extension's `.yy` file should look like this:

```json
{
  "$GMExtension": "",
  "%Name": "Colyseus_SDK",
  "files": [
    {
      "$GMExtensionFile": "v1",
      "%Name": "Native Library",
      "filename": "libcolyseus.0.1.0.dylib",
      "kind": 1,
      "copyToTargets": 3026418979657744622,
      "functions": [
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_client_create",
          "externalName": "colyseus_gm_client_create",
          "kind": 1,
          "argCount": 2,
          "args": [1, 2],
          "returnType": 2
        }
        // ... other native functions
      ]
    },
    {
      "$GMExtensionFile": "v1",
      "%Name": "HTML5 Implementation",
      "filename": "gamemaker_export_html5.js",
      "kind": 5,
      "copyToTargets": 32,
      "functions": [
        {
          "$GMExtensionFunction": "",
          "%Name": "colyseus_client_create",
          "externalName": "colyseus_gm_client_create",
          "kind": 5,
          "argCount": 2,
          "args": [1, 2],
          "returnType": 2
        }
        // ... same function list as native
      ]
    }
  ]
}
```

**Important Notes:**
- `kind: 1` = Native DLL/dylib/so
- `kind: 5` = JavaScript
- `copyToTargets: 32` = HTML5 only (use platform bitmask)
- Both files should expose the **same function names**

## Platform Target Bitmasks

When configuring `copyToTargets`, use these values:

| Platform | Bitmask Value |
|----------|---------------|
| Windows  | 1             |
| macOS    | 4             |
| Linux    | 8             |
| HTML5    | 32            |
| Android  | 512           |
| iOS      | 1024          |

To target multiple platforms, add the values together:
- Native platforms (Win + Mac + Linux): `1 + 4 + 8 = 13`
- All platforms: Use `-1` or calculate sum

## Usage in GameMaker

Your GameMaker code **doesn't need to change**! The same GML code works for both native and HTML5:

```gml
// Create event
global.client = colyseus_client_create("localhost:2567", 0);
global.room = 0;

// Step event - process events
var event_type = colyseus_poll_event();
if (event_type == 1) { // GM_EVENT_ROOM_JOIN
    var room_handle = colyseus_event_get_room();
    show_debug_message("Room joined!");
    global.room = room_handle;
}

// Send message (works the same on all platforms)
if (global.room != 0) {
    colyseus_room_send(global.room, "chat", json_stringify({
        text: "Hello from " + (os_browser != browser_not_a_browser ? "HTML5" : "native") + "!"
    }));
}

// Clean up event
if (global.room != 0) {
    colyseus_room_leave(global.room);
    colyseus_room_free(global.room);
}
colyseus_client_free(global.client);
```

## Testing HTML5 Build

1. **Build for HTML5**: File → Create Executable → HTML5
2. **Host locally** or upload to GX.Games
3. **Open browser console** (F12) to see Colyseus logs:
   - `[Colyseus HTML5] Creating client: ws://localhost:2567`
   - `[Colyseus HTML5] Joining or creating room: my_room`
   - etc.

### Testing Locally

To test HTML5 builds locally, you need an HTTP server:

```bash
# Option 1: Python
cd path/to/html5/build
python3 -m http.server 8000

# Option 2: Node.js (npx)
cd path/to/html5/build
npx http-server -p 8000

# Option 3: PHP
cd path/to/html5/build
php -S localhost:8000
```

Then open: http://localhost:8000

## Common Issues

### "Colyseus is not defined"

**Problem**: The colyseus.js library isn't loaded before your game code.

**Solution**: 
- Ensure colyseus.js script tag is in the HTML template
- Check browser console for 404 errors
- Verify the CDN URL is accessible

### Functions Not Found

**Problem**: GameMaker can't find the JavaScript functions.

**Solution**:
- Check that `gamemaker_export_html5.js` is added to extension
- Verify platform filter includes HTML5
- Ensure function names match exactly (case-sensitive)

### WebSocket Connection Fails

**Problem**: Can't connect to server from HTML5 build.

**Solutions**:
- Use `wss://` for HTTPS sites (secure WebSocket required)
- Enable CORS on your Colyseus server
- Check browser console for security errors

### Mixed Content Error

**Problem**: HTTPS site trying to connect to `ws://` (insecure WebSocket).

**Solution**: Use secure WebSocket when creating client:

```gml
// For production (HTTPS sites)
global.client = colyseus_client_create("yourserver.com:443", 1);

// For local development (HTTP sites)
global.client = colyseus_client_create("localhost:2567", 0);
```

## Event Types Reference

These constants match between C and JavaScript:

| Event | Value | Triggered When |
|-------|-------|----------------|
| `GM_EVENT_NONE` | 0 | No event |
| `GM_EVENT_ROOM_JOIN` | 1 | Successfully joined room |
| `GM_EVENT_ROOM_STATE_CHANGE` | 2 | Room state updated |
| `GM_EVENT_ROOM_MESSAGE` | 3 | Message received from server |
| `GM_EVENT_ROOM_ERROR` | 4 | Room error occurred |
| `GM_EVENT_ROOM_LEAVE` | 5 | Left room |
| `GM_EVENT_CLIENT_ERROR` | 6 | Client connection error |

## API Compatibility

All functions from the native implementation are available in HTML5:

✅ Client Management
- `colyseus_client_create()`
- `colyseus_client_free()`

✅ Room Operations
- `colyseus_client_join_or_create()`
- `colyseus_client_create_room()`
- `colyseus_client_join()`
- `colyseus_client_join_by_id()`
- `colyseus_client_reconnect()`
- `colyseus_room_leave()`
- `colyseus_room_free()`

✅ Messaging
- `colyseus_room_send()`
- `colyseus_room_send_bytes()`
- `colyseus_room_send_int()`

✅ Room Info
- `colyseus_room_get_id()`
- `colyseus_room_get_session_id()`
- `colyseus_room_get_name()`
- `colyseus_room_has_joined()`

✅ Event Polling
- `colyseus_poll_event()`
- `colyseus_event_get_room()`
- `colyseus_event_get_code()`
- `colyseus_event_get_message()`
- `colyseus_event_get_data()`
- `colyseus_event_get_data_length()`

## Performance Considerations

### HTML5 vs Native

- **Native builds**: Direct C implementation, lowest latency
- **HTML5 builds**: JavaScript bridge, slightly higher overhead but negligible for most games

### Optimization Tips

1. **Batch messages**: Send multiple game events in one message
2. **Use binary data**: More efficient than JSON for frequent updates
3. **Limit state sync**: Only send changed data
4. **Poll events efficiently**: Don't poll more than once per frame

## GX.Games Specific Notes

When deploying to GX.Games:

1. **Use secure WebSocket** (`wss://`) - GX.Games uses HTTPS
2. **CORS must be enabled** on your Colyseus server
3. **Test thoroughly** - GX.Games environment may have additional restrictions

### Example GX.Games Configuration

```gml
// Detect GX.Games environment
var is_gxgames = (os_browser == browser_not_a_browser) == false;
var server_url = is_gxgames ? "yourserver.com:443" : "localhost:2567";
var use_secure = is_gxgames ? 1 : 0;

global.client = colyseus_client_create(server_url, use_secure);
```

## Next Steps

- See [API_REFERENCE.md](API_REFERENCE.md) for full API documentation
- Check [EXAMPLE.md](EXAMPLE.md) for complete usage examples
- Read [INTEGRATION.md](INTEGRATION.md) for advanced integration patterns

## Support

If you encounter issues:

1. Check browser console for JavaScript errors
2. Verify colyseus.js version compatibility (0.15.x recommended)
3. Test with native build first to isolate platform-specific issues
4. Review Colyseus server logs for connection issues

