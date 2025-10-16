#include <colyseus/client.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>

static volatile int keep_running = 1;

void sigint_handler(int dummy) {
    keep_running = 0;
}

void on_join(void* userdata) {
    printf("✅ Successfully joined room!\n");
    fflush(stdout);
}

void on_room_error(int code, const char* message, void* userdata) {
    printf("❌ Room error (%d): %s\n", code, message);
    fflush(stdout);
}

void on_leave(int code, const char* reason, void* userdata) {
    printf("👋 Left room: %s\n", reason);
    fflush(stdout);
}

void on_error(int code, const char* message, void* userdata) {
    printf("❌ Error (%d): %s\n", code, message);
    fflush(stdout);
    keep_running = 0;
}

void on_room_success(colyseus_room_t* room, void* userdata) {
    printf("🎮 Room created: %s (session: %s)\n",
           colyseus_room_get_id(room),
           colyseus_room_get_session_id(room));
    fflush(stdout);

    // Set room event handlers
    colyseus_room_on_join(room, on_join, NULL);
    colyseus_room_on_error(room, on_room_error, NULL);
    colyseus_room_on_leave(room, on_leave, NULL);

    // Store room pointer
    colyseus_room_t** room_ptr = (colyseus_room_t**)userdata;
    *room_ptr = room;
}

int main() {
    printf("🚀 Colyseus Native SDK Example\n");
    fflush(stdout);

    signal(SIGINT, sigint_handler);

    /* Create settings */
    printf("Creating settings...\n");
    fflush(stdout);

    colyseus_settings_t* settings = colyseus_settings_create();
    if (!settings) {
        printf("Failed to create settings\n");
        return 1;
    }

    colyseus_settings_set_address(settings, "localhost");
    colyseus_settings_set_port(settings, "2567");

    printf("📡 Connecting to %s:%s\n",
           settings->server_address,
           settings->server_port);
    fflush(stdout);

    /* Create client */
    printf("Creating client...\n");
    fflush(stdout);

    colyseus_client_t* client = colyseus_client_create(settings);
    if (!client) {
        printf("Failed to create client\n");
        colyseus_settings_free(settings);
        return 1;
    }

    /* Store room reference */
    colyseus_room_t* room = NULL;

    /* Join or create room */
    printf("Joining room...\n");
    fflush(stdout);

    colyseus_client_join_or_create(
        client,
        "my_room",
        "{}",
        on_room_success,
        on_error,
        &room
    );

    printf("⏳ Waiting for connection... (Ctrl+C to exit)\n\n");
    fflush(stdout);

    /* Keep alive loop */
    while (keep_running) {
        sleep(1);
    }

    /* Cleanup */
    printf("\n🧹 Cleaning up...\n");
    fflush(stdout);

    if (room) {
        printf("Leaving room...\n");
        fflush(stdout);
        colyseus_room_leave(room, true);
        sleep(1); // Give time for leave message
        colyseus_room_free(room);
    }

    printf("Freeing client...\n");
    fflush(stdout);
    colyseus_client_free(client);

    printf("Freeing settings...\n");
    fflush(stdout);
    colyseus_settings_free(settings);

    printf("✨ Done!\n");
    
    return 0;
}