# HTML5 Quick Reference Card

Quick reference for setting up and troubleshooting the Colyseus GameMaker HTML5 extension.

## ⚡ Quick Setup (3 Steps)

### 1️⃣ Add JavaScript File

In GameMaker IDE:
1. Navigate to **Extensions** → **Colyseus_SDK**
2. Right-click → **Add File** → Select `gamemaker_export_html5.js`
3. Set properties:
   - **Kind**: JavaScript
   - **Platform Filter**: ✅ HTML5 only
   - **Copy to Targets**: Yes

### 2️⃣ Add colyseus.js to HTML Template

In your HTML file (before GameMaker scripts):

```html
<script src="https://unpkg.com/colyseus.js@^0.16.0/dist/colyseus.js"></script>
```

### 3️⃣ Build & Test

- **Build**: File → Create Executable → HTML5
- **Test locally**: `python3 -m http.server 8000` in build folder
- **Open**: http://localhost:8000

## 📋 Extension Configuration (.yy file)

```json
{
  "files": [
    {
      "filename": "libcolyseus.0.1.0.dylib",
      "kind": 1,
      "copyToTargets": 13,
      "functions": [ /* ... native functions ... */ ]
    },
    {
      "filename": "gamemaker_export_html5.js",
      "kind": 5,
      "copyToTargets": 32,
      "functions": [ /* ... same functions ... */ ]
    }
  ]
}
```

**Key Values**:
- `kind: 1` = Native DLL/dylib
- `kind: 5` = JavaScript
- `copyToTargets: 13` = Windows + macOS + Linux
- `copyToTargets: 32` = HTML5

## 🎮 Platform Detection

```gml
// Detect platform at runtime
var is_html5 = (os_browser != browser_not_a_browser);

// Use secure connection for production
var server = is_html5 ? "yourserver.com:443" : "localhost:2567";
var use_wss = is_html5 ? 1 : 0;

global.client = colyseus_client_create(server, use_wss);
```

## 🔧 Common Issues & Fixes

### ❌ "Colyseus is not defined"

**Cause**: colyseus.js not loaded

**Fix**: Add to HTML `<head>`:
```html
<script src="https://unpkg.com/colyseus.js@^0.15.0/dist/colyseus.js"></script>
```

---

### ❌ "colyseus_gm_client_create is not defined"

**Cause**: JavaScript file not in extension

**Fix**: 
1. Add `gamemaker_export_html5.js` to extension
2. Set platform filter: HTML5 only
3. Clean and rebuild

---

### ❌ "WebSocket connection failed"

**Cause**: Wrong protocol or server not running

**Fix**: 
- Local dev: Use `ws://localhost:2567`
- Production: Use `wss://yourserver.com:443`
- Check server is running

---

### ❌ "Mixed content blocked"

**Cause**: HTTPS site trying to use `ws://`

**Fix**: Use `wss://` (secure WebSocket) on HTTPS sites

---

### ❌ "CORS error"

**Cause**: Server not configured for cross-origin requests

**Fix**: Add to Colyseus server:
```typescript
import cors from "cors";
app.use(cors());
```

## 📦 Files Checklist

| File | Location | Purpose |
|------|----------|---------|
| `gamemaker_export_html5.js` | `src/` | JavaScript implementation |
| `gamemaker_export.c` | `src/` | Native C implementation |
| `HTML5_SETUP.md` | `./` | Detailed setup guide |
| `html5_template.html` | `example/` | HTML template example |
| `Colyseus_SDK_HTML5.yy` | `example/` | Extension config example |

## 🌐 GX.Games Deployment

```gml
// GX.Games configuration
global.client = colyseus_client_create("yourserver.com:443", 1);
//                                      ↑ your server      ↑ use wss
```

**Server Requirements**:
- ✅ HTTPS/WSS enabled
- ✅ CORS configured
- ✅ Valid SSL certificate

## 🐛 Debugging

### Enable Debug Console

Press **D** key in HTML5 build (shows top-right overlay)

### Browser Console

Press **F12** → Console tab

Look for logs:
```
[Colyseus HTML5] Creating client: ws://localhost:2567
[Colyseus HTML5] Joining room: my_room
[Colyseus HTML5] Room joined: 1
```

