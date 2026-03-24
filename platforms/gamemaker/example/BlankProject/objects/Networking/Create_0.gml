/// Create Event — initialize client and join room
client = -1;
colyseus_room = -1;
callbacks = -1;

// Skip room join when running GMTL tests
if (gmtl_has_finished || gmtl_is_initializing) {
    exit;
}

client = colyseus_client_create("http://localhost:2567");
colyseus_room = colyseus_client_join_or_create(client, "test_room", "{}");

// --- Room event handlers ---

colyseus_on_join(colyseus_room, function(_room) {
    show_debug_message("Joined room: " + colyseus_room_get_id(_room));

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
            show_debug_message("Position changed");
        });
        colyseus_listen(callbacks, instance, "y", function(v, p) {
            show_debug_message("Position changed");
        });
        colyseus_on_add(callbacks, instance, "items", function(item, k) {
            show_debug_message("Item added: " + string(item));
        });
    });

    // Listen for players removed from the map
    colyseus_on_remove(callbacks, 0, "players", function(instance, key) {
        show_debug_message("Player left: " + key);
    });
});

colyseus_on_state_change(colyseus_room, function(_room) {
    var state = colyseus_room_get_state(_room);
    if (is_struct(state)) {
        show_debug_message("State changed");
        show_debug_message("Room session id: " + colyseus_room_get_session_id(_room));

        var host = colyseus_schema_get(state, "host");
        var my_player = colyseus_map_get(state, "players", colyseus_room_get_session_id(_room));
        var is_host = (host == my_player);
        show_debug_message("Is host: " + string(is_host));
    }
});

colyseus_on_error(colyseus_room, function(code, msg) {
    show_debug_message("Room error [" + string(code) + "]: " + msg);
});

colyseus_on_leave(colyseus_room, function(code, reason) {
    show_debug_message("Left room [" + string(code) + "]: " + reason);
});

// --- Message handler ---
colyseus_on_message(colyseus_room, function(_room, _type, _data) {
    if (_type == "weather") {
        show_debug_message("Weather update: " + json_stringify(_data));
    } else {
        show_debug_message("Message received: " + _type);
    }
});
