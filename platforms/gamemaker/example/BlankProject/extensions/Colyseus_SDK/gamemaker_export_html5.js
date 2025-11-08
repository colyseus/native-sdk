/**
 * Colyseus GameMaker Extension - HTML5 Implementation
 * 
 * This file provides a JavaScript implementation of the Colyseus SDK for HTML5 builds.
 * It mirrors the C API from gamemaker_export.c using the colyseus.js client library.
 * 
 * Requirements:
 * - colyseus.js must be loaded before this script (via CDN or local file)
 * - Include in your HTML5 build: <script src="https://unpkg.com/colyseus.js@^0.15.0"></script>
 */

// Event types (must match C enum)
const GM_EVENT_NONE = 0;
const GM_EVENT_ROOM_JOIN = 1;
const GM_EVENT_ROOM_STATE_CHANGE = 2;
const GM_EVENT_ROOM_MESSAGE = 3;
const GM_EVENT_ROOM_ERROR = 4;
const GM_EVENT_ROOM_LEAVE = 5;
const GM_EVENT_CLIENT_ERROR = 6;

// Maximum number of events in the queue
const MAX_EVENT_QUEUE_SIZE = 1024;

// Global storage for clients and rooms
const g_clients = new Map();
const g_rooms = new Map();
let g_next_handle = 1;

// Event queue (circular buffer)
const g_event_queue = {
    events: [],
    head: 0,
    tail: 0,
    count: 0
};

// Current event (for event accessors)
let g_current_event = {
    type: GM_EVENT_NONE,
    room_handle: 0,
    code: 0,
    message: "",
    data: null,
    data_length: 0
};

// Helper function to generate unique handles
function generateHandle() {
    return g_next_handle++;
}

// Event queue functions
function eventQueuePush(event) {
    if (g_event_queue.count >= MAX_EVENT_QUEUE_SIZE) {
        // Queue is full, drop oldest event
        g_event_queue.head = (g_event_queue.head + 1) % MAX_EVENT_QUEUE_SIZE;
        g_event_queue.count--;
    }
    
    if (g_event_queue.events.length < MAX_EVENT_QUEUE_SIZE) {
        g_event_queue.events.push(event);
    } else {
        g_event_queue.events[g_event_queue.tail] = event;
    }
    
    g_event_queue.tail = (g_event_queue.tail + 1) % MAX_EVENT_QUEUE_SIZE;
    g_event_queue.count++;
}

function eventQueuePop() {
    if (g_event_queue.count === 0) {
        return null;
    }
    
    const event = g_event_queue.events[g_event_queue.head];
    g_event_queue.head = (g_event_queue.head + 1) % MAX_EVENT_QUEUE_SIZE;
    g_event_queue.count--;
    return event;
}

// =============================================================================
// GameMaker Exported Functions
// =============================================================================

/**
 * Create a Colyseus client
 * @param {string} endpoint - Server endpoint (e.g., "localhost:2567")
 * @param {number} use_secure - 1.0 for wss://, 0.0 for ws://
 * @returns {number} Client handle
 */
function colyseus_gm_client_create(endpoint, use_secure) {
    try {
        const protocol = use_secure > 0.5 ? "wss" : "ws";
        const url = `${protocol}://${endpoint}`;
        
        console.log(`[Colyseus HTML5] Creating client: ${url}`);
        
        // Create Colyseus client
        const client = new Colyseus.Client(url);
        
        // Generate and store handle
        const handle = generateHandle();
        g_clients.set(handle, client);
        
        return handle;
    } catch (error) {
        console.error("[Colyseus HTML5] Error creating client:", error);
        return 0;
    }
}

/**
 * Free a Colyseus client
 * @param {number} client_handle - Client handle
 */
function colyseus_gm_client_free(client_handle) {
    if (g_clients.has(client_handle)) {
        // Clean up any rooms associated with this client
        for (const [room_handle, room_info] of g_rooms.entries()) {
            if (room_info.client_handle === client_handle) {
                try {
                    room_info.room.leave();
                } catch (e) {
                    console.warn("[Colyseus HTML5] Error leaving room during cleanup:", e);
                }
                g_rooms.delete(room_handle);
            }
        }
        
        g_clients.delete(client_handle);
        console.log(`[Colyseus HTML5] Client freed: ${client_handle}`);
    }
}

