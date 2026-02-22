#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#include "raylib.h"
#include <colyseus/client.h>
#include <colyseus/schema.h>
#include <colyseus/schema/callbacks.h>
#include <colyseus/schema/collections.h>
#include <colyseus/msgpack_builder.h>
#include "test_room_state.h"

#define MAX_PLAYERS 16
#define PLAYER_SIZE 40
#define MOVE_SPEED 5.0
#define SCREEN_WIDTH 800
#define SCREEN_HEIGHT 600

typedef struct {
    char session_id[64];
    player_t* player;
    Color color;
    bool active;
    colyseus_callback_handle_t change_handle;
} local_player_t;

static colyseus_client_t* client = NULL;
static colyseus_room_t* room = NULL;
static colyseus_callbacks_t* callbacks = NULL;
static local_player_t players[MAX_PLAYERS] = {0};
static int player_count = 0;
static char my_session_id[64] = {0};
static double my_x = SCREEN_WIDTH / 2.0;
static double my_y = SCREEN_HEIGHT / 2.0;
static bool connected = false;
static bool joined = false;
static char status_message[256] = "Connecting...";

static Color player_colors[] = {
    RED, BLUE, GREEN, YELLOW, PURPLE, ORANGE, PINK, SKYBLUE,
    LIME, GOLD, VIOLET, BEIGE, BROWN, DARKBLUE, DARKGREEN, MAROON
};

static int find_player_slot(const char* session_id) {
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (players[i].active && strcmp(players[i].session_id, session_id) == 0) {
            return i;
        }
    }
    return -1;
}

static int find_free_slot(void) {
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (!players[i].active) {
            return i;
        }
    }
    return -1;
}

static void on_player_add(void* value, void* key, void* userdata) {
    player_t* player = (player_t*)value;
    const char* session_id = (const char*)key;

    printf("[on_player_add] Player added: %s (x=%.1f, y=%.1f)\n", session_id, player->x, player->y);
    fflush(stdout);

    int slot = find_free_slot();
    if (slot < 0) {
        printf("[on_player_add] No free slot for player!\n");
        fflush(stdout);
        return;
    }

    strncpy(players[slot].session_id, session_id, sizeof(players[slot].session_id) - 1);
    players[slot].player = player;
    players[slot].color = player_colors[slot % 16];
    players[slot].active = true;
    player_count++;

    snprintf(status_message, sizeof(status_message), "Players: %d", player_count);
}

static void on_player_remove(void* value, void* key, void* userdata) {
    const char* session_id = (const char*)key;

    printf("[on_player_remove] Player removed: %s\n", session_id);
    fflush(stdout);

    int slot = find_player_slot(session_id);
    if (slot >= 0) {
        // Remove change callback
        if (callbacks && players[slot].change_handle != COLYSEUS_INVALID_CALLBACK_HANDLE) {
            colyseus_callbacks_remove(callbacks, players[slot].change_handle);
        }

        players[slot].active = false;
        players[slot].player = NULL;
        players[slot].session_id[0] = '\0';
        player_count--;
    }

    snprintf(status_message, sizeof(status_message), "Players: %d", player_count);
}

static void on_join(void* userdata) {
    printf("[on_join] Successfully joined room!\n");
    fflush(stdout);
    joined = true;

    const char* session_id = colyseus_room_get_session_id(room);
    if (session_id) {
        strncpy(my_session_id, session_id, sizeof(my_session_id) - 1);
        printf("[on_join] My session ID: %s\n", my_session_id);
        fflush(stdout);
    }

    snprintf(status_message, sizeof(status_message), "Joined! Session: %.8s...", my_session_id);
}

static void on_state_change(void* userdata) {
    // State updated
}

static void on_room_error(int code, const char* message, void* userdata) {
    printf("[on_room_error] Error (%d): %s\n", code, message);
    fflush(stdout);
    snprintf(status_message, sizeof(status_message), "Error: %s", message);
}

static void on_leave(int code, const char* reason, void* userdata) {
    printf("[on_leave] Left room (%d): %s\n", code, reason ? reason : "unknown");
    fflush(stdout);
    joined = false;
    connected = false;
    snprintf(status_message, sizeof(status_message), "Disconnected");
}

static void on_error(int code, const char* message, void* userdata) {
    printf("[on_error] Connection error (%d): %s\n", code, message);
    fflush(stdout);
    snprintf(status_message, sizeof(status_message), "Connection failed: %s", message);
}

