#include <colyseus/client.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>

static volatile int keep_running = 1;

void sigint_handler(int dummy) {
    keep_running = 0;
}

void on_auth_success(const colyseus_auth_data_t* auth_data, void* userdata) {
    printf("✓ Authentication successful!\n");
    printf("Token: %s\n", auth_data->token ? auth_data->token : "null");
    printf("User data: %s\n", auth_data->user_json ? auth_data->user_json : "null");
    fflush(stdout);
    keep_running = 0;
}

void on_auth_error(const char* error, void* userdata) {
    printf("✗ Authentication failed: %s\n", error ? error : "unknown error");
    fflush(stdout);
    keep_running = 0;
}

void on_auth_change(const colyseus_auth_data_t* auth_data, void* userdata) {
    printf("→ Auth state changed!\n");
    printf("Token: %s\n", auth_data->token ? auth_data->token : "null");
    printf("User data: %s\n", auth_data->user_json ? auth_data->user_json : "null");
    fflush(stdout);
}

int main() {
    printf("Colyseus Native SDK Example\n");
    fflush(stdout);

    signal(SIGINT, sigint_handler);

    colyseus_settings_t* settings = colyseus_settings_create();
    if (!settings) {
        printf("Failed to create settings\n");
        return 1;
    }

    colyseus_settings_set_address(settings, "localhost");
    colyseus_settings_set_port(settings, "2567");

    printf("Connecting to %s:%s\n",
           settings->server_address,
           settings->server_port);
    fflush(stdout);

    colyseus_client_t* client = colyseus_client_create(settings);
    if (!client) {
        printf("Failed to create client\n");
        colyseus_settings_free(settings);
        return 1;
    }

    printf("Authenticating with email/password...\n");
    fflush(stdout);

    // Listen for auth state changes
    colyseus_auth_on_change(client->auth, on_auth_change, NULL);

    // Fail to sign in
    colyseus_auth_signin_email_password(
        client->auth,
        "test@example.com",
        "password123",
        on_auth_success,
        on_auth_error,
        NULL
    );

    // Success to register
    colyseus_auth_register_email_password(
        client->auth,
        "test2@example.com",
        "password123",
        "{}",
        on_auth_success,
        on_auth_error,
        NULL
    );

    // Wait for authentication to complete
    while (keep_running) {
        usleep(100000); // 100ms
    }

    colyseus_client_free(client);
    colyseus_settings_free(settings);

    printf("\nDone\n");
    
    return 0;
}