/*
 * HTTP and auth, moved off the isolate thread.
 *
 * colyseus_http_* and colyseus_auth_* are BLOCKING: each runs its request
 * inline and invokes the callback before returning. Calling one from Dart
 * would stall the frame loop for a whole round trip, so every request is
 * queued onto a worker thread here and the answer is handed back through a
 * NativeCallable.listener, which is safe to invoke from any thread.
 *
 * Strings crossing that boundary are heap COPIES. The core frees its response
 * as soon as the callback returns, while a listener runs later, on the
 * isolate's event loop — the same lifetime trap the latency selector hit.
 * Dart releases the copies with colyseus_flutter_free_string.
 *
 * The worker starts on the first request and lives for the process. It is
 * shared: several clients queue onto one thread, so requests are serialized.
 */

#include "colyseus/client.h"
#include "colyseus/http.h"
#include "colyseus/auth/auth.h"

#include "flutter_colyseus.h"

#include <stdlib.h>
#include <string.h>

#ifdef __EMSCRIPTEN__
    /* No threading — requests run inline, which is what the browser does. */
#elif defined(_WIN32)
    #include <windows.h>
    typedef DWORD fh_thread_return_t;
    #define FH_THREAD_CALL WINAPI
#else
    #include <pthread.h>
    typedef void* fh_thread_return_t;
    #define FH_THREAD_CALL
#endif

/* =============================================================================
 * Dart-facing callback shapes
 * ========================================================================== */

/*
 * One shape for both outcomes: `status`/`body` on success, `error_code`/
 * `error_message` on failure (status 0). Two separate callables would double
 * the registry bookkeeping on the Dart side for no gain.
 */
typedef void (*flutter_http_cb)(int64_t request_id, int status,
    char* body, int error_code, char* error_message);

/* `error` non-NULL means the request failed; user_json/token are then NULL. */
typedef void (*flutter_auth_cb)(int64_t request_id, char* user_json,
    char* token, char* error);

/* =============================================================================
 * Task queue
 * ========================================================================== */

typedef enum {
    FH_KIND_HTTP = 0,
    FH_KIND_AUTH = 1,
} fh_kind_t;

typedef struct fh_task {
    fh_kind_t kind;
    int op;                 /* flutter_http_method_t or flutter_auth_op_t */
    void* target;           /* colyseus_http_t* or colyseus_auth_t* */
    char* arg1;             /* path, or email */
    char* arg2;             /* json body, or password */
    char* arg3;             /* options json */
    int64_t request_id;
    void* callback;         /* flutter_http_cb or flutter_auth_cb */
    struct fh_task* next;
} fh_task_t;

typedef struct {
#ifdef _WIN32
    HANDLE thread;
    CRITICAL_SECTION mutex;
    CONDITION_VARIABLE cond;
#elif !defined(__EMSCRIPTEN__)
    pthread_t thread;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
#endif
    fh_task_t* head;
    fh_task_t* tail;
    int started;
} fh_worker_t;

static fh_worker_t g_worker;

static char* fh_dup(const char* s) {
    if (!s) return NULL;
    size_t len = strlen(s);
    char* copy = (char*)malloc(len + 1);
    if (copy) memcpy(copy, s, len + 1);
    return copy;
}

static void fh_task_free(fh_task_t* t) {
    free(t->arg1);
    free(t->arg2);
    free(t->arg3);
    free(t);
}

static void fh_run_task(fh_task_t* task);

#ifndef __EMSCRIPTEN__
static fh_thread_return_t FH_THREAD_CALL fh_worker_func(void* arg) {
    (void)arg;
    for (;;) {
        fh_task_t* task = NULL;
#ifdef _WIN32
        EnterCriticalSection(&g_worker.mutex);
        while (!g_worker.head) {
            SleepConditionVariableCS(&g_worker.cond, &g_worker.mutex, INFINITE);
        }
        task = g_worker.head;
        g_worker.head = task->next;
        if (!g_worker.head) g_worker.tail = NULL;
        LeaveCriticalSection(&g_worker.mutex);
#else
        pthread_mutex_lock(&g_worker.mutex);
        while (!g_worker.head) {
            pthread_cond_wait(&g_worker.cond, &g_worker.mutex);
        }
        task = g_worker.head;
        g_worker.head = task->next;
        if (!g_worker.head) g_worker.tail = NULL;
        pthread_mutex_unlock(&g_worker.mutex);
#endif
        fh_run_task(task);
        fh_task_free(task);
    }
#ifdef _WIN32
    return 0;
#else
    return NULL;
#endif
}
#endif /* !__EMSCRIPTEN__ */

