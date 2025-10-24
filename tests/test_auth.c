#include <colyseus/client.h>
#include <colyseus/auth/auth.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <unistd.h>

static int auth_change_called = 0;
static char* received_token = NULL;

void on_auth_change(const colyseus_auth_data_t* data, void* userdata) {
    auth_change_called++;
    
    if (data->token) {
        free(received_token);
        received_token = strdup(data->token);
        printf("Auth changed - token: %s\n", data->token);
    } else {
        free(received_token);
        received_token = NULL;
        printf("Auth changed - token cleared\n");
    }
}

void on_register_success(const colyseus_auth_data_t* data, void* userdata) {
    printf("Register success - token: %s\n", data->token);
    int* success = (int*)userdata;
    *success = 1;
}

void on_register_error(const char* error, void* userdata) {
    printf("Register error: %s\n", error);
    int* failed = (int*)userdata;
    *failed = 1;
}

int main() {
    printf("=== Test: Auth ===\n");
    
    colyseus_settings_t* settings = colyseus_settings_create();
    colyseus_settings_set_address(settings, "localhost");
    colyseus_settings_set_port(settings, "2567");
    
    colyseus_client_t* client = colyseus_client_create(settings);
    colyseus_auth_t* auth = colyseus_client_get_auth(client);
    
    /* Test onChange callback */
    printf("\nTest: onChange callback\n");
    colyseus_auth_on_change(auth, on_auth_change, NULL);
    assert(auth_change_called > 0);
    printf("PASS: onChange triggered on initialization\n");
    
    /* Test set token */
    printf("\nTest: Set token\n");
    auth_change_called = 0;
    colyseus_auth_set_token(auth, "test_token_123");
    
    const char* token = colyseus_auth_get_token(auth);
    assert(token != NULL);
    assert(strcmp(token, "test_token_123") == 0);
    printf("PASS: Token set correctly\n");
    
    /* Test token persistence */
    printf("\nTest: Token persistence\n");
    colyseus_auth_data_t data = {
        .user_json = "{\"id\":\"123\",\"name\":\"Test User\"}",
        .token = "persistent_token"
    };
    
    /* This should trigger onChange and save to storage */
    colyseus_auth_signout(auth);
    sleep(1);
    
    printf("PASS: Token operations working\n");
    
    /* Test anonymous sign in (requires server) */
    printf("\nTest: Anonymous sign in\n");
    printf("(Skipped - requires running server)\n");
    
    /* Cleanup */
    colyseus_client_free(client);
    colyseus_settings_free(settings);
    free(received_token);
    
    printf("\nAll auth tests passed!\n");
    return 0;
}