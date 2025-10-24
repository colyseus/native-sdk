#include <colyseus/client.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <unistd.h>

#define TEST_SERVER "localhost"
#define TEST_PORT "2567"
#define TIMEOUT_SECONDS 10

static int test_passed = 0;
static int test_failed = 0;
static int joined = 0;
static int state_received = 0;
static int message_received = 0;

void on_join(void* userdata) {
    printf("SUCCESS: Room join callback triggered\n");
    joined = 1;
}

void on_state_change(void* userdata) {
    printf("SUCCESS: State change received\n");
    state_received = 1;
}

void on_message_any(const uint8_t* data, size_t length, void* userdata) {
    printf("SUCCESS: Message received (%zu bytes)\n", length);
    message_received = 1;
}

void on_room_error(int code, const char* message, void* userdata) {
    printf("FAIL: Room error (%d): %s\n", code, message);
    test_failed = 1;
}

void on_leave(int code, const char* reason, void* userdata) {
    printf("Room left: %s (code: %d)\n", reason ? reason : "unknown", code);
}

void on_error(int code, const char* message, void* userdata) {
    printf("FAIL: Connection error (%d): %s\n", code, message);
    test_failed = 1;
}

void on_room_success(colyseus_room_t* room, void* userdata) {
    printf("SUCCESS: Room created - ID: %s, Session: %s\n", 
           colyseus_room_get_id(room), 
           colyseus_room_get_session_id(room));
    
    colyseus_room_on_join(room, on_join, NULL);
    colyseus_room_on_state_change(room, on_state_change, NULL);
    colyseus_room_on_message_any(room, on_message_any, NULL);
    colyseus_room_on_error(room, on_room_error, NULL);
    colyseus_room_on_leave(room, on_leave, NULL);
    
    colyseus_room_t** room_ptr = (colyseus_room_t**)userdata;
    *room_ptr = room;
    
    test_passed = 1;
}

int main() {
    printf("=== Integration Test: Full Connection Flow ===\n");
    printf("Testing against server at %s:%s\n\n", TEST_SERVER, TEST_PORT);
    
    colyseus_settings_t* settings = colyseus_settings_create();
    colyseus_settings_set_address(settings, TEST_SERVER);
    colyseus_settings_set_port(settings, TEST_PORT);
    
    colyseus_client_t* client = colyseus_client_create(settings);
    if (!client) {
        printf("FAIL: Failed to create client\n");
        colyseus_settings_free(settings);
        return 1;
    }
    
    colyseus_room_t* room = NULL;
    
    printf("Step 1: Attempting to join or create room...\n");
    colyseus_client_join_or_create(
        client,
        "my_room",
        "{}",
        on_room_success,
        on_error,
        &room
    );
    
    /* Wait for connection */
    int elapsed = 0;
    printf("Step 2: Waiting for connection (timeout: %ds)\n", TIMEOUT_SECONDS);
    
    while (!test_failed && elapsed < TIMEOUT_SECONDS) {
        if (joined && state_received) {
            printf("Step 3: Connected and state received!\n");
            break;
        }
        sleep(1);
        elapsed++;
        
        if (elapsed % 2 == 0 && !test_failed) {
            printf("  ... still waiting (%ds elapsed)\n", elapsed);
        }
    }
    
    /* Test sending a message if connected */
    if (room && joined) {
        printf("Step 4: Testing message send...\n");
        const char* test_msg = "{\"test\":\"message\"}";
        colyseus_room_send(room, "test", (const uint8_t*)test_msg, strlen(test_msg));
        
        /* Wait a bit for possible response */
        sleep(2);
    }
    
    /* Results */
    printf("\n=== Test Results ===\n");
    printf("Room created: %s\n", test_passed ? "YES" : "NO");
    printf("Joined room: %s\n", joined ? "YES" : "NO");
    printf("State received: %s\n", state_received ? "YES" : "NO");
    printf("Message received: %s\n", message_received ? "YES" : "NO (optional)");
    printf("Errors: %s\n", test_failed ? "YES" : "NO");
    
    /* Cleanup */
    if (room) {
        printf("\nStep 5: Cleaning up and leaving room...\n");
        colyseus_room_leave(room, true);
        sleep(1);
        colyseus_room_free(room);
    }
    
    colyseus_client_free(client);
    colyseus_settings_free(settings);
    
    /* Final verdict */
    printf("\n=== Final Verdict ===\n");
    
    if (test_failed) {
        printf("FAILED: Connection errors occurred\n");
        return 1;
    }
    
    if (!test_passed) {
        printf("FAILED: Timeout - could not connect to server\n");
        printf("Make sure Colyseus server is running on %s:%s\n", TEST_SERVER, TEST_PORT);
        return 1;
    }
    
    if (!joined) {
        printf("FAILED: Did not receive join confirmation\n");
        return 1;
    }
    
    printf("PASSED: All integration tests passed!\n");
    return 0;
}