/**
 * Setup room event handlers
 * @param {Colyseus.Room} room - Room instance
 * @param {number} room_handle - Room handle
 */
function setupRoomHandlers(room, room_handle) {
    // On join
    room.onJoin.once(() => {
        console.log(`[Colyseus HTML5] Room joined: ${room_handle}`);
        eventQueuePush({
            type: GM_EVENT_ROOM_JOIN,
            room_handle: room_handle,
            code: 0,
            message: "",
            data: null,
            data_length: 0
        });
    });
    
    // On state change
    room.onStateChange.once((state) => {
        console.log(`[Colyseus HTML5] Room state changed: ${room_handle}`);
        eventQueuePush({
            type: GM_EVENT_ROOM_STATE_CHANGE,
            room_handle: room_handle,
            code: 0,
            message: "",
            data: null,
            data_length: 0
        });
    });
    
    // On subsequent state changes
    room.onStateChange((state) => {
        eventQueuePush({
            type: GM_EVENT_ROOM_STATE_CHANGE,
            room_handle: room_handle,
            code: 0,
            message: "",
            data: null,
            data_length: 0
        });
    });
    
    // On message (catch-all)
    room.onMessage("*", (type, message) => {
        console.log(`[Colyseus HTML5] Room message received: ${type}`);
        
        // Convert message to bytes if it's a string or object
        let data = message;
        let data_length = 0;
        
        if (typeof message === 'string') {
            data = new TextEncoder().encode(message);
            data_length = data.length;
        } else if (typeof message === 'object') {
            const jsonStr = JSON.stringify(message);
            data = new TextEncoder().encode(jsonStr);
            data_length = data.length;
        } else if (message instanceof Uint8Array || message instanceof ArrayBuffer) {
            data = new Uint8Array(message);
            data_length = data.length;
        }
        
        eventQueuePush({
            type: GM_EVENT_ROOM_MESSAGE,
            room_handle: room_handle,
            code: 0,
            message: type || "",
            data: data,
            data_length: data_length
        });
    });
    
    // On error
    room.onError.once((code, message) => {
        console.error(`[Colyseus HTML5] Room error: ${code} - ${message}`);
        eventQueuePush({
            type: GM_EVENT_ROOM_ERROR,
            room_handle: room_handle,
            code: code || 0,
            message: message || "",
            data: null,
            data_length: 0
        });
    });
    
    // On leave
    room.onLeave.once((code) => {
        console.log(`[Colyseus HTML5] Room left: ${code}`);
        eventQueuePush({
            type: GM_EVENT_ROOM_LEAVE,
            room_handle: room_handle,
            code: code || 0,
            message: "",
            data: null,
            data_length: 0
        });
    });
}

/**
 * Join or create a room
 * @param {number} client_handle - Client handle
 * @param {string} room_name - Room name
 * @param {string} options_json - Options as JSON string
 * @returns {number} Room handle (0 if async, check events)
 */
function colyseus_gm_client_join_or_create(client_handle, room_name, options_json) {
    const client = g_clients.get(client_handle);
    if (!client) {
        console.error("[Colyseus HTML5] Invalid client handle:", client_handle);
        return 0;
    }
    
    try {
        const options = options_json && options_json.length > 0 ? JSON.parse(options_json) : {};
        console.log(`[Colyseus HTML5] Joining or creating room: ${room_name}`);
        
        const room_handle = generateHandle();
        
        client.joinOrCreate(room_name, options)
            .then((room) => {
                g_rooms.set(room_handle, {
                    room: room,
                    client_handle: client_handle
                });
                setupRoomHandlers(room, room_handle);
            })
            .catch((error) => {
                console.error("[Colyseus HTML5] Error joining/creating room:", error);
                eventQueuePush({
                    type: GM_EVENT_CLIENT_ERROR,
                    room_handle: 0,
                    code: error.code || -1,
                    message: error.message || String(error),
                    data: null,
                    data_length: 0
                });
            });
        
        return room_handle;
    } catch (error) {
        console.error("[Colyseus HTML5] Error in join_or_create:", error);
        eventQueuePush({
            type: GM_EVENT_CLIENT_ERROR,
            room_handle: 0,
            code: -1,
            message: String(error),
            data: null,
            data_length: 0
        });
        return 0;
    }
}

