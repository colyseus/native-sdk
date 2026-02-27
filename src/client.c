#include "colyseus/client.h"
#include "sds.h"
#include "cJSON.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Platform-specific threading */
#ifdef __EMSCRIPTEN__
    /* No threading on Emscripten – tasks are processed inline */
#elif defined(_WIN32)
    #include <windows.h>
    typedef DWORD thread_return_t;
    #define THREAD_CALL WINAPI
#else
    #include <pthread.h>
    typedef void* thread_return_t;
    #define THREAD_CALL
#endif

/* ── HTTP worker (threaded on native, inline on Emscripten) ────── */

/* Task node in the queue */
typedef struct http_task {
    colyseus_http_t* http;
    char* path;
    char* body;
    void (*on_success)(const colyseus_http_response_t*, void*);
    void (*on_error)(const colyseus_http_error_t*, void*);
    void* userdata;
    struct http_task* next;
} http_task_t;

#ifdef __EMSCRIPTEN__
/*
 * Emscripten: no worker thread needed. emscripten_fetch() is async –
 * calling colyseus_http_post() fires the request and returns immediately.
 * The browser event loop delivers the response callback later.
 */
typedef struct {
    bool running;
} http_worker_t;

static http_worker_t* http_worker_create(void) {
    http_worker_t* w = malloc(sizeof(http_worker_t));
    if (!w) return NULL;
    w->running = true;
    return w;
}

static void http_worker_enqueue(http_worker_t* w, http_task_t* task) {
    (void)w;
    colyseus_http_post(task->http, task->path, task->body,
                       task->on_success, task->on_error, task->userdata);
    free(task->path);
    free(task->body);
    free(task);
}

static void http_worker_free(http_worker_t* w) {
    free(w);
}

#else /* Native platforms – threaded worker */

/* Worker state – one per client */
typedef struct {
#ifdef _WIN32
    HANDLE thread;
    CRITICAL_SECTION mutex;
    CONDITION_VARIABLE cond;
#else
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
#endif
    http_task_t* head;  /* queue head */
    http_task_t* tail;  /* queue tail */
    bool running;
    bool started;
} http_worker_t;

static thread_return_t THREAD_CALL http_worker_func(void* arg);

static http_worker_t* http_worker_create(void) {
    http_worker_t* w = malloc(sizeof(http_worker_t));
    if (!w) return NULL;
    memset(w, 0, sizeof(http_worker_t));

#ifdef _WIN32
    InitializeCriticalSection(&w->mutex);
    InitializeConditionVariable(&w->cond);
#else
    pthread_mutex_init(&w->mutex, NULL);
    pthread_cond_init(&w->cond, NULL);
#endif

    w->head = NULL;
    w->tail = NULL;
    w->running = true;
    w->started = false;
    return w;
}

static void http_worker_ensure_started(http_worker_t* w) {
    if (w->started) return;
    w->started = true;

#ifdef _WIN32
    w->thread = CreateThread(NULL, 0, http_worker_func, w, 0, NULL);
#else
    pthread_create(&w->thread, NULL, http_worker_func, w);
#endif
}

static void http_worker_enqueue(http_worker_t* w, http_task_t* task) {
    task->next = NULL;

#ifdef _WIN32
    EnterCriticalSection(&w->mutex);
#else
    pthread_mutex_lock(&w->mutex);
#endif

    if (w->tail) {
        w->tail->next = task;
    } else {
        w->head = task;
    }
    w->tail = task;

    http_worker_ensure_started(w);

#ifdef _WIN32
    WakeConditionVariable(&w->cond);
    LeaveCriticalSection(&w->mutex);
#else
    pthread_cond_signal(&w->cond);
    pthread_mutex_unlock(&w->mutex);
#endif
}