static void on_room_success(colyseus_room_t* joined_room, void* userdata) {
    room = joined_room;
    connected = true;

    printf("[on_room_success] Room created: %s (session: %s)\n",
           colyseus_room_get_id(room),
           colyseus_room_get_session_id(room));
    fflush(stdout);

    // Set state type before setting up handlers
    colyseus_room_set_state_type(room, &test_room_state_vtable);

    // Set up room event handlers
    colyseus_room_on_join(room, on_join, NULL);
    colyseus_room_on_error(room, on_room_error, NULL);
    colyseus_room_on_leave(room, on_leave, NULL);
    colyseus_room_on_state_change(room, on_state_change, NULL);

    snprintf(status_message, sizeof(status_message), "Room joined, waiting for state...");
}

static void setup_state_callbacks(void) {
    printf("[setup_state_callbacks] Attempting to setup callbacks...\n");
    fflush(stdout);
    
    if (!room) {
        printf("[setup_state_callbacks] room is NULL\n");
        fflush(stdout);
        return;
    }
    if (!room->serializer) {
        printf("[setup_state_callbacks] room->serializer is NULL\n");
        fflush(stdout);
        return;
    }
    if (!room->serializer->decoder) {
        printf("[setup_state_callbacks] room->serializer->decoder is NULL\n");
        fflush(stdout);
        return;
    }

    test_room_state_t* state = (test_room_state_t*)colyseus_room_get_state(room);
    if (!state) {
        printf("[setup_state_callbacks] state is NULL\n");
        fflush(stdout);
        return;
    }
    
    printf("[setup_state_callbacks] State obtained: %p\n", (void*)state);
    printf("[setup_state_callbacks] state->players: %p\n", (void*)state->players);
    fflush(stdout);

    // Create callbacks manager
    callbacks = colyseus_callbacks_create(room->serializer->decoder);
    if (!callbacks) {
        printf("[setup_state_callbacks] Failed to create callbacks manager\n");
        fflush(stdout);
        return;
    }

    // Listen for player additions and removals
    colyseus_callback_handle_t add_handle = colyseus_callbacks_on_add(callbacks, state, "players", on_player_add, NULL, true);
    colyseus_callback_handle_t remove_handle = colyseus_callbacks_on_remove(callbacks, state, "players", on_player_remove, NULL);

    printf("[setup_state_callbacks] State callbacks registered (add=%d, remove=%d)\n", add_handle, remove_handle);
    fflush(stdout);
}

static void send_move_message(double x, double y) {
    if (!room || !joined) return;

    msgpack_payload_t* msg = msgpack_map_create();
    msgpack_map_put_float(msg, "x", x);
    msgpack_map_put_float(msg, "y", y);
    colyseus_room_send(room, "move", msg);
    msgpack_payload_free(msg);
}

static void handle_input(void) {
    if (!joined) return;

    bool moved = false;
    double new_x = my_x;
    double new_y = my_y;

    if (IsKeyDown(KEY_W) || IsKeyDown(KEY_UP)) {
        new_y -= MOVE_SPEED;
        moved = true;
    }
    if (IsKeyDown(KEY_S) || IsKeyDown(KEY_DOWN)) {
        new_y += MOVE_SPEED;
        moved = true;
    }
    if (IsKeyDown(KEY_A) || IsKeyDown(KEY_LEFT)) {
        new_x -= MOVE_SPEED;
        moved = true;
    }
    if (IsKeyDown(KEY_D) || IsKeyDown(KEY_RIGHT)) {
        new_x += MOVE_SPEED;
        moved = true;
    }

    // Clamp to screen bounds
    if (new_x < 0) new_x = 0;
    if (new_x > SCREEN_WIDTH - PLAYER_SIZE) new_x = SCREEN_WIDTH - PLAYER_SIZE;
    if (new_y < 0) new_y = 0;
    if (new_y > SCREEN_HEIGHT - PLAYER_SIZE) new_y = SCREEN_HEIGHT - PLAYER_SIZE;

    if (moved && (new_x != my_x || new_y != my_y)) {
        my_x = new_x;
        my_y = new_y;
        send_move_message(my_x, my_y);
    }
}

// Callback context for drawing from state directly
typedef struct {
    int index;
} draw_context_t;

static void draw_player_from_state(const char* key, void* value, void* userdata) {
    draw_context_t* ctx = (draw_context_t*)userdata;
    player_t* p = (player_t*)value;
    
    int x = (int)p->x;
    int y = (int)p->y;
    
    bool is_local = (strcmp(key, my_session_id) == 0);
    
    Color color = player_colors[ctx->index % 16];
    if (p->disconnected) {
        color = GRAY;
    }
    
    DrawRectangle(x, y, PLAYER_SIZE, PLAYER_SIZE, color);
    
    if (is_local) {
        DrawRectangleLines(x - 2, y - 2, PLAYER_SIZE + 4, PLAYER_SIZE + 4, WHITE);
    }
    
    if (p->isBot) {
        DrawText("BOT", x + 5, y + PLAYER_SIZE / 2 - 5, 10, BLACK);
    }
    
    char short_id[9];
    strncpy(short_id, key, 8);
    short_id[8] = '\0';
    DrawText(short_id, x, y + PLAYER_SIZE + 2, 10, LIGHTGRAY);
    
    ctx->index++;
}

