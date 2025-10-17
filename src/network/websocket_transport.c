#include "colyseus/websocket_transport.h"
#include "colyseus/utils/strUtil.h"
#include "colyseus/utils/sha1_c.h"
#include "sds.h"
#include <wslay/wslay.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

/* Platform-specific includes */
#ifdef _WIN32
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #include <windows.h>
    typedef HANDLE thread_t;
    typedef DWORD thread_return_t;
    #define THREAD_CALL WINAPI
#else
    #include <pthread.h>
    #include <sys/socket.h>
    #include <netdb.h>
    #include <unistd.h>
    #include <fcntl.h>
    #include <arpa/inet.h>
    typedef pthread_t thread_t;
    typedef void* thread_return_t;
    #define THREAD_CALL
#endif

#define WS_DEBUG 0

#if WS_DEBUG
#define WS_LOG(fmt, ...) fprintf(stderr, "[WS] " fmt "\n", ##__VA_ARGS__)
#else
#define WS_LOG(fmt, ...)
#endif

/* Forward declarations */
static void ws_connect_impl(colyseus_transport_t* transport, const char* url);
static void ws_send_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length);
static void ws_send_unreliable_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length);
static void ws_close_impl(colyseus_transport_t* transport, int code, const char* reason);
static bool ws_is_open_impl(const colyseus_transport_t* transport);
static void ws_destroy_impl(colyseus_transport_t* transport);

/* Internal functions */
static thread_return_t THREAD_CALL ws_tick_thread_func(void* arg);
static void ws_tick_once(colyseus_transport_t* transport);
static bool ws_connect_init(colyseus_ws_transport_data_t* data);
static bool ws_connect_tick(colyseus_ws_transport_data_t* data);
static bool ws_http_handshake_init(colyseus_ws_transport_data_t* data);
static bool ws_http_handshake_send(colyseus_ws_transport_data_t* data);
static bool ws_http_handshake_receive(colyseus_ws_transport_data_t* data);
static ssize_t ws_socket_recv(colyseus_ws_transport_data_t* data, uint8_t* buf, size_t len, int* would_block);
static ssize_t ws_socket_send(colyseus_ws_transport_data_t* data, const uint8_t* buf, size_t len, int* would_block);
static void ws_socket_close(colyseus_ws_transport_data_t* data);
static void ws_cleanup_wslay(colyseus_ws_transport_data_t* data);

/* wslay callbacks */
static void ws_on_msg_recv_callback(wslay_event_context_ptr ctx, const struct wslay_event_on_msg_recv_arg* arg, void* user_data);
static ssize_t ws_recv_callback(wslay_event_context_ptr ctx, uint8_t* data, size_t len, int flags, void* user_data);
static ssize_t ws_send_callback(wslay_event_context_ptr ctx, const uint8_t* data, size_t len, int flags, void* user_data);
static int ws_genmask_callback(wslay_event_context_ptr ctx, uint8_t* buf, size_t len, void* user_data);

/* Create WebSocket transport */
colyseus_transport_t* colyseus_websocket_transport_create(const colyseus_transport_events_t* events) {
    colyseus_transport_t* transport = malloc(sizeof(colyseus_transport_t));
    if (!transport) return NULL;

    /* Set vtable */
    transport->connect = ws_connect_impl;
    transport->send = ws_send_impl;
    transport->send_unreliable = ws_send_unreliable_impl;
    transport->close = ws_close_impl;
    transport->is_open = ws_is_open_impl;
    transport->destroy = ws_destroy_impl;

    /* Copy events */
    if (events) {
        transport->events = *events;
    } else {
        memset(&transport->events, 0, sizeof(colyseus_transport_events_t));
    }

    /* Allocate implementation data */
    colyseus_ws_transport_data_t* data = malloc(sizeof(colyseus_ws_transport_data_t));
    if (!data) {
        free(transport);
        return NULL;
    }

    memset(data, 0, sizeof(colyseus_ws_transport_data_t));
    data->state = COLYSEUS_WS_DISCONNECTED;
    data->running = false;
    data->socket_fd = -1;
    data->buffer_size = 8192;
    data->buffer = malloc(data->buffer_size);

    transport->impl_data = data;

    return transport;
}