static void http_worker_free(http_worker_t* w) {
    if (!w) return;

    /* Signal shutdown */
#ifdef _WIN32
    EnterCriticalSection(&w->mutex);
    w->running = false;
    WakeConditionVariable(&w->cond);
    LeaveCriticalSection(&w->mutex);
#else
    pthread_mutex_lock(&w->mutex);
    w->running = false;
    pthread_cond_signal(&w->cond);
    pthread_mutex_unlock(&w->mutex);
#endif

    /* Wait for thread to finish */
    if (w->started) {
#ifdef _WIN32
        WaitForSingleObject(w->thread, INFINITE);
        CloseHandle(w->thread);
#else
        pthread_join(w->thread, NULL);
#endif
    }

    /* Drain remaining tasks */
    http_task_t* t = w->head;
    while (t) {
        http_task_t* next = t->next;
        free(t->path);
        free(t->body);
        free(t);
        t = next;
    }

#ifdef _WIN32
    DeleteCriticalSection(&w->mutex);
#else
    pthread_mutex_destroy(&w->mutex);
    pthread_cond_destroy(&w->cond);
#endif

    free(w);
}

static thread_return_t THREAD_CALL http_worker_func(void* arg) {
    http_worker_t* w = (http_worker_t*)arg;

    while (1) {
        http_task_t* task = NULL;

#ifdef _WIN32
        EnterCriticalSection(&w->mutex);
        while (!w->head && w->running) {
            SleepConditionVariableCS(&w->cond, &w->mutex, INFINITE);
        }
        if (!w->running && !w->head) {
            LeaveCriticalSection(&w->mutex);
            break;
        }
        task = w->head;
        w->head = task->next;
        if (!w->head) w->tail = NULL;
        LeaveCriticalSection(&w->mutex);
#else
        pthread_mutex_lock(&w->mutex);
        while (!w->head && w->running) {
            pthread_cond_wait(&w->cond, &w->mutex);
        }
        if (!w->running && !w->head) {
            pthread_mutex_unlock(&w->mutex);
            break;
        }
        task = w->head;
        w->head = task->next;
        if (!w->head) w->tail = NULL;
        pthread_mutex_unlock(&w->mutex);
#endif

        /* Execute the HTTP request (blocking, but on this worker thread) */
        colyseus_http_post(
            task->http,
            task->path,
            task->body,
            task->on_success,
            task->on_error,
            task->userdata
        );

        free(task->path);
        free(task->body);
        free(task);
    }

#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

#endif /* __EMSCRIPTEN__ */

/* ── Matchmaking ──────────────────────────────────────────────── */

/* Internal context for async operations */
typedef struct {
    colyseus_client_t* client;
    colyseus_client_room_callback_t on_success;
    colyseus_client_error_callback_t on_error;
    void* userdata;
} colyseus_matchmake_context_t;

/* Internal functions */
static void client_create_matchmake_request(
    colyseus_client_t* client,
    const char* method,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

static void client_on_matchmake_success(const colyseus_http_response_t* response, void* userdata);
static void client_on_matchmake_error(const colyseus_http_error_t* error, void* userdata);

static void client_consume_seat_reservation(
    colyseus_client_t* client,
    const colyseus_seat_reservation_t* reservation,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
);

static char* client_build_room_endpoint(
    colyseus_client_t* client,
    const colyseus_room_available_t* room_data,
    const char* session_id,
    const char* reconnection_token
);

/* Create client */
colyseus_client_t* colyseus_client_create(colyseus_settings_t* settings) {
    return colyseus_client_create_with_transport(settings, colyseus_websocket_transport_create);
}

colyseus_client_t* colyseus_client_create_with_transport(
    colyseus_settings_t* settings,
    colyseus_transport_factory_fn transport_factory
) {
    colyseus_client_t* client = malloc(sizeof(colyseus_client_t));
    if (!client) return NULL;

    client->settings = settings;
    client->transport_factory = transport_factory;
    client->http = colyseus_http_create(settings);
    client->auth = colyseus_auth_create(client->http);
    client->http_worker = http_worker_create();

    return client;
}

void colyseus_client_free(colyseus_client_t* client) {
    if (!client) return;

    http_worker_free((http_worker_t*)client->http_worker);
    colyseus_http_free(client->http);
    colyseus_auth_free(client->auth);
    free(client);
}

colyseus_http_t* colyseus_client_get_http(colyseus_client_t* client) {
    return client ? client->http : NULL;
}

colyseus_auth_t* colyseus_client_get_auth(colyseus_client_t* client) {
    return client ? client->auth : NULL;
}

/* Matchmaking methods */
void colyseus_client_join_or_create(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    client_create_matchmake_request(client, "joinOrCreate", room_name, options_json, on_success, on_error, userdata);
}

void colyseus_client_create_room(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    client_create_matchmake_request(client, "create", room_name, options_json, on_success, on_error, userdata);
}

void colyseus_client_join(
    colyseus_client_t* client,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    client_create_matchmake_request(client, "join", room_name, options_json, on_success, on_error, userdata);
}

void colyseus_client_join_by_id(
    colyseus_client_t* client,
    const char* room_id,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    client_create_matchmake_request(client, "joinById", room_id, options_json, on_success, on_error, userdata);
}

void colyseus_client_reconnect(
    colyseus_client_t* client,
    const char* reconnection_token,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    /* Parse reconnection token: "roomId:token" */
    char* token_copy = strdup(reconnection_token);
    char* colon = strchr(token_copy, ':');

    if (!colon) {
        if (on_error) {
            on_error(-1, "Invalid reconnection token format", userdata);
        }
        free(token_copy);
        return;
    }

    *colon = '\0';
    const char* room_id = token_copy;
    const char* token = colon + 1;

    /* Build options JSON with reconnection token */
    cJSON* json = cJSON_CreateObject();
    cJSON_AddStringToObject(json, "reconnectionToken", token);
    char* options_json = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);

    client_create_matchmake_request(client, "reconnect", room_id, options_json, on_success, on_error, userdata);

    free(options_json);
    free(token_copy);
}

/* Internal matchmaking implementation */
static void client_create_matchmake_request(
    colyseus_client_t* client,
    const char* method,
    const char* room_name,
    const char* options_json,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    /* Build path */
    sds path = sdsempty();
    path = sdscatprintf(path, "matchmake/%s/%s", method, room_name);

    /* Create context for callbacks */
    colyseus_matchmake_context_t* ctx = malloc(sizeof(colyseus_matchmake_context_t));
    ctx->client = client;
    ctx->on_success = on_success;
    ctx->on_error = on_error;
    ctx->userdata = userdata;

    /* Enqueue on the worker thread */
    http_task_t* task = malloc(sizeof(http_task_t));
    task->http = client->http;
    task->path = strdup(path);
    task->body = strdup(options_json ? options_json : "{}");
    task->on_success = client_on_matchmake_success;
    task->on_error = client_on_matchmake_error;
    task->userdata = ctx;
    task->next = NULL;

    http_worker_enqueue((http_worker_t*)client->http_worker, task);

    sdsfree(path);
}

static void client_on_matchmake_success(const colyseus_http_response_t* response, void* userdata) {
    colyseus_matchmake_context_t* ctx = (colyseus_matchmake_context_t*)userdata;

    /* Parse JSON response */
    cJSON* json = cJSON_Parse(response->body);
    if (!json) {
        if (ctx->on_error) {
            ctx->on_error(-1, "Failed to parse matchmaking response", ctx->userdata);
        }
        free(ctx);
        return;
    }

    /* Parse seat reservation */
    colyseus_seat_reservation_t reservation = {0};

    cJSON* session_id = cJSON_GetObjectItem(json, "sessionId");
    if (session_id && cJSON_IsString(session_id)) {
        reservation.session_id = strdup(session_id->valuestring);
    }

    cJSON* reconnection_token = cJSON_GetObjectItem(json, "reconnectionToken");
    if (reconnection_token && cJSON_IsString(reconnection_token)) {
        reservation.reconnection_token = strdup(reconnection_token->valuestring);
    }

    cJSON* dev_mode = cJSON_GetObjectItem(json, "devMode");
    if (dev_mode && cJSON_IsBool(dev_mode)) {
        reservation.dev_mode = cJSON_IsTrue(dev_mode);
    }

    cJSON* protocol = cJSON_GetObjectItem(json, "protocol");
    if (protocol && cJSON_IsString(protocol)) {
        reservation.protocol = strdup(protocol->valuestring);
    }

    /* Parse room data */
    cJSON* room_id = cJSON_GetObjectItem(json, "roomId");
    if (room_id && cJSON_IsString(room_id)) {
        reservation.room.room_id = strdup(room_id->valuestring);
    }

    cJSON* name = cJSON_GetObjectItem(json, "name");
    if (name && cJSON_IsString(name)) {
        reservation.room.name = strdup(name->valuestring);
    }

    cJSON* process_id = cJSON_GetObjectItem(json, "processId");
    if (process_id && cJSON_IsString(process_id)) {
        reservation.room.process_id = strdup(process_id->valuestring);
    }

    cJSON* public_address = cJSON_GetObjectItem(json, "publicAddress");
    if (public_address && cJSON_IsString(public_address)) {
        reservation.room.public_address = strdup(public_address->valuestring);
    }

    cJSON_Delete(json);

    /* Consume seat reservation */
    client_consume_seat_reservation(ctx->client, &reservation, ctx->on_success, ctx->on_error, ctx->userdata);

    /* Cleanup */
    colyseus_seat_reservation_free(&reservation);
    free(ctx);
}

static void client_on_matchmake_error(const colyseus_http_error_t* error, void* userdata) {
    colyseus_matchmake_context_t* ctx = (colyseus_matchmake_context_t*)userdata;

    if (ctx->on_error) {
        ctx->on_error(error->code, error->message, ctx->userdata);
    }

    free(ctx);
}

static void client_consume_seat_reservation(
    colyseus_client_t* client,
    const colyseus_seat_reservation_t* reservation,
    colyseus_client_room_callback_t on_success,
    colyseus_client_error_callback_t on_error,
    void* userdata
) {
    /* Create room */
    colyseus_room_t* room = colyseus_room_create(reservation->room.name, client->transport_factory);
    if (!room) {
        if (on_error) {
            on_error(-1, "Failed to create room", userdata);
        }
        return;
    }

    colyseus_room_set_id(room, reservation->room.room_id);
    colyseus_room_set_session_id(room, reservation->session_id);

    /* Build WebSocket endpoint */
    char* endpoint = client_build_room_endpoint(
        client,
        &reservation->room,
        reservation->session_id,
        reservation->reconnection_token
    );

    /* Connect room (pass settings for TLS configuration) */
    colyseus_room_connect(
        room,
        endpoint,
        client->settings,
        NULL,  /* on_success handled via room.on_join */
        on_error,
        userdata
    );

    /* Return room to user */
    if (on_success) {
        on_success(room, userdata);
    }

    free(endpoint);
}

static char* client_build_room_endpoint(
    colyseus_client_t* client,
    const colyseus_room_available_t* room_data,
    const char* session_id,
    const char* reconnection_token
) {
    char* base = colyseus_settings_get_websocket_endpoint(client->settings);

    sds endpoint = sdsempty();
    endpoint = sdscatprintf(endpoint, "%s/%s/%s", base, room_data->process_id, room_data->room_id);

    /* Add query parameters */
    endpoint = sdscatprintf(endpoint, "?sessionId=%s", session_id);

    if (reconnection_token && strlen(reconnection_token) > 0) {
        endpoint = sdscatprintf(endpoint, "&reconnectionToken=%s", reconnection_token);
    }

    char* result = strdup(endpoint);
    sdsfree(endpoint);
    free(base);

    return result;
}

/* Helper to free seat reservation */
void colyseus_seat_reservation_free(colyseus_seat_reservation_t* reservation) {
    if (!reservation) return;

    free(reservation->session_id);
    free(reservation->reconnection_token);
    free(reservation->protocol);
    colyseus_room_available_free(&reservation->room);
}

void colyseus_room_available_free(colyseus_room_available_t* room) {
    if (!room) return;

    free(room->room_id);
    free(room->name);
    free(room->process_id);
    free(room->public_address);
}
