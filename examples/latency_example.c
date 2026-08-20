/* Smoke test / example for colyseus_get_latency + colyseus_select_by_latency.
 *
 * Usage: latency_example [ws://host:port]   (defaults to ws://127.0.0.1:2567)
 *
 * Exercises the issue #941 settle paths:
 *   1) healthy endpoint  -> resolves with a small latency
 *   2) blackholed host   -> fails at ~timeout_ms (not an OS-length hang)
 *   3) select over both  -> picks the healthy endpoint
 */
#include <colyseus/latency.h>
#include <stdio.h>
#include <unistd.h>

static volatile int g_done = 0;

static void on_single(const colyseus_latency_result_t* r, void* ud) {
    printf("  [%s] ok=%d latency=%.1fms code=%d err=%s\n",
           (const char*)ud, r->ok, r->latency_ms, r->error_code,
           r->error ? r->error : "(none)");
    fflush(stdout);
    g_done++;
}

static void on_select(const char* best_endpoint, double best_latency_ms, void* ud) {
    (void)ud;
    if (best_endpoint != NULL) {
        printf("  best -> %s (%.1fms)\n", best_endpoint, best_latency_ms);
    } else {
        printf("  best -> (all endpoints failed)\n");
    }
    fflush(stdout);
    g_done++;
}

static void wait_for(int n, int max_ms) {
    int waited = 0;
    while (g_done < n && waited < max_ms) { usleep(20000); waited += 20; }
}

int main(int argc, char** argv) {
    const char* host = (argc > 1) ? argv[1] : "ws://127.0.0.1:2567";
    const char* blackhole = "ws://10.255.255.1:9999";

    colyseus_latency_options_t opt = {0};
    opt.timeout_ms = 800;

    printf("1) healthy: %s\n", host);
    g_done = 0;
    colyseus_get_latency(host, NULL, on_single, (void*)"healthy");
    wait_for(1, 4000);

    printf("2) blackhole: %s (expect timeout ~800ms)\n", blackhole);
    g_done = 0;
    colyseus_get_latency(blackhole, &opt, on_single, (void*)"blackhole");
    wait_for(1, 4000);

    printf("3) select_by_latency [blackhole, healthy]\n");
    g_done = 0;
    const char* eps[2] = { blackhole, host };
    colyseus_select_by_latency(eps, 2, &opt, on_select, NULL);
    wait_for(1, 4000);

    printf("done.\n");
    return 0;
}