/* Implementation functions */
static void ws_connect_impl(colyseus_transport_t* transport, const char* url) {
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;

    WS_LOG("Connect called: %s", url);

    if (data->state != COLYSEUS_WS_DISCONNECTED) {
        WS_LOG("Already connecting/connected, state=%d", data->state);
        return;
    }

    data->url = strdup(url);

    if (!ws_connect_init(data)) {
        WS_LOG("Connect init failed");
        if (transport->events.on_error) {
            transport->events.on_error("Failed to initialize connection", transport->events.userdata);
        }
        return;
    }

    WS_LOG("Socket initialized, starting state machine");
    data->state = COLYSEUS_WS_CONNECTING;
    data->running = true;

    /* Create tick thread */
#ifdef _WIN32
    data->tick_thread = CreateThread(NULL, 0, ws_tick_thread_func, transport, 0, NULL);
#else
    pthread_t* thread = malloc(sizeof(pthread_t));
    pthread_create(thread, NULL, ws_tick_thread_func, transport);
    data->tick_thread = thread;
#endif

    WS_LOG("Tick thread created");
}

static void ws_send_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length) {
    colyseus_ws_transport_data_t* impl = (colyseus_ws_transport_data_t*)transport->impl_data;

    if (impl->state != COLYSEUS_WS_CONNECTED) {
        return;
    }

    struct wslay_event_msg msg = {
        .opcode = WSLAY_BINARY_FRAME,
        .msg = data,
        .msg_length = length
    };

    wslay_event_queue_msg(impl->wslay_ctx, &msg);
}

static void ws_send_unreliable_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length) {
    fprintf(stderr, "WebSocket does not support unreliable messages\n");
    (void)transport;
    (void)data;
    (void)length;
}

static void ws_close_impl(colyseus_transport_t* transport, int code, const char* reason) {
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;

    if (data->state == COLYSEUS_WS_DISCONNECTED) {
        return;
    }

    data->running = false;

    if (data->wslay_ctx && data->state == COLYSEUS_WS_CONNECTED) {
        wslay_event_queue_close(data->wslay_ctx, code, (const uint8_t*)reason, reason ? strlen(reason) : 0);
        wslay_event_send(data->wslay_ctx);
    }

    ws_socket_close(data);
    ws_cleanup_wslay(data);

    /* Wait for thread */
#ifdef _WIN32
    if (data->tick_thread) {
        WaitForSingleObject(data->tick_thread, INFINITE);
        CloseHandle(data->tick_thread);
        data->tick_thread = NULL;
    }
#else
    if (data->tick_thread) {
        pthread_t* thread = (pthread_t*)data->tick_thread;
        pthread_join(*thread, NULL);
        free(thread);
        data->tick_thread = NULL;
    }
#endif

    data->state = COLYSEUS_WS_DISCONNECTED;

    if (transport->events.on_close) {
        transport->events.on_close(code, reason, transport->events.userdata);
    }
}

static bool ws_is_open_impl(const colyseus_transport_t* transport) {
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;
    return data->state == COLYSEUS_WS_CONNECTED;
}

static void ws_destroy_impl(colyseus_transport_t* transport) {
    if (!transport) return;

    ws_close_impl(transport, 1000, "Normal closure");

    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;
    if (data) {
        free(data->url);
        free(data->url_host);
        free(data->url_path);
        free(data->client_key);
        free(data->buffer);
        free(data);
    }

    free(transport);
}

