/// Create Event — initialize client and join room
client = colyseus_client_create("localhost:2567", 0);
room = colyseus_client_join_or_create(client, "my_room", "{}");
callbacks = -1;

// --- Room event handlers ---

colyseus_on_join(room, function(_room) {
    show_debug_message("Joined room: " + colyseus_room_get_id(_room));

    // Send a message to the server
    colyseus_send(_room, "move", { x: 10, y: 20 });

    // Create callbacks manager for state change tracking
    callbacks = colyseus_callbacks_create(_room);

    // Listen to root state properties
    colyseus_listen(callbacks, 0, "currentTurn", function(value, prev) {
        show_debug_message("Turn changed: " + string(prev) + " -> " + string(value));
    });

    // Listen for players added to the map
    colyseus_on_add(callbacks, 0, "players", function(instance, key) {
        show_debug_message("Player joined: " + key);

        // Listen to nested properties on the player instance
        colyseus_listen(callbacks, instance, "x", function(v, p) {
            show_debug_message("x changed: " + string(v));
        });
        colyseus_listen(callbacks, instance, "y", function(v, p) {
            show_debug_message("y changed: " + string(v));
        });
        colyseus_on_add(callbacks, instance, "items", function(item, k) {
            show_debug_message("Item added at index " + k);
        });
    });

    // Listen for players removed from the map
    colyseus_on_remove(callbacks, 0, "players", function(instance, key) {
        show_debug_message("Player left: " + key);
    });
});

colyseus_on_state_change(room, function(_room) {
    var state = colyseus_room_get_state(_room);
    if (state != 0) {
        var host = colyseus_schema_get_ref(state, "host");
        var my_player = colyseus_map_get(state, "players", colyseus_room_get_session_id(_room));
        var is_host = (host == my_player);
        show_debug_message("State changed — is host: " + string(is_host));
    }
});

colyseus_on_error(room, function(code, msg) {
    show_debug_message("Room error [" + string(code) + "]: " + msg);
});

colyseus_on_leave(room, function(code, reason) {
    show_debug_message("Left room [" + string(code) + "]: " + reason);
});

// --- Message handler ---
colyseus_on_message(room, function(_room, _type, _data) {
    show_debug_message("Message received: " + _type);
    show_debug_message("Data: " + json_stringify(_data));
});
