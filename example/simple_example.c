#include <colyseus/client.h>
#include <stdio.h>

void on_room_joined(colyseus_room_t* room, void* userdata) {
    printf("Joined room: %s\n", colyseus_room_get_id(room));
}

void on_error(int code, const char* message, void* userdata) {
    printf("Error (%d): %s\n", code, message);
}

int main() {
    /* Create settings */
    colyseus_settings_t* settings = colyseus_settings_create();
    colyseus_settings_set_address(settings, "localhost");
    colyseus_settings_set_port(settings, "2567");
    
    /* Create client */
    colyseus_client_t* client = colyseus_client_create(settings);
    
    /* Join or create room */
    colyseus_client_join_or_create(
        client,
        "my_room",
        "{}",
        on_room_joined,
        on_error,
        NULL
    );
    
    /* Keep alive (in real app, you'd have a game loop) */
    getchar();
    
    /* Cleanup */
    colyseus_client_free(client);
    colyseus_settings_free(settings);
    
    return 0;
}