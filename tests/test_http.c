#include <colyseus/client.h>
#include <stdio.h>
#include <assert.h>
#include <unistd.h>

static int success_called = 0;
static int error_called = 0;

void on_http_success(const colyseus_http_response_t* response, void* userdata) {
    printf("HTTP Success: %d\n", response->status_code);
    printf("Body: %s\n", response->body);
    success_called = 1;
}

void on_http_error(const colyseus_http_error_t* error, void* userdata) {
    printf("HTTP Error: %d - %s\n", error->code, error->message);
    error_called = 1;
}

int main() {
    printf("=== Test: HTTP ===\n");
    
    colyseus_settings_t* settings = colyseus_settings_create();
    colyseus_settings_set_address(settings, "localhost");
    colyseus_settings_set_port(settings, "9999"); // Non-existent port
    
    colyseus_client_t* client = colyseus_client_create(settings);
    colyseus_http_t* http = colyseus_client_get_http(client);
    
    /* Test offline service */
    printf("\nTest: Request to offline service\n");
    colyseus_http_get(http, "/test", on_http_success, on_http_error, NULL);
    
    sleep(2); // Wait for async request
    
    assert(error_called == 1);
    printf("PASS: Error handler called for offline service\n");
    
    /* Test with valid server (requires running Colyseus server) */
    printf("\nTest: Request to valid server\n");
    printf("(Skipped - requires running server on port 2567)\n");
    
    /* Cleanup */
    colyseus_client_free(client);
    colyseus_settings_free(settings);
    
    printf("\nAll HTTP tests passed!\n");
    return 0;
}