static void draw_players(void) {
    // Draw directly from state (bypassing callbacks)
    if (room && room->serializer) {
        test_room_state_t* state = (test_room_state_t*)colyseus_room_get_state(room);
        if (state && state->players) {
            draw_context_t ctx = { .index = 0 };
            colyseus_map_schema_foreach(state->players, draw_player_from_state, &ctx);
            
            // Debug: show state player count
            char debug_msg[64];
            snprintf(debug_msg, sizeof(debug_msg), "State players: %d", state->players->count);
            DrawText(debug_msg, 10, 40, 16, YELLOW);
            return;
        }
    }
    
    // Fallback: draw from tracked players array (via callbacks)
    int drawn = 0;
    for (int i = 0; i < MAX_PLAYERS; i++) {
        if (!players[i].active || !players[i].player) continue;

        player_t* p = players[i].player;
        int x = (int)p->x;
        int y = (int)p->y;

        bool is_local = (strcmp(players[i].session_id, my_session_id) == 0);

        Color color = players[i].color;
        if (p->disconnected) {
            color = GRAY;
        }

        DrawRectangle(x, y, PLAYER_SIZE, PLAYER_SIZE, color);

        if (is_local) {
            DrawRectangleLines(x - 2, y - 2, PLAYER_SIZE + 4, PLAYER_SIZE + 4, WHITE);
        }

        if (p->isBot) {
            DrawText("BOT", x + 5, y + PLAYER_SIZE / 2 - 5, 10, BLACK);
        }

        char short_id[9];
        strncpy(short_id, players[i].session_id, 8);
        short_id[8] = '\0';
        DrawText(short_id, x, y + PLAYER_SIZE + 2, 10, LIGHTGRAY);
        drawn++;
    }
    
    char debug_msg[64];
    snprintf(debug_msg, sizeof(debug_msg), "Tracked players: %d (drawn: %d)", player_count, drawn);
    DrawText(debug_msg, 10, 40, 16, YELLOW);
}

int main(void) {
    printf("Colyseus Raylib Example\n");
    printf("=======================\n");
    fflush(stdout);

    // Initialize raylib
    InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Colyseus Raylib Example");
    SetTargetFPS(60);

    // Create colyseus client
    colyseus_settings_t* settings = colyseus_settings_create();
    if (!settings) {
        printf("Failed to create settings\n");
        return 1;
    }

    colyseus_settings_set_address(settings, "localhost");
    colyseus_settings_set_port(settings, "2567");

    printf("Connecting to %s:%s\n", settings->server_address, settings->server_port);
    fflush(stdout);

    client = colyseus_client_create(settings);
    if (!client) {
        printf("Failed to create client\n");
        colyseus_settings_free(settings);
        CloseWindow();
        return 1;
    }

    // Join or create room
    colyseus_client_join_or_create(
        client,
        "test_room",
        "{}",
        on_room_success,
        on_error,
        NULL
    );

    bool callbacks_setup = false;

    // Main game loop
    while (!WindowShouldClose()) {
        // Setup callbacks once we have state
        if (joined && !callbacks_setup && room && room->serializer) {
            setup_state_callbacks();
            callbacks_setup = true;
        }

        // Handle input
        handle_input();

        // Draw
        BeginDrawing();
        ClearBackground(DARKGRAY);

        // Draw status
        DrawText(status_message, 10, 10, 20, WHITE);

        // Draw instructions
        if (joined) {
            DrawText("Use WASD or Arrow keys to move", 10, SCREEN_HEIGHT - 30, 16, LIGHTGRAY);
        }

        // Draw players
        draw_players();

        // Draw connection indicator
        if (connected) {
            DrawCircle(SCREEN_WIDTH - 20, 20, 10, joined ? GREEN : YELLOW);
        } else {
            DrawCircle(SCREEN_WIDTH - 20, 20, 10, RED);
        }

        EndDrawing();
    }

    // Cleanup
    printf("\nCleaning up...\n");
    fflush(stdout);

    if (callbacks) {
        colyseus_callbacks_free(callbacks);
    }

    if (room) {
        colyseus_room_leave(room, true);
        colyseus_room_free(room);
    }

    if (client) {
        colyseus_client_free(client);
    }

    colyseus_settings_free(settings);
    CloseWindow();

    printf("Done\n");
    return 0;
}
