#include "colyseus/websocket_transport.h"
#include "colyseus/utils/strUtil.h"
#include "sds.h"
#include <wslay/wslay.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include "../../include/colyseus/tls_context.h"
#include "colyseus/settings.h"
#include "certs/system_certs.h"
#include "certs/ca_bundle.h"

/* Platform-specific includes */
#ifdef _WIN32
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #include <mstcpip.h>  /* For SIO_KEEPALIVE_VALS */
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
    #include <netinet/tcp.h>  /* For TCP keepalive options */
    typedef pthread_t thread_t;
    typedef void* thread_return_t;
    #define THREAD_CALL
#endif

/* Runtime-gated diagnostics: set COLYSEUS_WS_DEBUG=1 in the environment to enable.
 * This keeps pre-push hooks / non-CI runs quiet while still letting Windows CI
 * emit detailed frame-level tracing. */
static int ws_debug_enabled(void) {
    static int cached = -1;
    if (cached == -1) {
        const char* v = getenv("COLYSEUS_WS_DEBUG");
        cached = (v && v[0] && v[0] != '0') ? 1 : 0;
    }
    return cached;
}

#define WS_LOG(fmt, ...) do { \
    if (ws_debug_enabled()) { fprintf(stderr, "[WS] " fmt "\n", ##__VA_ARGS__); fflush(stderr); } \
} while (0)

static void ws_hex_dump(const char* tag, const uint8_t* buf, size_t len) {
    if (!ws_debug_enabled()) return;
    size_t max = len < 64 ? len : 64;
    fprintf(stderr, "[WS] %s len=%zu bytes:", tag, len);
    for (size_t i = 0; i < max; i++) {
        fprintf(stderr, " %02x", buf[i]);
    }
    if (len > max) fprintf(stderr, " ...");
    fprintf(stderr, "\n");
    fflush(stderr);
}

/* Forward declarations */
static void ws_connect_impl(colyseus_transport_t* transport, const char* url);
static void ws_send_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length);
static void ws_send_unreliable_impl(colyseus_transport_t* transport, const uint8_t* data, size_t length);
static void ws_close_impl(colyseus_transport_t* transport, int code, const char* reason);
static bool ws_is_open_impl(const colyseus_transport_t* transport);
static void ws_destroy_impl(colyseus_transport_t* transport);
static bool ws_tls_init(colyseus_ws_transport_data_t* data);
static void ws_tls_cleanup(colyseus_ws_transport_data_t* data);
static bool ws_tls_handshake_tick(colyseus_ws_transport_data_t* data);

/* Internal functions */
static thread_return_t THREAD_CALL ws_tick_thread_func(void* arg);
static void ws_tick_once(colyseus_transport_t* transport);
static bool ws_connect_init(colyseus_ws_transport_data_t* data);
static bool ws_connect_tick(colyseus_ws_transport_data_t* data);
static bool ws_http_handshake_init(colyseus_ws_transport_data_t* data);
static bool ws_http_handshake_send(colyseus_ws_transport_data_t* data);
static bool ws_http_handshake_receive(colyseus_ws_transport_data_t* data);
static ssize_t ws_socket_recv(colyseus_ws_transport_data_t* data, uint8_t* buf, size_t len, int* would_block, int* eof);
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
    data->in_tick_thread = false;
    data->pending_close = false;
    data->pending_close_code = 0;
    data->pending_close_reason = NULL;
    data->socket_fd = -1;
    data->buffer_size = 8192;
    data->buffer = malloc(data->buffer_size);
    data->use_tls = false;
    data->tls_skip_verify = false;
    data->tls_ctx = NULL;
    data->ca_pem_data = NULL;
    data->ca_pem_len = 0;

    transport->impl_data = data;

    return transport;
}