/**
 * Create a room
 * @param {number} client_handle - Client handle
 * @param {string} room_name - Room name
 * @param {string} options_json - Options as JSON string
 * @returns {number} Room handle (0 if async, check events)
 */
function colyseus_gm_client_create_room(client_handle, room_name, options_json) {
    const client = g_clients.get(client_handle);
    if (!client) {
        console.error("[Colyseus HTML5] Invalid client handle:", client_handle);
        return 0;
    }
    
    try {
        const options = options_json && options_json.length > 0 ? JSON.parse(options_json) : {};
        console.log(`[Colyseus HTML5] Creating room: ${room_name}`);
        
        const room_handle = generateHandle();
        
        client.create(room_name, options)
            .then((room) => {
                g_rooms.set(room_handle, {
                    room: room,
                    client_handle: client_handle
                });
                setupRoomHandlers(room, room_handle);
            })
            .catch((error) => {
                console.error("[Colyseus HTML5] Error creating room:", error);
                eventQueuePush({
                    type: GM_EVENT_CLIENT_ERROR,
                    room_handle: 0,
                    code: error.code || -1,
                    message: error.message || String(error),
                    data: null,
                    data_length: 0
                });
            });
        
        return room_handle;
    } catch (error) {
        console.error("[Colyseus HTML5] Error in create_room:", error);
        eventQueuePush({
            type: GM_EVENT_CLIENT_ERROR,
            room_handle: 0,
            code: -1,
            message: String(error),
            data: null,
            data_length: 0
        });
        return 0;
    }
}

/**
 * Join a room
 * @param {number} client_handle - Client handle
 * @param {string} room_name - Room name
 * @param {string} options_json - Options as JSON string
 * @returns {number} Room handle (0 if async, check events)
 */
function colyseus_gm_client_join(client_handle, room_name, options_json) {
    const client = g_clients.get(client_handle);
    if (!client) {
        console.error("[Colyseus HTML5] Invalid client handle:", client_handle);
        return 0;
    }
    
    try {
        const options = options_json && options_json.length > 0 ? JSON.parse(options_json) : {};
        console.log(`[Colyseus HTML5] Joining room: ${room_name}`);
        
        const room_handle = generateHandle();
        
        client.join(room_name, options)
            .then((room) => {
                g_rooms.set(room_handle, {
                    room: room,
                    client_handle: client_handle
                });
                setupRoomHandlers(room, room_handle);
            })
            .catch((error) => {
                console.error("[Colyseus HTML5] Error joining room:", error);
                eventQueuePush({
                    type: GM_EVENT_CLIENT_ERROR,
                    room_handle: 0,
                    code: error.code || -1,
                    message: error.message || String(error),
                    data: null,
                    data_length: 0
                });
            });
        
        return room_handle;
    } catch (error) {
        console.error("[Colyseus HTML5] Error in join:", error);
        eventQueuePush({
            type: GM_EVENT_CLIENT_ERROR,
            room_handle: 0,
            code: -1,
            message: String(error),
            data: null,
            data_length: 0
        });
        return 0;
    }
}

/**
 * Join a room by ID
 * @param {number} client_handle - Client handle
 * @param {string} room_id - Room ID
 * @param {string} options_json - Options as JSON string
 * @returns {number} Room handle (0 if async, check events)
 */
