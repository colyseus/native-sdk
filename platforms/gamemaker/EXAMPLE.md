# GameMaker Colyseus SDK - Example Usage

This example demonstrates how to integrate Colyseus into your GameMaker project.

## Setup

1. Build the Colyseus library for your platform(s):
   ```bash
   cd platforms/gamemaker
   zig build -Dall=true -Doptimize=ReleaseFast
   ```

2. Copy the compiled libraries to your GameMaker project's `datafiles` or appropriate extension directory

3. Import `colyseus_sdk.gml` into your GameMaker project

## Basic Example

### Step 1: Create a Colyseus Manager Object

Create an object called `obj_colyseus_manager` to handle the Colyseus connection.

#### Create Event

```gml
// Initialize the Colyseus SDK
colyseus_init();

// Create a client
client = external_call(global.colyseus_client_create, "localhost:2567", 0);
room = 0;
is_connected = false;

// Set up event handlers
global.on_colyseus_room_join = method(self, function(room_handle) {
    show_debug_message("Successfully joined room!");
    room = room_handle;
    is_connected = true;
    
    // Get room information
    var room_id = external_call(global.colyseus_room_get_id, room);
    var session_id = external_call(global.colyseus_room_get_session_id, room);
    show_debug_message("Room ID: " + room_id);
    show_debug_message("Session ID: " + session_id);
});

global.on_colyseus_state_change = method(self, function(room_handle) {
    show_debug_message("Room state changed");
    // Handle state changes here
});

global.on_colyseus_message = method(self, function(room_handle, data_length) {
    show_debug_message("Received message: " + string(data_length) + " bytes");
    
    // Get the message data
    var message_text = external_call(global.colyseus_event_get_message);
    show_debug_message("Message: " + message_text);
    
    // Parse as JSON if needed
    try {
        var data = json_parse(message_text);
        // Handle your message data
    } catch (e) {
        show_debug_message("Failed to parse message as JSON");
    }
});

global.on_colyseus_room_error = method(self, function(room_handle, code, message) {
    show_debug_message("Room error [" + string(code) + "]: " + message);
});

global.on_colyseus_room_leave = method(self, function(room_handle, code, reason) {
    show_debug_message("Left room [" + string(code) + "]: " + reason);
    is_connected = false;
    room = 0;
});

global.on_colyseus_client_error = method(self, function(code, message) {
    show_debug_message("Client error [" + string(code) + "]: " + message);
});

// Join or create a room
show_debug_message("Attempting to join room...");
external_call(global.colyseus_client_join_or_create, client, "my_room", "{}");
```

#### Step Event

```gml
// Process Colyseus events every frame
colyseus_process_events();
```

#### Clean Up Event

```gml
// Disconnect and cleanup
if (room != 0) {
    external_call(global.colyseus_room_leave, room);
    external_call(global.colyseus_room_free, room);
}

if (client != 0) {
    external_call(global.colyseus_client_free, client);
}

colyseus_free();
```

### Step 2: Create a Player Object

Create an object called `obj_player` to send player input to the server.

#### Create Event

```gml
player_name = "Player" + string(irandom(9999));
position_x = x;
position_y = y;
```

#### Step Event

```gml
// Handle input
var moved = false;
var new_x = x;
var new_y = y;

if (keyboard_check(vk_left)) {
    new_x -= 4;
    moved = true;
}
if (keyboard_check(vk_right)) {
    new_x += 4;
    moved = true;
}
if (keyboard_check(vk_up)) {
    new_y -= 4;
    moved = true;
}
if (keyboard_check(vk_down)) {
    new_y += 4;
    moved = true;
}

// Update position
x = new_x;
y = new_y;

// Send position update to server if moved
if (moved && obj_colyseus_manager.is_connected) {
    var message = json_stringify({
        x: x,
        y: y
    });
    
    external_call(
        global.colyseus_room_send,
        obj_colyseus_manager.room,
        "move",
        message
    );
}
```

#### Draw Event

```gml
draw_self();
draw_text(x, y - 20, player_name);
```

### Step 3: Sending Different Message Types

#### String Message Type

```gml
var data = json_stringify({
    action: "attack",
    target_id: "player123"
});

external_call(
    global.colyseus_room_send,
    obj_colyseus_manager.room,
    "player_action",
    data
);
```

#### Integer Message Type