/* Tick thread */
static thread_return_t THREAD_CALL ws_tick_thread_func(void* arg) {
    colyseus_transport_t* transport = (colyseus_transport_t*)arg;
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;

    while (data->running) {
        ws_tick_once(transport);

#ifdef _WIN32
        Sleep(10);  /* 10ms */
#else
        usleep(10000);  /* 10ms */
#endif
    }

#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}

static void ws_tick_once(colyseus_transport_t* transport) {
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;

    if (data->state == COLYSEUS_WS_CONNECTED) {
        int ret = wslay_event_recv(data->wslay_ctx);
        if (ret != 0) {
            WS_LOG("wslay_event_recv error: %d", ret);
            ws_close_impl(transport, 1006, "Receive error");
            return;
        }

        ret = wslay_event_send(data->wslay_ctx);
        if (ret != 0) {
            WS_LOG("wslay_event_send error: %d", ret);
            ws_close_impl(transport, 1006, "Send error");
            return;
        }

        return;
    }

    if (data->state == COLYSEUS_WS_REMOTE_DISCONNECT) {
        WS_LOG("Remote disconnect");
        uint16_t code = wslay_event_get_status_code_received(data->wslay_ctx);
        ws_close_impl(transport, code, "Remote disconnect");
        return;
    }

    /* State machine */
    if (data->state == COLYSEUS_WS_CONNECTING) {
        if (ws_connect_tick(data)) {
            WS_LOG("TCP connected");
            data->state = COLYSEUS_WS_HANDSHAKE_SENDING;
            ws_http_handshake_init(data);
        }
    }
    else if (data->state == COLYSEUS_WS_HANDSHAKE_SENDING) {
        if (ws_http_handshake_send(data)) {
            WS_LOG("Handshake sent");
            data->state = COLYSEUS_WS_HANDSHAKE_RECEIVING;
        }
    }
    else if (data->state == COLYSEUS_WS_HANDSHAKE_RECEIVING) {
        if (ws_http_handshake_receive(data)) {
            WS_LOG("Handshake received, WS connected");
            data->state = COLYSEUS_WS_CONNECTED;

            /* Initialize wslay */
            struct wslay_event_callbacks callbacks = {
                ws_recv_callback,
                ws_send_callback,
                ws_genmask_callback,
                NULL,
                NULL,
                NULL,
                ws_on_msg_recv_callback
            };

            wslay_event_context_client_init(&data->wslay_ctx, &callbacks, transport);

            WS_LOG("Calling on_open callback");

            if (transport->events.on_open) {
                transport->events.on_open(transport->events.userdata);
            }
        }
    }
}

/* Connection functions */
static bool ws_connect_init(colyseus_ws_transport_data_t* data) {
    colyseus_url_parts_t* parts = colyseus_parse_url(data->url);
    if (!parts) {
        return false;
    }

    data->url_host = strdup(parts->host);
    data->url_port = parts->port ? *parts->port : (strcmp(parts->scheme, "wss") == 0 ? 443 : 80);
    data->url_path = sdscatprintf(sdsempty(), "/%s", parts->path_and_args);

    colyseus_url_parts_free(parts);

    /* Create socket */
    data->socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (data->socket_fd < 0) {
        return false;
    }

    /* Set non-blocking */
#ifdef _WIN32
    u_long mode = 1;
    ioctlsocket(data->socket_fd, FIONBIO, &mode);
#else
    int flags = fcntl(data->socket_fd, F_GETFL, 0);
    fcntl(data->socket_fd, F_SETFL, flags | O_NONBLOCK);
#endif

    /* Resolve hostname */
    struct hostent* server = gethostbyname(data->url_host);
    if (!server) {
        ws_socket_close(data);
        return false;
    }

    /* Connect */
    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(data->url_port);
    memcpy(&server_addr.sin_addr.s_addr, server->h_addr, server->h_length);

    connect(data->socket_fd, (struct sockaddr*)&server_addr, sizeof(server_addr));

    return true;
}

static bool ws_connect_tick(colyseus_ws_transport_data_t* data) {
    fd_set write_fds;
    FD_ZERO(&write_fds);
    FD_SET(data->socket_fd, &write_fds);

    struct timeval tv = {0, 0};
    int ret = select(data->socket_fd + 1, NULL, &write_fds, NULL, &tv);

    if (ret > 0 && FD_ISSET(data->socket_fd, &write_fds)) {
        int error = 0;
        socklen_t len = sizeof(error);
        getsockopt(data->socket_fd, SOL_SOCKET, SO_ERROR, (char*)&error, &len);
        return error == 0;
    }

    return false;
}

static bool ws_http_handshake_init(colyseus_ws_transport_data_t* data) {
    /* Generate random key */
    uint8_t random_bytes[16];
    for (int i = 0; i < 16; i++) {
        random_bytes[i] = rand() % 256;
    }

    sds random_str = sdsnewlen(random_bytes, 16);
    data->client_key = colyseus_base64_encode(random_str);
    sdsfree(random_str);

    /* Build HTTP request */
    sds request = sdsempty();
    request = sdscatprintf(request, "GET %s HTTP/1.1\r\n", data->url_path);
    request = sdscatprintf(request, "Host: %s:%d\r\n", data->url_host, data->url_port);
    request = sdscat(request, "Upgrade: websocket\r\n");
    request = sdscat(request, "Connection: Upgrade\r\n");
    request = sdscat(request, "Sec-WebSocket-Version: 13\r\n");
    request = sdscatprintf(request, "Sec-WebSocket-Key: %s\r\n", data->client_key);
    request = sdscat(request, "\r\n");

    /* Copy to buffer */
    data->buffer_offset = 0;
    size_t req_len = sdslen(request);
    if (req_len > data->buffer_size) {
        data->buffer_size = req_len;
        data->buffer = realloc(data->buffer, data->buffer_size);
    }
    memcpy(data->buffer, request, req_len);
    data->buffer_offset = 0;

    /* Store length at end for sending */
    *(size_t*)(data->buffer + data->buffer_size - sizeof(size_t)) = req_len;

    sdsfree(request);
    return true;
}

/* Continue with handshake send/receive and wslay callbacks... */
/* (Due to length, showing key parts - full implementation follows same pattern as C++ version) */

static bool ws_http_handshake_send(colyseus_ws_transport_data_t* data) {
    size_t total_len = *(size_t*)(data->buffer + data->buffer_size - sizeof(size_t));

    while (data->buffer_offset < total_len) {
        int would_block = 0;
        ssize_t sent = ws_socket_send(data,
            (uint8_t*)(data->buffer + data->buffer_offset),
            total_len - data->buffer_offset,
            &would_block);

        if (sent < 0) return false;
        if (would_block) return false;

        data->buffer_offset += sent;
    }

    /* Reset for receiving */
    data->buffer_offset = 0;
    memset(data->buffer, 0, data->buffer_size);
    return true;
}

static bool ws_http_handshake_receive(colyseus_ws_transport_data_t* data) {
    int would_block = 0;
    char buf[1024];
    ssize_t received = ws_socket_recv(data, (uint8_t*)buf, sizeof(buf) - 1, &would_block);

    if (received > 0) {
        size_t space_left = data->buffer_size - data->buffer_offset;
        size_t to_copy = (size_t)received < space_left ? (size_t)received : space_left;
        memcpy(data->buffer + data->buffer_offset, buf, to_copy);
        data->buffer_offset += to_copy;
    }

    if (would_block) {
        return false;
    }

    // Look for end of HTTP headers
    char* header_end = strstr((char*)data->buffer, "\r\n\r\n");
    if (!header_end) {
        return false;
    }

    // Check for HTTP 101
    if (!strstr((char*)data->buffer, "HTTP/1.1 101")) {
        fprintf(stderr, "WebSocket handshake failed\n");
        return false;
    }

    // Calculate where headers end
    size_t headers_length = (header_end - (char*)data->buffer) + 4; // +4 for \r\n\r\n

    fprintf(stderr, "Headers length: %zu, total buffered: %zu\n", headers_length, data->buffer_offset);

    // Check if there's extra data after headers (WebSocket frames that came with handshake)
    if (data->buffer_offset > headers_length) {
        size_t extra_data_len = data->buffer_offset - headers_length;
        fprintf(stderr, "Found %zu bytes of data after handshake headers\n", extra_data_len);

        // Move the extra data to the beginning of the buffer
        // This data will be read by wslay on the next recv_callback
        memmove(data->buffer, data->buffer + headers_length, extra_data_len);
        data->buffer_offset = extra_data_len;
    } else {
        data->buffer_offset = 0;
    }

    return true;
}

/* wslay callbacks */
static void ws_on_msg_recv_callback(wslay_event_context_ptr ctx, const struct wslay_event_on_msg_recv_arg* arg, void* user_data) {
    colyseus_transport_t* transport = (colyseus_transport_t*)user_data;
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;

    WS_LOG("Message received: opcode=%d (%s), length=%zu",
           arg->opcode,
           arg->opcode == WSLAY_TEXT_FRAME ? "TEXT" :
           arg->opcode == WSLAY_BINARY_FRAME ? "BINARY" :
           arg->opcode == WSLAY_PING ? "PING" :
           arg->opcode == WSLAY_PONG ? "PONG" : "OTHER",
           arg->msg_length);

    if (wslay_is_ctrl_frame(arg->opcode)) {
        if (arg->opcode == WSLAY_CONNECTION_CLOSE) {
            WS_LOG("Close frame received");
            data->state = COLYSEUS_WS_REMOTE_DISCONNECT;
        }
        // wslay handles ping/pong automatically
    } else {
        // Data frame
        if (arg->msg_length > 0) {
            WS_LOG("Data frame - first 4 bytes: %02x %02x %02x %02x",
                   arg->msg[0],
                   arg->msg_length > 1 ? arg->msg[1] : 0,
                   arg->msg_length > 2 ? arg->msg[2] : 0,
                   arg->msg_length > 3 ? arg->msg[3] : 0);
        }
        if (transport->events.on_message) {
            transport->events.on_message(arg->msg, arg->msg_length, transport->events.userdata);
        }
    }
}

static ssize_t ws_recv_callback(wslay_event_context_ptr ctx, uint8_t* buf, size_t len, int flags, void* user_data) {
    colyseus_transport_t* transport = (colyseus_transport_t*)user_data;
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;

    // Check if we have buffered data from handshake first
    if (data->buffer_offset > 0) {
        size_t to_copy = data->buffer_offset < len ? data->buffer_offset : len;
        memcpy(buf, data->buffer, to_copy);

        // Shift remaining buffer data
        if (to_copy < data->buffer_offset) {
            memmove(data->buffer, data->buffer + to_copy, data->buffer_offset - to_copy);
        }
        data->buffer_offset -= to_copy;

        WS_LOG("wslay recv_callback: returned %zu bytes from buffer", to_copy);
        return (ssize_t)to_copy;
    }

    // No buffered data, read from socket
    int would_block = 0;
    ssize_t ret = ws_socket_recv(data, buf, len, &would_block);

    WS_LOG("wslay recv_callback: requested=%zu, received=%zd, would_block=%d", len, ret, would_block);

    if (would_block) {
        wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
        return -1;
    } else if (ret < 0) {
        wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
        return -1;
    }

    if (ret > 0) {
        WS_LOG("wslay received %zd bytes from socket", ret);
    }

    return ret;
}

static ssize_t ws_send_callback(wslay_event_context_ptr ctx, const uint8_t* buf, size_t len, int flags, void* user_data) {
    colyseus_transport_t* transport = (colyseus_transport_t*)user_data;
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;

    int would_block = 0;
    ssize_t ret = ws_socket_send(data, buf, len, &would_block);

    if (ret < 0) {
        wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
        return -1;
    } else if (would_block) {
        wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
        return 0;
    }

    return ret;
}

static int ws_genmask_callback(wslay_event_context_ptr ctx, uint8_t* buf, size_t len, void* user_data) {
    for (size_t i = 0; i < len; i++) {
        buf[i] = rand() % 256;
    }
    return 0;
}

/* Socket I/O */
static ssize_t ws_socket_recv(colyseus_ws_transport_data_t* data, uint8_t* buf, size_t len, int* would_block) {
    *would_block = 0;

    ssize_t ret = recv(data->socket_fd, (char*)buf, len, 0);

    if (ret < 0) {
#ifdef _WIN32
        if (WSAGetLastError() == WSAEWOULDBLOCK) {
#else
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
#endif
            *would_block = 1;
            return 0;
        }
        return -1;
    }

    return ret;
}

static ssize_t ws_socket_send(colyseus_ws_transport_data_t* data, const uint8_t* buf, size_t len, int* would_block) {
    *would_block = 0;

    ssize_t ret = send(data->socket_fd, (const char*)buf, len, 0);

    if (ret < 0) {
#ifdef _WIN32
        if (WSAGetLastError() == WSAEWOULDBLOCK) {
#else
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
#endif
            *would_block = 1;
            return 0;
        }
        return -1;
    }

    return ret;
}

static void ws_socket_close(colyseus_ws_transport_data_t* data) {
    if (data->socket_fd >= 0) {
#ifdef _WIN32
        closesocket(data->socket_fd);
#else
        close(data->socket_fd);
#endif
        data->socket_fd = -1;
    }
}

static void ws_cleanup_wslay(colyseus_ws_transport_data_t* data) {
    if (data->wslay_ctx) {
        wslay_event_context_free(data->wslay_ctx);
        data->wslay_ctx = NULL;
    }
}