function colyseus_gm_client_join_by_id(client_handle, room_id, options_json) {
    const client = g_clients.get(client_handle);
    if (!client) {
        console.error("[Colyseus HTML5] Invalid client handle:", client_handle);
        return 0;
    }
    
    try {
        const options = options_json && options_json.length > 0 ? JSON.parse(options_json) : {};
        console.log(`[Colyseus HTML5] Joining room by ID: ${room_id}`);
        
        const room_handle = generateHandle();
        
        client.joinById(room_id, options)
            .then((room) => {
                g_rooms.set(room_handle, {
                    room: room,
                    client_handle: client_handle
                });
                setupRoomHandlers(room, room_handle);
            })
            .catch((error) => {
                console.error("[Colyseus HTML5] Error joining room by ID:", error);
                eventQueuePush({
                    type: GM_EVENT_CLIENT_ERROR,
                    room_handle: 0,
                    code: error.code || -1,
                    message: error.message || String(error),
                    data: null,
                    data_length: 0
                });
            });
        
        return room_handle;
    } catch (error) {
        console.error("[Colyseus HTML5] Error in join_by_id:", error);
        eventQueuePush({
            type: GM_EVENT_CLIENT_ERROR,
            room_handle: 0,
            code: -1,
            message: String(error),
            data: null,
            data_length: 0
        });
        return 0;
    }
}

/**
 * Reconnect to a room
 * @param {number} client_handle - Client handle
 * @param {string} reconnection_token - Reconnection token
 * @returns {number} Room handle (0 if async, check events)
 */
function colyseus_gm_client_reconnect(client_handle, reconnection_token) {
    const client = g_clients.get(client_handle);
    if (!client) {
        console.error("[Colyseus HTML5] Invalid client handle:", client_handle);
        return 0;
    }
    
    try {
        console.log(`[Colyseus HTML5] Reconnecting with token: ${reconnection_token}`);
        
        const room_handle = generateHandle();
        
        client.reconnect(reconnection_token)
            .then((room) => {
                g_rooms.set(room_handle, {
                    room: room,
                    client_handle: client_handle
                });
                setupRoomHandlers(room, room_handle);
            })
            .catch((error) => {
                console.error("[Colyseus HTML5] Error reconnecting:", error);
                eventQueuePush({
                    type: GM_EVENT_CLIENT_ERROR,
                    room_handle: 0,
                    code: error.code || -1,
                    message: error.message || String(error),
                    data: null,
                    data_length: 0
                });
            });
        
        return room_handle;
    } catch (error) {
        console.error("[Colyseus HTML5] Error in reconnect:", error);
        eventQueuePush({
            type: GM_EVENT_CLIENT_ERROR,
            room_handle: 0,
            code: -1,
            message: String(error),
            data: null,
            data_length: 0
        });
        return 0;
    }
}

/**
 * Leave a room
 * @param {number} room_handle - Room handle
 */
function colyseus_gm_room_leave(room_handle) {
    const room_info = g_rooms.get(room_handle);
    if (room_info && room_info.room) {
        try {
            room_info.room.leave();
            console.log(`[Colyseus HTML5] Room left: ${room_handle}`);
        } catch (error) {
            console.error("[Colyseus HTML5] Error leaving room:", error);
        }
    }
}

/**
 * Free a room (after leaving)
 * @param {number} room_handle - Room handle
 */
function colyseus_gm_room_free(room_handle) {
    if (g_rooms.has(room_handle)) {
        g_rooms.delete(room_handle);
        console.log(`[Colyseus HTML5] Room freed: ${room_handle}`);
    }
}

/**
 * Send a message to the room (string type)
 * @param {number} room_handle - Room handle
 * @param {string} type - Message type
 * @param {string} data - Message data as string
 */
function colyseus_gm_room_send(room_handle, type, data) {
    const room_info = g_rooms.get(room_handle);
    if (room_info && room_info.room) {
        try {
            // Try to parse as JSON first, otherwise send as string
            let message;
            try {
                message = JSON.parse(data);
            } catch {
                message = data;
            }
            room_info.room.send(type, message);
            console.log(`[Colyseus HTML5] Message sent: ${type}`);
        } catch (error) {
            console.error("[Colyseus HTML5] Error sending message:", error);
        }
    }
}