```gml
// Useful for performance when you have many message types
var PLAYER_MOVE = 1;
var data = json_stringify({x: 100, y: 200});

external_call(
    global.colyseus_room_send_int,
    obj_colyseus_manager.room,
    PLAYER_MOVE,
    data
);
```

## Advanced Example: Chat System

### obj_chat_manager (Create Event)

```gml
chat_messages = [];
chat_input = "";

global.on_colyseus_message = method(self, function(room_handle, data_length) {
    var message_str = external_call(global.colyseus_event_get_message);
    
    try {
        var data = json_parse(message_str);
        
        // Check if it's a chat message
        if (variable_struct_exists(data, "type") && data.type == "chat") {
            array_push(chat_messages, {
                username: data.username,
                text: data.text,
                timestamp: current_time
            });
            
            // Keep only last 50 messages
            if (array_length(chat_messages) > 50) {
                array_delete(chat_messages, 0, 1);
            }
        }
    } catch (e) {
        show_debug_message("Failed to parse chat message");
    }
});
```

### obj_chat_manager (Step Event)

```gml
// Handle chat input
if (keyboard_check_pressed(vk_enter)) {
    if (chat_input != "" && obj_colyseus_manager.is_connected) {
        // Send chat message
        var message = json_stringify({
            type: "chat",
            text: chat_input
        });
        
        external_call(
            global.colyseus_room_send,
            obj_colyseus_manager.room,
            "chat",
            message
        );
        
        chat_input = "";
    }
}
```

### obj_chat_manager (Draw GUI Event)

```gml
// Draw chat messages
var start_y = 500;
for (var i = 0; i < array_length(chat_messages); i++) {
    var msg = chat_messages[i];
    var text = msg.username + ": " + msg.text;
    draw_text(10, start_y - (i * 20), text);
}

// Draw input
draw_text(10, 600, "> " + chat_input);
```

## Room Options Example

You can pass options when joining a room:

```gml
var options = json_stringify({
    map: "desert",
    max_players: 4,
    game_mode: "deathmatch"
});

external_call(
    global.colyseus_client_join_or_create,
    client,
    "game_room",
    options
);
```

## Reconnection Example

If you want to support reconnection:

```gml
// Store reconnection token when joining
global.on_colyseus_room_join = method(self, function(room_handle) {
    room = room_handle;
    
    // Store reconnection token for later use
    // Note: You'll need to add this to the C API if not already present
    // For now, store the session ID
    reconnection_token = external_call(global.colyseus_room_get_session_id, room);
});

// Later, to reconnect:
if (reconnection_token != "") {
    external_call(
        global.colyseus_client_reconnect,
        client,
        reconnection_token
    );
}
```

## Multiple Rooms Example

You can join multiple rooms simultaneously:

```gml
// Create separate room handles
lobby_room = 0;
game_room = 0;

// Join lobby
external_call(global.colyseus_client_join_or_create, client, "lobby", "{}");

// Join game room
external_call(global.colyseus_client_join_or_create, client, "game", "{}");

// Handle events - check which room the event is for
global.on_colyseus_room_join = method(self, function(room_handle) {
    var room_name = external_call(global.colyseus_room_get_name, room_handle);
    
    if (room_name == "lobby") {
        lobby_room = room_handle;
    } else if (room_name == "game") {
        game_room = room_handle;
    }
});
```

## Performance Tips

1. **Process events only when needed**: If your game has a pause state, you might want to skip event processing:
   ```gml
   if (!game_paused) {
       colyseus_process_events();
   }
   ```

2. **Throttle updates**: Don't send position updates every frame if not necessary:
   ```gml
   update_timer++;
   if (update_timer >= 3) {  // Update every 3 frames
       update_timer = 0;
       // Send update
   }
   ```

3. **Batch messages**: If you need to send multiple pieces of data, combine them into one message:
   ```gml
   var batch = json_stringify({
       position: {x: x, y: y},
       health: hp,
       rotation: image_angle
   });
   external_call(global.colyseus_room_send, room, "update", batch);
   ```

## Troubleshooting

### Library not found
- Ensure the library file is in the correct location for your platform
- Check the library name matches in `colyseus_init()`

### No events received
- Make sure you're calling `colyseus_process_events()` in a Step event
- Check that your event handlers are properly set up before joining a room

### Connection fails
- Verify the server address and port are correct
- Check if the server is running and accessible
- Look at the client error events for details

### Messages not sending
- Ensure the room is joined before sending (check `is_connected` flag)
- Verify JSON syntax if sending JSON strings
- Check server logs to see if messages are being received