static void fh_enqueue(fh_task_t* task) {
#ifdef __EMSCRIPTEN__
    /* Single-threaded: the request runs inline. */
    fh_run_task(task);
    fh_task_free(task);
#else
    if (!g_worker.started) {
#ifdef _WIN32
        InitializeCriticalSection(&g_worker.mutex);
        InitializeConditionVariable(&g_worker.cond);
        g_worker.started = 1;
        g_worker.thread = CreateThread(NULL, 0, fh_worker_func, NULL, 0, NULL);
#else
        pthread_mutex_init(&g_worker.mutex, NULL);
        pthread_cond_init(&g_worker.cond, NULL);
        g_worker.started = 1;
        pthread_create(&g_worker.thread, NULL, fh_worker_func, NULL);
        /* Nothing joins it: the worker outlives every client and the process
         * reclaims it at exit. */
        pthread_detach(g_worker.thread);
#endif
    }

#ifdef _WIN32
    EnterCriticalSection(&g_worker.mutex);
#else
    pthread_mutex_lock(&g_worker.mutex);
#endif
    task->next = NULL;
    if (g_worker.tail) g_worker.tail->next = task;
    else g_worker.head = task;
    g_worker.tail = task;
#ifdef _WIN32
    WakeConditionVariable(&g_worker.cond);
    LeaveCriticalSection(&g_worker.mutex);
#else
    pthread_cond_signal(&g_worker.cond);
    pthread_mutex_unlock(&g_worker.mutex);
#endif
#endif /* __EMSCRIPTEN__ */
}

/* =============================================================================
 * HTTP
 * ========================================================================== */

static void fh_http_success(const colyseus_http_response_t* response, void* userdata) {
    fh_task_t* task = (fh_task_t*)userdata;
    flutter_http_cb cb = (flutter_http_cb)task->callback;
    if (!cb) return;
    cb(task->request_id, response ? response->status_code : 0,
       fh_dup(response ? response->body : NULL), 0, NULL);
}

static void fh_http_error(const colyseus_http_error_t* error, void* userdata) {
    fh_task_t* task = (fh_task_t*)userdata;
    flutter_http_cb cb = (flutter_http_cb)task->callback;
    if (!cb) return;
    cb(task->request_id, 0, NULL, error ? error->code : -1,
       fh_dup(error ? error->message : NULL));
}

static void fh_auth_success(const colyseus_auth_data_t* data, void* userdata) {
    fh_task_t* task = (fh_task_t*)userdata;
    flutter_auth_cb cb = (flutter_auth_cb)task->callback;
    if (!cb) return;
    cb(task->request_id, fh_dup(data ? data->user_json : NULL),
       fh_dup(data ? data->token : NULL), NULL);
}

static void fh_auth_error(const char* error, void* userdata) {
    fh_task_t* task = (fh_task_t*)userdata;
    flutter_auth_cb cb = (flutter_auth_cb)task->callback;
    if (!cb) return;
    cb(task->request_id, NULL, NULL, fh_dup(error));
}