/**
 * Send a message to the room with raw bytes
 * @param {number} room_handle - Room handle
 * @param {string} type - Message type
 * @param {*} data - Message data as bytes
 * @param {number} length - Data length
 */
function colyseus_gm_room_send_bytes(room_handle, type, data, length) {
    const room_info = g_rooms.get(room_handle);
    if (room_info && room_info.room) {
        try {
            // Convert to Uint8Array if needed
            const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
            room_info.room.send(type, bytes);
            console.log(`[Colyseus HTML5] Bytes sent: ${type} (${length} bytes)`);
        } catch (error) {
            console.error("[Colyseus HTML5] Error sending bytes:", error);
        }
    }
}

/**
 * Send a message to the room (integer type)
 * @param {number} room_handle - Room handle
 * @param {number} type - Message type as integer
 * @param {string} data - Message data as string
 */
function colyseus_gm_room_send_int(room_handle, type, data) {
    const room_info = g_rooms.get(room_handle);
    if (room_info && room_info.room) {
        try {
            // Try to parse as JSON first, otherwise send as string
            let message;
            try {
                message = JSON.parse(data);
            } catch {
                message = data;
            }
            room_info.room.send(type, message);
            console.log(`[Colyseus HTML5] Message sent: ${type}`);
        } catch (error) {
            console.error("[Colyseus HTML5] Error sending message:", error);
        }
    }
}

/**
 * Get room ID
 * @param {number} room_handle - Room handle
 * @returns {string} Room ID
 */
function colyseus_gm_room_get_id(room_handle) {
    const room_info = g_rooms.get(room_handle);
    if (room_info && room_info.room) {
        return room_info.room.id || "";
    }
    return "";
}

/**
 * Get room session ID
 * @param {number} room_handle - Room handle
 * @returns {string} Session ID
 */
function colyseus_gm_room_get_session_id(room_handle) {
    const room_info = g_rooms.get(room_handle);
    if (room_info && room_info.room) {
        return room_info.room.sessionId || "";
    }
    return "";
}

/**
 * Get room name
 * @param {number} room_handle - Room handle
 * @returns {string} Room name
 */
function colyseus_gm_room_get_name(room_handle) {
    const room_info = g_rooms.get(room_handle);
    if (room_info && room_info.room) {
        return room_info.room.name || "";
    }
    return "";
}

/**
 * Check if room has joined
 * @param {number} room_handle - Room handle
 * @returns {number} 1.0 if joined, 0.0 otherwise
 */
function colyseus_gm_room_has_joined(room_handle) {
    const room_info = g_rooms.get(room_handle);
    if (room_info && room_info.room) {
        // Check if room has a session ID (means it's connected)
        return room_info.room.sessionId ? 1.0 : 0.0;
    }
    return 0.0;
}

// =============================================================================
// Event Polling Functions
// =============================================================================

/**
 * Poll for next event
 * @returns {number} Event type (0 if no events)
 */
function colyseus_gm_poll_event() {
    const event = eventQueuePop();
    if (event) {
        g_current_event = event;
        return event.type;
    }
    
    // Clear current event when no more events
    g_current_event = {
        type: GM_EVENT_NONE,
        room_handle: 0,
        code: 0,
        message: "",
        data: null,
        data_length: 0
    };
    return 0;
}

/**
 * Get room handle from last polled event
 * @returns {number} Room handle
 */
function colyseus_gm_event_get_room() {
    return g_current_event.room_handle;
}

/**
 * Get error/leave code from last polled event
 * @returns {number} Code
 */
function colyseus_gm_event_get_code() {
    return g_current_event.code;
}

/**
 * Get message/error/reason from last polled event
 * @returns {string} Message string
 */
function colyseus_gm_event_get_message() {
    return g_current_event.message || "";
}

/**
 * Get message data from last polled event
 * @returns {*} Data (Uint8Array or null)
 */
function colyseus_gm_event_get_data() {
    return g_current_event.data;
}

/**
 * Get message data length from last polled event
 * @returns {number} Data length
 */
function colyseus_gm_event_get_data_length() {
    return g_current_event.data_length || 0;
}