### Test Connection

```gml
// Create event
global.client = colyseus_client_create("localhost:2567", 0);
global.room = 0;
global.connected = false;

// Step event
var event_type = colyseus_poll_event();

switch (event_type) {
    case 1: // GM_EVENT_ROOM_JOIN
        global.room = colyseus_event_get_room();
        global.connected = true;
        show_debug_message("✅ Connected!");
        break;
        
    case 4: // GM_EVENT_ROOM_ERROR
        var error = colyseus_event_get_message();
        show_debug_message("❌ Error: " + error);
        break;
        
    case 6: // GM_EVENT_CLIENT_ERROR
        var error = colyseus_event_get_message();
        show_debug_message("❌ Client Error: " + error);
        break;
}

// Draw event (for debugging)
draw_text(10, 10, "Connected: " + string(global.connected));
```

## 🎯 Event Types

| Constant | Value | Meaning |
|----------|-------|---------|
| `GM_EVENT_NONE` | 0 | No event |
| `GM_EVENT_ROOM_JOIN` | 1 | ✅ Joined room |
| `GM_EVENT_ROOM_STATE_CHANGE` | 2 | 🔄 State updated |
| `GM_EVENT_ROOM_MESSAGE` | 3 | 📨 Message received |
| `GM_EVENT_ROOM_ERROR` | 4 | ❌ Room error |
| `GM_EVENT_ROOM_LEAVE` | 5 | 👋 Left room |
| `GM_EVENT_CLIENT_ERROR` | 6 | ❌ Client error |

## 📊 API Compatibility Matrix

| Function | Native | HTML5 | Notes |
|----------|--------|-------|-------|
| `colyseus_client_create` | ✅ | ✅ | |
| `colyseus_client_free` | ✅ | ✅ | |
| `colyseus_client_join_or_create` | ✅ | ✅ | |
| `colyseus_client_create_room` | ✅ | ✅ | |
| `colyseus_client_join` | ✅ | ✅ | |
| `colyseus_client_join_by_id` | ✅ | ✅ | |
| `colyseus_client_reconnect` | ✅ | ✅ | |
| `colyseus_room_leave` | ✅ | ✅ | |
| `colyseus_room_free` | ✅ | ✅ | |
| `colyseus_room_send` | ✅ | ✅ | |
| `colyseus_room_send_bytes` | ✅ | ✅ | |
| `colyseus_room_send_int` | ✅ | ✅ | |
| `colyseus_room_get_id` | ✅ | ✅ | |
| `colyseus_room_get_session_id` | ✅ | ✅ | |
| `colyseus_room_get_name` | ✅ | ✅ | |
| `colyseus_room_is_connected` | ✅ | ✅ | |
| `colyseus_poll_event` | ✅ | ✅ | |
| `colyseus_event_get_room` | ✅ | ✅ | |
| `colyseus_event_get_code` | ✅ | ✅ | |
| `colyseus_event_get_message` | ✅ | ✅ | |
| `colyseus_event_get_data` | ✅ | ✅ | |
| `colyseus_event_get_data_length` | ✅ | ✅ | |

**Total**: 22/22 functions supported ✅

## 🔗 Quick Links

- 📖 [Detailed Setup Guide](HTML5_SETUP.md)
- 📚 [API Reference](API_REFERENCE.md)
- 💡 [Examples](EXAMPLE.md)
- 🏗️ [Implementation Details](HTML5_IMPLEMENTATION_SUMMARY.md)
- 🚀 [QuickStart](QUICKSTART.md)

## 💬 Need Help?

1. Check browser console (F12)
2. Enable debug overlay (D key)
3. Review [HTML5_SETUP.md](HTML5_SETUP.md)
4. Check server logs
5. Test with native build first

## ✅ Pre-Flight Checklist

Before building for HTML5:

- [ ] `gamemaker_export_html5.js` added to extension
- [ ] Platform filter set to HTML5 only
- [ ] colyseus.js script tag in HTML template
- [ ] Server endpoint configured correctly
- [ ] Server is running and accessible
- [ ] CORS enabled on server (if cross-origin)
- [ ] Using wss:// for HTTPS sites

---

**TIP**: Keep this reference handy when building for HTML5! 🚀

