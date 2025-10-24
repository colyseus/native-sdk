#include <colyseus/client.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>

static int message_received = 0;
static int state_changed = 0;

void on_message_string(const uint8_t* data, size_t length, void* userdata) {
    printf("Message received (string type): %zu bytes\n", length);
    message_received++;
}

void on_state_change(void* userdata) {
    printf("State changed\n");
    state_changed++;
}

int main() {
    printf("=== Test: Room ===\n");
    
    /* Create a room */
    colyseus_room_t* room = colyseus_room_create("test_room", colyseus_websocket_transport_create);
    assert(room != NULL);
    printf("PASS: Room created\n");
    
    /* Test room properties */
    const char* room_name = colyseus_room_get_name(room);
    assert(room_name != NULL);
    assert(strcmp(room_name, "test_room") == 0);
    printf("PASS: Room name correct\n");
    
    /* Test setting room ID and session ID */
    colyseus_room_set_id(room, "test_room_id");
    colyseus_room_set_session_id(room, "test_session_id");
    
    const char* room_id = colyseus_room_get_id(room);
    const char* session_id = colyseus_room_get_session_id(room);
    
    assert(strcmp(room_id, "test_room_id") == 0);
    assert(strcmp(session_id, "test_session_id") == 0);
    printf("PASS: Room ID and session ID set correctly\n");
    
    /* Test message handler registration */
    printf("\nTest: Register message handlers\n");
    colyseus_room_on_message(room, "chat", on_message_string, NULL);
    colyseus_room_on_state_change(room, on_state_change, NULL);
    printf("PASS: Message handlers registered\n");
    
    /* Note: Actual message dispatch testing requires connection to server */
    printf("\nTest: Message dispatch (requires server connection)\n");
    printf("(Skipped - requires running server)\n");
    
    /* Cleanup */
    colyseus_room_free(room);
    
    printf("\nAll room tests passed!\n");
    return 0;
}