/* Implementation functions */
static void ws_connect_impl(colyseus_transport_t* transport, const char* url) {
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;
    // use_tls and tls_skip_verify are already set on data before this is called

    WS_LOG("Connect called: %s (TLS=%d, skip_verify=%d)", url, data->use_tls, data->tls_skip_verify);

    if (data->state != COLYSEUS_WS_DISCONNECTED) {
        WS_LOG("Already connecting/connected, state=%d", data->state);
        return;
    }

    data->url = strdup(url);

    if (!ws_connect_init(data)) {
        WS_LOG("Connect init failed");
        free(data->url);
        data->url = NULL;
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

    WS_LOG("ws_send_impl called: state=%d length=%zu", impl->state, length);
    ws_hex_dump("ws_send_impl_payload", data, length);

    if (impl->state != COLYSEUS_WS_CONNECTED) {
        WS_LOG("ws_send_impl: DROPPING - not connected (state=%d)", impl->state);
        return;
    }

    struct wslay_event_msg msg = {
        .opcode = WSLAY_BINARY_FRAME,
        .msg = data,
        .msg_length = length
    };

    int qret = wslay_event_queue_msg(impl->wslay_ctx, &msg);
    WS_LOG("wslay_event_queue_msg returned %d", qret);
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

    /* If we're being called from within the tick thread, defer the close.
     * We cannot pthread_join() on ourselves - that would deadlock. */
    if (data->in_tick_thread) {
        WS_LOG("Close called from tick thread - deferring");
        data->pending_close = true;
        data->pending_close_code = code;
        free(data->pending_close_reason);
        data->pending_close_reason = reason ? strdup(reason) : NULL;
        data->running = false;  /* Signal thread to exit */
        return;
    }

    data->running = false;

    if (data->wslay_ctx && data->state == COLYSEUS_WS_CONNECTED) {
        wslay_event_queue_close(data->wslay_ctx, code, (const uint8_t*)reason, reason ? strlen(reason) : 0);
        wslay_event_send(data->wslay_ctx);
    }

    ws_tls_cleanup(data);
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
        sdsfree(data->url_path);
        free(data->client_key);
        free(data->buffer);
        free(data->pending_close_reason);
        free(data);
    }

    free(transport);
}