static void fh_run_task(fh_task_t* task) {
    if (task->kind == FH_KIND_HTTP) {
        colyseus_http_t* http = (colyseus_http_t*)task->target;
        switch ((flutter_http_method_t)task->op) {
            case FLUTTER_HTTP_GET:
                colyseus_http_get(http, task->arg1, fh_http_success, fh_http_error, task);
                break;
            case FLUTTER_HTTP_POST:
                colyseus_http_post(http, task->arg1, task->arg2, fh_http_success, fh_http_error, task);
                break;
            case FLUTTER_HTTP_PUT:
                colyseus_http_put(http, task->arg1, task->arg2, fh_http_success, fh_http_error, task);
                break;
            case FLUTTER_HTTP_DELETE:
                colyseus_http_delete(http, task->arg1, fh_http_success, fh_http_error, task);
                break;
            case FLUTTER_HTTP_PATCH:
                colyseus_http_patch(http, task->arg1, task->arg2, fh_http_success, fh_http_error, task);
                break;
        }
        return;
    }

    colyseus_auth_t* auth = (colyseus_auth_t*)task->target;
    switch ((flutter_auth_op_t)task->op) {
        case FLUTTER_AUTH_GET_USER_DATA:
            colyseus_auth_get_user_data(auth, fh_auth_success, fh_auth_error, task);
            break;
        case FLUTTER_AUTH_REGISTER:
            colyseus_auth_register_email_password(auth, task->arg1, task->arg2,
                task->arg3, fh_auth_success, fh_auth_error, task);
            break;
        case FLUTTER_AUTH_SIGNIN:
            colyseus_auth_signin_email_password(auth, task->arg1, task->arg2,
                fh_auth_success, fh_auth_error, task);
            break;
        case FLUTTER_AUTH_SIGNIN_ANONYMOUS:
            colyseus_auth_signin_anonymous(auth, task->arg3,
                fh_auth_success, fh_auth_error, task);
            break;
        case FLUTTER_AUTH_SEND_PASSWORD_RESET:
            colyseus_auth_send_password_reset(auth, task->arg1,
                fh_auth_success, fh_auth_error, task);
            break;
    }
}

FLUTTER_EXPORT void colyseus_flutter_http_request(intptr_t http, int method,
    const char* path, const char* json_body, int64_t request_id, void* callback)
{
    if (!http) return;
    fh_task_t* task = (fh_task_t*)calloc(1, sizeof(fh_task_t));
    if (!task) return;
    task->kind = FH_KIND_HTTP;
    task->op = method;
    task->target = (void*)http;
    task->arg1 = fh_dup(path);
    task->arg2 = fh_dup(json_body);
    task->request_id = request_id;
    task->callback = callback;
    fh_enqueue(task);
}

FLUTTER_EXPORT void colyseus_flutter_auth_request(intptr_t auth, int op,
    const char* arg1, const char* arg2, const char* options_json,
    int64_t request_id, void* callback)
{
    if (!auth) return;
    fh_task_t* task = (fh_task_t*)calloc(1, sizeof(fh_task_t));
    if (!task) return;
    task->kind = FH_KIND_AUTH;
    task->op = op;
    task->target = (void*)auth;
    task->arg1 = fh_dup(arg1);
    task->arg2 = fh_dup(arg2);
    task->arg3 = fh_dup(options_json);
    task->request_id = request_id;
    task->callback = callback;
    fh_enqueue(task);
}

/* =============================================================================
 * Auth token + change notification
 * ========================================================================== */

/*
 * The core hands out its token as a borrowed pointer that the next
 * set_token/signout frees. Copy it so a Dart string can be built from a
 * stable buffer.
 */
FLUTTER_EXPORT char* colyseus_flutter_auth_get_token(intptr_t auth) {
    if (!auth) return NULL;
    return fh_dup(colyseus_auth_get_token((colyseus_auth_t*)auth));
}

typedef void (*flutter_auth_change_cb)(char* user_json, char* token);

static void fh_auth_change(const colyseus_auth_data_t* data, void* userdata) {
    flutter_auth_change_cb cb = (flutter_auth_change_cb)userdata;
    if (!cb) return;
    cb(fh_dup(data ? data->user_json : NULL), fh_dup(data ? data->token : NULL));
}

FLUTTER_EXPORT void colyseus_flutter_auth_on_change(intptr_t auth, void* callback) {
    if (!auth) return;
    colyseus_auth_on_change((colyseus_auth_t*)auth, fh_auth_change, callback);
}
