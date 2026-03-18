/*
 * fuzz_msgpack.c — libFuzzer harness for kgd C client process_message
 *
 * Feeds arbitrary bytes to process_message via a mock client to find
 * crashes, OOB reads, and infinite loops.
 *
 * Build: clang -fsanitize=fuzzer,address,undefined -DMPACK_NODE=0
 *        -DMPACK_EXTENSIONS=0 mpack.c fuzz_msgpack.c -lpthread
 */

#define _POSIX_C_SOURCE 200809L

/* Include the implementation to access process_message */
#include "kgd.c"

/* Callback stubs that track invocations but don't do anything dangerous */
static void fuzz_evicted_cb(uint32_t handle, void *ud) {
    (void)handle; (void)ud;
}

static void fuzz_topology_cb(int cols, int rows, int cw, int ch, void *ud) {
    (void)cols; (void)rows; (void)cw; (void)ch; (void)ud;
}

static void fuzz_visibility_cb(uint32_t pid, int visible, void *ud) {
    (void)pid; (void)visible; (void)ud;
}

static void fuzz_theme_cb(kgd_color fg, kgd_color bg, void *ud) {
    (void)fg; (void)bg; (void)ud;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* Create a minimal mock client */
    kgd_client mock;
    memset(&mock, 0, sizeof(mock));
    mock.fd = -1;
    pthread_mutex_init(&mock.write_lock, NULL);
    for (int i = 0; i < MAX_PENDING; i++) {
        pthread_mutex_init(&mock.pending[i].mtx, NULL);
        pthread_cond_init(&mock.pending[i].cond, NULL);
        /* Mark some slots active so response handling exercises the path */
        if (i < 8) mock.pending[i].active = 1;
    }

    /* Install all callbacks to exercise notification paths */
    mock.evicted_cb = fuzz_evicted_cb;
    mock.topology_cb = fuzz_topology_cb;
    mock.visibility_cb = fuzz_visibility_cb;
    mock.theme_cb = fuzz_theme_cb;

    /* Feed the fuzz input */
    process_message(&mock, data, size);

    /* Cleanup */
    for (int i = 0; i < MAX_PENDING; i++) {
        pthread_mutex_destroy(&mock.pending[i].mtx);
        pthread_cond_destroy(&mock.pending[i].cond);
        free(mock.pending[i].data);
    }
    pthread_mutex_destroy(&mock.write_lock);

    return 0;
}