/* Tick thread */
static thread_return_t THREAD_CALL ws_tick_thread_func(void* arg) {
    colyseus_transport_t* transport = (colyseus_transport_t*)arg;
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;

    data->in_tick_thread = true;

    while (data->running) {
        ws_tick_once(transport);

#ifdef _WIN32
        Sleep(10);  /* 10ms */
#else
        usleep(10000);  /* 10ms */
#endif
    }

    data->in_tick_thread = false;

    /* Handle deferred close (was requested from within tick thread) */
    if (data->pending_close) {
        WS_LOG("Handling deferred close: code=%d, reason=%s",
               data->pending_close_code,
               data->pending_close_reason ? data->pending_close_reason : "(null)");

        ws_tls_cleanup(data);
        ws_socket_close(data);
        ws_cleanup_wslay(data);

        data->state = COLYSEUS_WS_DISCONNECTED;

        if (transport->events.on_close) {
            transport->events.on_close(data->pending_close_code,
                                       data->pending_close_reason,
                                       transport->events.userdata);
        }

        free(data->pending_close_reason);
        data->pending_close_reason = NULL;
        data->pending_close = false;
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
            if (data->use_tls) {
                if (!ws_tls_init(data)) {
                    ws_close_impl(transport, 1006, "TLS init failed");
                    return;
                }
                data->state = COLYSEUS_WS_TLS_HANDSHAKE;
            } else {
                data->state = COLYSEUS_WS_HANDSHAKE_SENDING;
                ws_http_handshake_init(data);
            }
        }
    }
    else if (data->state == COLYSEUS_WS_TLS_HANDSHAKE) {
        if (ws_tls_handshake_tick(data)) {
            WS_LOG("TLS handshake complete");
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

    /* Auto-detect TLS from URL scheme (wss://) */
    if (strcmp(parts->scheme, "wss") == 0) {
        data->use_tls = true;
    }

    WS_LOG("Connecting to %s:%d (path=%s, TLS=%d)", data->url_host, data->url_port, data->url_path, data->use_tls);

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

    /* Enable TCP keepalive to detect dead connections faster */
#ifdef _WIN32
    /* Windows: use SIO_KEEPALIVE_VALS for fine-grained control */
    struct tcp_keepalive {
        u_long onoff;
        u_long keepalivetime;
        u_long keepaliveinterval;
    } keepalive_vals = {
        .onoff = 1,
        .keepalivetime = 10000,  /* 10 seconds before first probe */
        .keepaliveinterval = 5000  /* 5 seconds between probes */
    };
    DWORD bytes_returned;
    WSAIoctl(data->socket_fd, SIO_KEEPALIVE_VALS, &keepalive_vals, sizeof(keepalive_vals),
             NULL, 0, &bytes_returned, NULL, NULL);
#else
    int keepalive = 1;
    setsockopt(data->socket_fd, SOL_SOCKET, SO_KEEPALIVE, (const char*)&keepalive, sizeof(keepalive));

#ifdef __linux__
    /* Linux-specific: set keepalive parameters for faster detection */
    int keepidle = 10;   /* Start probing after 10 seconds of inactivity */
    int keepintvl = 5;   /* Probe interval: 5 seconds */
    int keepcnt = 3;     /* Give up after 3 failed probes */
    setsockopt(data->socket_fd, IPPROTO_TCP, TCP_KEEPIDLE, &keepidle, sizeof(keepidle));
    setsockopt(data->socket_fd, IPPROTO_TCP, TCP_KEEPINTVL, &keepintvl, sizeof(keepintvl));
    setsockopt(data->socket_fd, IPPROTO_TCP, TCP_KEEPCNT, &keepcnt, sizeof(keepcnt));
#elif defined(__APPLE__)
    /* macOS: set keepalive idle time */
    int keepidle = 10;
    setsockopt(data->socket_fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepidle, sizeof(keepidle));
#endif
#endif /* _WIN32 */

    /* Resolve hostname using getaddrinfo (modern, alignment-safe) */
    struct addrinfo hints, *result;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    
    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", data->url_port);
    
    if (getaddrinfo(data->url_host, port_str, &hints, &result) != 0) {
        ws_socket_close(data);
        return false;
    }

    /* Connect */
    connect(data->socket_fd, result->ai_addr, result->ai_addrlen);
    freeaddrinfo(result);

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

    /* Use binary version to avoid strlen() truncating at null bytes */
    data->client_key = colyseus_base64_encode_binary(random_bytes, 16);

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

    /* Store length for sending */
    data->handshake_len = req_len;

    sdsfree(request);
    return true;
}

/* Continue with handshake send/receive and wslay callbacks... */
/* (Due to length, showing key parts - full implementation follows same pattern as C++ version) */

static bool ws_http_handshake_send(colyseus_ws_transport_data_t* data) {
    size_t total_len = data->handshake_len;

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
    int eof = 0;
    char buf[1024];
    ssize_t received = ws_socket_recv(data, (uint8_t*)buf, sizeof(buf) - 1, &would_block, &eof);

    WS_LOG("handshake_receive: received=%zd would_block=%d eof=%d buffer_offset_before=%zu",
           received, would_block, eof, data->buffer_offset);

    if (received > 0) {
        size_t space_left = data->buffer_size - data->buffer_offset;
        size_t to_copy = (size_t)received < space_left ? (size_t)received : space_left;
        memcpy(data->buffer + data->buffer_offset, buf, to_copy);
        data->buffer_offset += to_copy;
        ws_hex_dump("handshake_recv_chunk", (uint8_t*)buf, (size_t)received);
    }

    if (would_block) {
        return false;
    }

    /* Connection closed during handshake */
    if (eof) {
        fprintf(stderr, "Connection closed during WebSocket handshake\n");
        return false;
    }

    /* Bounded search for end-of-headers (don't rely on null termination of buffer,
     * since the server may send WebSocket binary frames in the same TCP segment
     * right after the \r\n\r\n — those frames can contain 0x00 bytes that would
     * truncate a strstr-based scan). */
    size_t eoh = 0;
    bool found_eoh = false;
    if (data->buffer_offset >= 4) {
        for (size_t i = 0; i + 3 < data->buffer_offset; i++) {
            if (data->buffer[i] == '\r' && data->buffer[i+1] == '\n' &&
                data->buffer[i+2] == '\r' && data->buffer[i+3] == '\n') {
                eoh = i;
                found_eoh = true;
                break;
            }
        }
    }

    if (!found_eoh) {
        WS_LOG("handshake_receive: \\r\\n\\r\\n not found yet (have %zu bytes)", data->buffer_offset);
        return false;
    }

    // Check for HTTP 101 in the header region only (bounded)
    bool has_101 = false;
    if (eoh >= 12) {
        for (size_t i = 0; i + 12 <= eoh; i++) {
            if (memcmp(data->buffer + i, "HTTP/1.1 101", 12) == 0) {
                has_101 = true;
                break;
            }
        }
    }
    if (!has_101) {
        fprintf(stderr, "WebSocket handshake failed\n");
        ws_hex_dump("handshake_headers", (uint8_t*)data->buffer, eoh);
        return false;
    }

    size_t headers_length = eoh + 4; // +4 for \r\n\r\n

    WS_LOG("handshake_receive: headers_length=%zu total_buffered=%zu", headers_length, data->buffer_offset);

    // Check if there's extra data after headers (WebSocket frames that came with handshake)
    if (data->buffer_offset > headers_length) {
        size_t extra_data_len = data->buffer_offset - headers_length;
        WS_LOG("handshake_receive: %zu extra bytes after headers", extra_data_len);
        ws_hex_dump("handshake_extra", (uint8_t*)(data->buffer + headers_length), extra_data_len);

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
            WS_LOG("Close frame received (payload_len=%zu)", arg->msg_length);
            if (arg->msg_length >= 2 && ws_debug_enabled()) {
                uint16_t code = ((uint16_t)arg->msg[0] << 8) | arg->msg[1];
                size_t reason_len = arg->msg_length - 2;
                fprintf(stderr, "[WS] Close code=%u reason=\"%.*s\"\n",
                        (unsigned)code, (int)reason_len, (const char*)(arg->msg + 2));
                fflush(stderr);
            }
            ws_hex_dump("close_payload", arg->msg, arg->msg_length);
            data->state = COLYSEUS_WS_REMOTE_DISCONNECT;
        }
        // wslay handles ping/pong automatically
    } else {
        // Data frame
        if (arg->msg_length > 0) {
            ws_hex_dump("ws_data_frame", arg->msg, arg->msg_length);
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

        WS_LOG("wslay recv_callback: returning %zu buffered bytes (requested=%zu)", to_copy, len);
        ws_hex_dump("wslay_from_buffer", buf, to_copy);

        // Shift remaining buffer data
        if (to_copy < data->buffer_offset) {
            memmove(data->buffer, data->buffer + to_copy, data->buffer_offset - to_copy);
        }
        data->buffer_offset -= to_copy;

        return (ssize_t)to_copy;
    }

    // No buffered data, read from socket
    int would_block = 0;
    int eof = 0;
    ssize_t ret = ws_socket_recv(data, buf, len, &would_block, &eof);

    if (ret > 0 || eof) {
        WS_LOG("wslay recv_callback: requested=%zu, received=%zd, would_block=%d, eof=%d", len, ret, would_block, eof);
    }

    if (would_block) {
        wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
        return -1;
    } else if (ret < 0) {
        wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
        return -1;
    } else if (eof) {
        /* Connection was closed by remote (server killed, network issue, etc.) */
        WS_LOG("EOF detected - connection closed by remote");
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

    ws_hex_dump("wslay_send_to_socket", buf, len);

    int would_block = 0;
    ssize_t ret = ws_socket_send(data, buf, len, &would_block);

    WS_LOG("wslay send_callback: requested=%zu, sent=%zd, would_block=%d", len, ret, would_block);

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
static ssize_t ws_socket_recv(colyseus_ws_transport_data_t* data, uint8_t* buf, size_t len, int* would_block, int* eof) {
    *would_block = 0;
    *eof = 0;

    if (data->use_tls && data->tls_ctx) {
        colyseus_tls_context_t* tls = (colyseus_tls_context_t*)data->tls_ctx;
        int ret = mbedtls_ssl_read(&tls->ssl, buf, len);
        
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) {
            *would_block = 1;
            return 0;
        }
        if (ret < 0) {
            if (ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
                *eof = 1;
                return 0;
            }
            return -1;
        }
        if (ret == 0) {
            *eof = 1;
        }
        return ret;
    }

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

    /* recv() returning 0 means the connection was closed (EOF) */
    if (ret == 0) {
        *eof = 1;
    }

    return ret;
}

static ssize_t ws_socket_send(colyseus_ws_transport_data_t* data, const uint8_t* buf, size_t len, int* would_block) {
    *would_block = 0;

    if (data->use_tls && data->tls_ctx) {
        colyseus_tls_context_t* tls = (colyseus_tls_context_t*)data->tls_ctx;
        int ret = mbedtls_ssl_write(&tls->ssl, buf, len);
        
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) {
            *would_block = 1;
            return 0;
        }
        if (ret < 0) {
            return -1;
        }
        return ret;
    }

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

/* TLS functions */

static int tls_bio_send(void* ctx, const unsigned char* buf, size_t len) {
    int fd = *(int*)ctx;
    ssize_t ret = send(fd, (const char*)buf, len, 0);
    if (ret < 0) {
#ifdef _WIN32
        if (WSAGetLastError() == WSAEWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_WRITE;
#else
        if (errno == EAGAIN || errno == EWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_WRITE;
#endif
        return MBEDTLS_ERR_NET_SEND_FAILED;
    }
    return (int)ret;
}

static int tls_bio_recv(void* ctx, unsigned char* buf, size_t len) {
    int fd = *(int*)ctx;
    ssize_t ret = recv(fd, (char*)buf, len, 0);
    if (ret < 0) {
#ifdef _WIN32
        if (WSAGetLastError() == WSAEWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_READ;
#else
        if (errno == EAGAIN || errno == EWOULDBLOCK) return MBEDTLS_ERR_SSL_WANT_READ;
#endif
        return MBEDTLS_ERR_NET_RECV_FAILED;
    }
    if (ret == 0) return MBEDTLS_ERR_NET_CONN_RESET;
    return (int)ret;
}

static bool ws_tls_init(colyseus_ws_transport_data_t* data) {
    colyseus_tls_context_t* tls = malloc(sizeof(colyseus_tls_context_t));
    if (!tls) return false;
    
    mbedtls_ssl_init(&tls->ssl);
    mbedtls_ssl_config_init(&tls->conf);
    mbedtls_entropy_init(&tls->entropy);
    mbedtls_ctr_drbg_init(&tls->ctr_drbg);
    tls->ca_chain_initialized = 0;
    tls->handshake_done = 0;
    data->tls_ctx = tls;  /* assign early so ws_tls_cleanup can free it */
    
    if (mbedtls_ctr_drbg_seed(&tls->ctr_drbg, mbedtls_entropy_func, &tls->entropy, NULL, 0) != 0) {
        ws_tls_cleanup(data);
        return false;
    }
    
    if (mbedtls_ssl_config_defaults(&tls->conf, MBEDTLS_SSL_IS_CLIENT,
                                     MBEDTLS_SSL_TRANSPORT_STREAM,
                                     MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
        ws_tls_cleanup(data);
        return false;
    }
    
    if (data->tls_skip_verify) {
        mbedtls_ssl_conf_authmode(&tls->conf, MBEDTLS_SSL_VERIFY_NONE);
    } else {
        mbedtls_ssl_conf_authmode(&tls->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        
        /* Load CA certificates with fallback chain:
         * 1. System certificates (via Zig's rescan)
         * 2. Bundled Mozilla CA certificates
         * 3. Settings-provided certificates
         */
        const unsigned char* ca_pem = NULL;
        size_t ca_pem_len = 0;
        const char* ca_source = NULL;
        
        /* Try system certificates first */
        if (colyseus_system_certs_init()) {
            ca_pem = colyseus_system_certs_get_pem();
            ca_pem_len = colyseus_system_certs_get_pem_len();
            ca_source = "system";
        }
        
        /* Fall back to bundled certificates */
        if (!ca_pem || ca_pem_len == 0) {
            ca_pem = colyseus_ca_bundle_pem;
            ca_pem_len = colyseus_ca_bundle_pem_len;
            ca_source = "bundled Mozilla CA";
        }
        
        /* Fall back to settings-provided certificates */
        if ((!ca_pem || ca_pem_len == 0) && data->ca_pem_data && data->ca_pem_len > 0) {
            ca_pem = data->ca_pem_data;
            ca_pem_len = data->ca_pem_len;
            ca_source = "settings";
        }
        
        if (ca_pem && ca_pem_len > 0) {
            mbedtls_x509_crt_init(&tls->ca_chain);
            tls->ca_chain_initialized = 1;
            
            int ret = mbedtls_x509_crt_parse(&tls->ca_chain, ca_pem, ca_pem_len);
            if (ret < 0) {
                WS_LOG("Failed to parse CA certificates from %s: -0x%04x", ca_source, -ret);
                ws_tls_cleanup(data);
                return false;
            }
            
            WS_LOG("Loaded CA certificates from %s (%d certs)", ca_source, ret == 0 ? 1 : ret);
            mbedtls_ssl_conf_ca_chain(&tls->conf, &tls->ca_chain, NULL);
        } else {
            WS_LOG("No CA certificates available - verification will fail");
        }
    }
    
    mbedtls_ssl_conf_rng(&tls->conf, mbedtls_ctr_drbg_random, &tls->ctr_drbg);
    
    if (mbedtls_ssl_setup(&tls->ssl, &tls->conf) != 0) {
        ws_tls_cleanup(data);
        return false;
    }
    
    if (mbedtls_ssl_set_hostname(&tls->ssl, data->url_host) != 0) {
        ws_tls_cleanup(data);
        return false;
    }
    
    mbedtls_ssl_set_bio(&tls->ssl, &data->socket_fd, tls_bio_send, tls_bio_recv, NULL);

    return true;
}

static void ws_tls_cleanup(colyseus_ws_transport_data_t* data) {
    if (!data->tls_ctx) return;
    
    colyseus_tls_context_t* tls = (colyseus_tls_context_t*)data->tls_ctx;
    mbedtls_ssl_free(&tls->ssl);
    mbedtls_ssl_config_free(&tls->conf);
    mbedtls_ctr_drbg_free(&tls->ctr_drbg);
    mbedtls_entropy_free(&tls->entropy);
    if (tls->ca_chain_initialized) {
        mbedtls_x509_crt_free(&tls->ca_chain);
    }
    free(tls);
    data->tls_ctx = NULL;
}

static bool ws_tls_handshake_tick(colyseus_ws_transport_data_t* data) {
    if (!data->tls_ctx) return false;
    
    colyseus_tls_context_t* tls = (colyseus_tls_context_t*)data->tls_ctx;
    if (tls->handshake_done) return true;
    
    int ret = mbedtls_ssl_handshake(&tls->ssl);
    
    if (ret == 0) {
        tls->handshake_done = 1;
        return true;
    }
    
    if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
        return false;
    }
    
    return false;
}

/* Public API wrapper for connecting with settings */
void colyseus_websocket_connect_with_settings(colyseus_transport_t* transport,
                                               const char* url,
                                               const colyseus_settings_t* settings) {
    colyseus_ws_transport_data_t* data = (colyseus_ws_transport_data_t*)transport->impl_data;
    data->use_tls        = settings ? settings->use_secure_protocol  : false;
    data->tls_skip_verify = settings ? settings->tls_skip_verification : false;
    data->ca_pem_data    = settings ? settings->ca_pem_data : NULL;
    data->ca_pem_len     = settings ? settings->ca_pem_len : 0;
    transport->connect(transport, url);
}

void colyseus_http_poll(void) {
    /* Native HTTP is synchronous - no polling needed */
}

void colyseus_ws_poll(void) {
    /* Native WebSocket runs on its own thread - no polling needed */
}

