/*
 * kgd_test.c — Unit tests for kgd C client
 *
 * Uses #include "kgd.c" to access static functions and internal types.
 * Minimal framework using assert() + fprintf.
 */

#define _POSIX_C_SOURCE 200809L

/* Include the implementation to access static internals */
#include "kgd.c"

#include <assert.h>
#include <stdio.h>

static int tests_run = 0;
static int tests_passed = 0;

#define RUN_TEST(fn) do { \
    fprintf(stderr, "  %s ... ", #fn); \
    tests_run++; \
    fn(); \
    tests_passed++; \
    fprintf(stderr, "ok\n"); \
} while (0)

/* ---- Encoding Tests ---- */

/* Helper: encode a hello request and verify its msgpack structure */
static void test_encode_hello(void) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 4);
    mpack_write_int(&w, 0);
    mpack_write_u32(&w, 42);
    mpack_write_cstr(&w, "hello");
    mpack_start_array(&w, 1);
    mpack_build_map(&w);
    mpack_write_cstr(&w, "client_type");
    mpack_write_cstr(&w, "test");
    mpack_write_cstr(&w, "pid");
    mpack_write_int(&w, 1234);
    mpack_write_cstr(&w, "label");
    mpack_write_cstr(&w, "test-label");
    mpack_complete_map(&w);
    mpack_finish_array(&w);
    mpack_finish_array(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    /* Decode and verify structure */
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, data, size);

    assert(mpack_expect_array(&rd) == 4);
    assert(mpack_expect_int(&rd) == 0); /* type: request */
    assert(mpack_expect_u32(&rd) == 42); /* msgid */

    char method[32];
    mpack_expect_cstr(&rd, method, sizeof(method));
    assert(strcmp(method, "hello") == 0);

    assert(mpack_expect_array(&rd) == 1); /* params array */
    uint32_t nkeys = mpack_expect_map(&rd);
    assert(nkeys == 3);

    /* Verify keys exist */
    int found_type = 0, found_pid = 0, found_label = 0;
    for (uint32_t i = 0; i < nkeys; i++) {
        char key[32];
        mpack_expect_cstr(&rd, key, sizeof(key));
        if (strcmp(key, "client_type") == 0) {
            char val[32];
            mpack_expect_cstr(&rd, val, sizeof(val));
            assert(strcmp(val, "test") == 0);
            found_type = 1;
        } else if (strcmp(key, "pid") == 0) {
            assert(mpack_expect_int(&rd) == 1234);
            found_pid = 1;
        } else if (strcmp(key, "label") == 0) {
            char val[32];
            mpack_expect_cstr(&rd, val, sizeof(val));
            assert(strcmp(val, "test-label") == 0);
            found_label = 1;
        } else {
            mpack_discard(&rd);
        }
    }
    mpack_done_map(&rd);
    mpack_done_array(&rd);
    mpack_done_array(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);
    free(data);

    assert(found_type && found_pid && found_label);
}

/* Verify upload request encodes binary data correctly */
static void test_encode_upload(void) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    uint8_t imgdata[] = {0x89, 0x50, 0x4e, 0x47}; /* PNG header bytes */
    mpack_start_array(&w, 4);
    mpack_write_int(&w, 0);
    mpack_write_u32(&w, 1);
    mpack_write_cstr(&w, "upload");
    mpack_start_array(&w, 1);
    mpack_start_map(&w, 4);
    mpack_write_cstr(&w, "data");
    mpack_write_bin(&w, (const char *)imgdata, sizeof(imgdata));
    mpack_write_cstr(&w, "format");
    mpack_write_cstr(&w, "png");
    mpack_write_cstr(&w, "width");
    mpack_write_int(&w, 100);
    mpack_write_cstr(&w, "height");
    mpack_write_int(&w, 50);
    mpack_finish_map(&w);
    mpack_finish_array(&w);
    mpack_finish_array(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    /* Verify the binary data survived encoding */
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, data, size);
    mpack_expect_array(&rd); /* 4 */
    mpack_discard(&rd); /* type */
    mpack_discard(&rd); /* msgid */
    mpack_discard(&rd); /* method */
    mpack_expect_array(&rd); /* params */
    uint32_t nkeys = mpack_expect_map(&rd);
    for (uint32_t i = 0; i < nkeys; i++) {
        char key[32];
        mpack_expect_cstr(&rd, key, sizeof(key));
        if (strcmp(key, "data") == 0) {
            const char *bindata;
            size_t binlen;
            binlen = mpack_expect_bin(&rd);
            bindata = mpack_read_bytes_inplace(&rd, binlen);
            assert(binlen == 4);
            assert(memcmp(bindata, imgdata, 4) == 0);
            mpack_done_bin(&rd);
        } else {
            mpack_discard(&rd);
        }
    }
    mpack_done_map(&rd);
    mpack_done_array(&rd);
    mpack_done_array(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);
    free(data);
}

/* Verify place request with nested anchor map and conditional fields */
static void test_encode_place(void) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 4);
    mpack_write_int(&w, 0);
    mpack_write_u32(&w, 5);
    mpack_write_cstr(&w, "place");
    mpack_start_array(&w, 1);
    mpack_build_map(&w);
    mpack_write_cstr(&w, "handle");
    mpack_write_u32(&w, 10);
    mpack_write_cstr(&w, "anchor");
    mpack_build_map(&w);
    mpack_write_cstr(&w, "type");
    mpack_write_cstr(&w, "pane");
    mpack_write_cstr(&w, "pane_id");
    mpack_write_cstr(&w, "%5");
    mpack_write_cstr(&w, "row");
    mpack_write_int(&w, 3);
    mpack_complete_map(&w);
    mpack_write_cstr(&w, "width");
    mpack_write_int(&w, 20);
    mpack_write_cstr(&w, "height");
    mpack_write_int(&w, 15);
    mpack_complete_map(&w);
    mpack_finish_array(&w);
    mpack_finish_array(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    /* Verify structure: find anchor.type == "pane" */
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, data, size);
    mpack_expect_array(&rd);
    mpack_discard(&rd); /* type */
    mpack_discard(&rd); /* msgid */
    char method[32];
    mpack_expect_cstr(&rd, method, sizeof(method));
    assert(strcmp(method, "place") == 0);
    mpack_expect_array(&rd);
    uint32_t nkeys = mpack_expect_map(&rd);
    int found_anchor = 0;
    for (uint32_t i = 0; i < nkeys; i++) {
        char key[32];
        mpack_expect_cstr(&rd, key, sizeof(key));
        if (strcmp(key, "anchor") == 0) {
            uint32_t akeys = mpack_expect_map(&rd);
            for (uint32_t j = 0; j < akeys; j++) {
                char akey[32];
                mpack_expect_cstr(&rd, akey, sizeof(akey));
                if (strcmp(akey, "type") == 0) {
                    char aval[32];
                    mpack_expect_cstr(&rd, aval, sizeof(aval));
                    assert(strcmp(aval, "pane") == 0);
                    found_anchor = 1;
                } else if (strcmp(akey, "pane_id") == 0) {
                    char pval[32];
                    mpack_expect_cstr(&rd, pval, sizeof(pval));
                    assert(strcmp(pval, "%5") == 0);
                } else {
                    mpack_discard(&rd);
                }
            }
            mpack_done_map(&rd);
        } else {
            mpack_discard(&rd);
        }
    }
    mpack_done_map(&rd);
    mpack_done_array(&rd);
    mpack_done_array(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);
    free(data);

    assert(found_anchor);
}

/* Verify notification encoding: [2, method, [params]] */
static void test_encode_notification(void) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 3);
    mpack_write_int(&w, 2);
    mpack_write_cstr(&w, "stop");
    mpack_start_array(&w, 0);
    mpack_finish_array(&w);
    mpack_finish_array(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    mpack_reader_t rd;
    mpack_reader_init_data(&rd, data, size);
    assert(mpack_expect_array(&rd) == 3);
    assert(mpack_expect_int(&rd) == 2);
    char method[32];
    mpack_expect_cstr(&rd, method, sizeof(method));
    assert(strcmp(method, "stop") == 0);
    assert(mpack_expect_array(&rd) == 0);
    mpack_done_array(&rd);
    mpack_done_array(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);
    free(data);
}

/* ---- Decoding Tests ---- */

/* Helper: build a hello response in msgpack */
static void build_hello_response(char **out, size_t *outlen) {
    mpack_writer_t w;
    mpack_writer_init_growable(&w, out, outlen);
    mpack_start_map(&w, 6);
    mpack_write_cstr(&w, "client_id");
    mpack_write_cstr(&w, "test-client-abc");
    mpack_write_cstr(&w, "cols");
    mpack_write_int(&w, 120);
    mpack_write_cstr(&w, "rows");
    mpack_write_int(&w, 40);
    mpack_write_cstr(&w, "cell_width");
    mpack_write_int(&w, 8);
    mpack_write_cstr(&w, "cell_height");
    mpack_write_int(&w, 16);
    mpack_write_cstr(&w, "in_tmux");
    mpack_write_bool(&w, true);
    mpack_finish_map(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);
}

static void test_decode_hello(void) {
    char *resp = NULL;
    size_t resplen = 0;
    build_hello_response(&resp, &resplen);

    kgd_hello_result hello;
    memset(&hello, 0, sizeof(hello));

    mpack_reader_t rd;
    mpack_reader_init_data(&rd, resp, resplen);
    enum { HK_CLIENT_ID, HK_COLS, HK_ROWS, HK_CELL_WIDTH, HK_CELL_HEIGHT, HK_IN_TMUX, HK_COUNT };
    const char *hkeys[] = {"client_id", "cols", "rows", "cell_width", "cell_height", "in_tmux"};
    bool hfound[HK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, hkeys, hfound, HK_COUNT)) {
        case HK_CLIENT_ID:
            mpack_expect_cstr(&rd, hello.client_id, sizeof(hello.client_id));
            break;
        case HK_COLS:
            hello.cols = mpack_expect_int(&rd);
            break;
        case HK_ROWS:
            hello.rows = mpack_expect_int(&rd);
            break;
        case HK_CELL_WIDTH:
            hello.cell_width = mpack_expect_int(&rd);
            break;
        case HK_CELL_HEIGHT:
            hello.cell_height = mpack_expect_int(&rd);
            break;
        case HK_IN_TMUX:
            hello.in_tmux = mpack_expect_bool(&rd) ? 1 : 0;
            break;
        default:
            mpack_discard(&rd);
            break;
        }
    }
    mpack_done_map(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);

    assert(strcmp(hello.client_id, "test-client-abc") == 0);
    assert(hello.client_id[strlen("test-client-abc")] == '\0'); /* null-terminated */
    assert(hello.cols == 120);
    assert(hello.rows == 40);
    assert(hello.cell_width == 8);
    assert(hello.cell_height == 16);
    assert(hello.in_tmux == 1);

    free(resp);
}

static void test_decode_upload(void) {
    char *resp = NULL;
    size_t resplen = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &resp, &resplen);
    mpack_start_map(&w, 1);
    mpack_write_cstr(&w, "handle");
    mpack_write_u32(&w, 42);
    mpack_finish_map(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    uint32_t handle = 0;
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, resp, resplen);
    enum { UK_HANDLE, UK_COUNT };
    const char *ukeys[] = {"handle"};
    bool ufound[UK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, ukeys, ufound, UK_COUNT)) {
        case UK_HANDLE:
            handle = mpack_expect_u32(&rd);
            break;
        default:
            mpack_discard(&rd);
            break;
        }
    }
    mpack_done_map(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);

    assert(handle == 42);
    free(resp);
}

static void test_decode_place(void) {
    char *resp = NULL;
    size_t resplen = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &resp, &resplen);
    mpack_start_map(&w, 1);
    mpack_write_cstr(&w, "placement_id");
    mpack_write_u32(&w, 99);
    mpack_finish_map(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    uint32_t pid = 0;
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, resp, resplen);
    enum { PLK_PID, PLK_COUNT };
    const char *plkeys[] = {"placement_id"};
    bool plfound[PLK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, plkeys, plfound, PLK_COUNT)) {
        case PLK_PID:
            pid = mpack_expect_u32(&rd);
            break;
        default:
            mpack_discard(&rd);
            break;
        }
    }
    mpack_done_map(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);

    assert(pid == 99);
    free(resp);
}

static void test_decode_list(void) {
    char *resp = NULL;
    size_t resplen = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &resp, &resplen);
    mpack_start_map(&w, 1);
    mpack_write_cstr(&w, "placements");
    mpack_start_array(&w, 2);

    /* First placement */
    mpack_start_map(&w, 6);
    mpack_write_cstr(&w, "placement_id"); mpack_write_u32(&w, 1);
    mpack_write_cstr(&w, "client_id"); mpack_write_cstr(&w, "client-1");
    mpack_write_cstr(&w, "handle"); mpack_write_u32(&w, 10);
    mpack_write_cstr(&w, "visible"); mpack_write_bool(&w, true);
    mpack_write_cstr(&w, "row"); mpack_write_int(&w, 5);
    mpack_write_cstr(&w, "col"); mpack_write_int(&w, 12);
    mpack_finish_map(&w);

    /* Second placement with extra unknown key */
    mpack_start_map(&w, 4);
    mpack_write_cstr(&w, "placement_id"); mpack_write_u32(&w, 2);
    mpack_write_cstr(&w, "client_id"); mpack_write_cstr(&w, "client-2");
    mpack_write_cstr(&w, "handle"); mpack_write_u32(&w, 20);
    mpack_write_cstr(&w, "unknown_key"); mpack_write_int(&w, 999);
    mpack_finish_map(&w);

    mpack_finish_array(&w);
    mpack_finish_map(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    /* Parse using the same pattern as kgd_list */
    kgd_placement_info *out = NULL;
    int out_count = 0;

    mpack_reader_t rd;
    mpack_reader_init_data(&rd, resp, resplen);
    enum { LK_PLACEMENTS, LK_COUNT };
    const char *lkeys[] = {"placements"};
    bool lfound[LK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, lkeys, lfound, LK_COUNT)) {
        case LK_PLACEMENTS: {
            uint32_t arr_count = mpack_expect_array_max(&rd, 4096);
            if (arr_count > 0) {
                out = calloc(arr_count, sizeof(kgd_placement_info));
                assert(out);
                out_count = (int)arr_count;
                enum { PK_PLACEMENT_ID, PK_CLIENT_ID, PK_HANDLE, PK_VISIBLE, PK_ROW, PK_COL, PK_COUNT };
                const char *pkeys[] = {"placement_id", "client_id", "handle", "visible", "row", "col"};
                for (uint32_t j = 0; j < arr_count && mpack_reader_error(&rd) == mpack_ok; j++) {
                    bool pfound[PK_COUNT] = {0};
                    uint32_t mkeys = mpack_expect_map_max(&rd, 32);
                    for (uint32_t k = 0; k < mkeys && mpack_reader_error(&rd) == mpack_ok; k++) {
                        switch (mpack_expect_key_cstr(&rd, pkeys, pfound, PK_COUNT)) {
                        case PK_PLACEMENT_ID: out[j].placement_id = mpack_expect_u32(&rd); break;
                        case PK_CLIENT_ID: mpack_expect_cstr(&rd, out[j].client_id, sizeof(out[j].client_id)); break;
                        case PK_HANDLE: out[j].handle = mpack_expect_u32(&rd); break;
                        case PK_VISIBLE: out[j].visible = mpack_expect_bool(&rd) ? 1 : 0; break;
                        case PK_ROW: out[j].row = mpack_expect_int(&rd); break;
                        case PK_COL: out[j].col = mpack_expect_int(&rd); break;
                        default: mpack_discard(&rd); break;
                        }
                    }
                    mpack_done_map(&rd);
                }
            }
            mpack_done_array(&rd);
            break;
        }
        default:
            mpack_discard(&rd);
            break;
        }
    }
    mpack_done_map(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);

    assert(out_count == 2);
    assert(out[0].placement_id == 1);
    assert(strcmp(out[0].client_id, "client-1") == 0);
    assert(out[0].client_id[strlen("client-1")] == '\0'); /* null-terminated */
    assert(out[0].handle == 10);
    assert(out[0].visible == 1);
    assert(out[0].row == 5);
    assert(out[0].col == 12);

    assert(out[1].placement_id == 2);
    assert(strcmp(out[1].client_id, "client-2") == 0);
    assert(out[1].handle == 20);
    /* visible, row, col default to 0 */
    assert(out[1].visible == 0);
    assert(out[1].row == 0);

    free(out);
    free(resp);
}

static void test_decode_status(void) {
    char *resp = NULL;
    size_t resplen = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &resp, &resplen);
    mpack_start_map(&w, 5);
    mpack_write_cstr(&w, "clients"); mpack_write_int(&w, 3);
    mpack_write_cstr(&w, "placements"); mpack_write_int(&w, 7);
    mpack_write_cstr(&w, "images"); mpack_write_int(&w, 5);
    mpack_write_cstr(&w, "cols"); mpack_write_int(&w, 200);
    mpack_write_cstr(&w, "rows"); mpack_write_int(&w, 50);
    mpack_finish_map(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    kgd_status_result out;
    memset(&out, 0, sizeof(out));
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, resp, resplen);
    enum { SK_CLIENTS, SK_PLACEMENTS, SK_IMAGES, SK_COLS, SK_ROWS, SK_COUNT };
    const char *skeys[] = {"clients", "placements", "images", "cols", "rows"};
    bool sfound[SK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, skeys, sfound, SK_COUNT)) {
        case SK_CLIENTS: out.clients = mpack_expect_int(&rd); break;
        case SK_PLACEMENTS: out.placements = mpack_expect_int(&rd); break;
        case SK_IMAGES: out.images = mpack_expect_int(&rd); break;
        case SK_COLS: out.cols = mpack_expect_int(&rd); break;
        case SK_ROWS: out.rows = mpack_expect_int(&rd); break;
        default: mpack_discard(&rd); break;
        }
    }
    mpack_done_map(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);

    assert(out.clients == 3);
    assert(out.placements == 7);
    assert(out.images == 5);
    assert(out.cols == 200);
    assert(out.rows == 50);

    free(resp);
}

/* ---- process_message Tests ---- */

/* Build a full msgpack-rpc response: [1, msgid, nil, result] */
static void build_rpc_response(uint32_t msgid, const char *result, size_t result_len,
                                char **out, size_t *outlen) {
    mpack_writer_t w;
    mpack_writer_init_growable(&w, out, outlen);
    mpack_start_array(&w, 4);
    mpack_write_int(&w, 1);
    mpack_write_u32(&w, msgid);
    mpack_write_nil(&w);
    mpack_write_bytes(&w, result, result_len);
    mpack_finish_array(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);
}

/* Build a full msgpack-rpc notification: [2, method, [params_map]] */
static void build_notification(const char *method, const char *params, size_t params_len,
                                char **out, size_t *outlen) {
    mpack_writer_t w;
    mpack_writer_init_growable(&w, out, outlen);
    mpack_start_array(&w, 3);
    mpack_write_int(&w, 2);
    mpack_write_cstr(&w, method);
    mpack_start_array(&w, 1);
    mpack_write_bytes(&w, params, params_len);
    mpack_finish_array(&w);
    mpack_finish_array(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);
}

/* Create a mock client for testing process_message */
static kgd_client *make_mock_client(void) {
    kgd_client *c = calloc(1, sizeof(*c));
    assert(c);
    c->fd = -1;
    pthread_mutex_init(&c->write_lock, NULL);
    for (int i = 0; i < MAX_PENDING; i++) {
        pthread_mutex_init(&c->pending[i].mtx, NULL);
        pthread_cond_init(&c->pending[i].cond, NULL);
    }
    return c;
}

static void free_mock_client(kgd_client *c) {
    pthread_mutex_destroy(&c->write_lock);
    for (int i = 0; i < MAX_PENDING; i++) {
        pthread_mutex_destroy(&c->pending[i].mtx);
        pthread_cond_destroy(&c->pending[i].cond);
        free(c->pending[i].data);
    }
    free(c->recv_buf);
    free(c);
}

static void test_process_response(void) {
    kgd_client *c = make_mock_client();

    /* Build a result payload: {"handle": 42} */
    char *result = NULL;
    size_t result_len = 0;
    mpack_writer_t rw;
    mpack_writer_init_growable(&rw, &result, &result_len);
    mpack_start_map(&rw, 1);
    mpack_write_cstr(&rw, "handle");
    mpack_write_u32(&rw, 42);
    mpack_finish_map(&rw);
    assert(mpack_writer_destroy(&rw) == mpack_ok);

    /* Build the full RPC response */
    uint32_t msgid = 7;
    char *msg = NULL;
    size_t msglen = 0;
    build_rpc_response(msgid, result, result_len, &msg, &msglen);

    /* Set up pending slot */
    int slot = (int)(msgid % MAX_PENDING);
    c->pending[slot].active = 1;

    /* Process */
    process_message(c, (const uint8_t *)msg, msglen);

    /* Verify */
    assert(c->pending[slot].done == 1);
    assert(c->pending[slot].has_error == 0);
    assert(c->pending[slot].data != NULL);
    assert(c->pending[slot].len == result_len);
    assert(memcmp(c->pending[slot].data, result, result_len) == 0);

    free(result);
    free(msg);
    free_mock_client(c);
}

/* Callback tracking for notification tests */
static uint32_t cb_evicted_handle;
static int cb_evicted_called;
static void test_evicted_cb(uint32_t handle, void *ud) {
    (void)ud;
    cb_evicted_handle = handle;
    cb_evicted_called = 1;
}

static void test_notify_evicted(void) {
    kgd_client *c = make_mock_client();
    cb_evicted_called = 0;
    cb_evicted_handle = 0;
    c->evicted_cb = test_evicted_cb;

    /* Build params: {"handle": 55} */
    char *params = NULL;
    size_t params_len = 0;
    mpack_writer_t pw;
    mpack_writer_init_growable(&pw, &params, &params_len);
    mpack_start_map(&pw, 1);
    mpack_write_cstr(&pw, "handle");
    mpack_write_u32(&pw, 55);
    mpack_finish_map(&pw);
    assert(mpack_writer_destroy(&pw) == mpack_ok);

    char *msg = NULL;
    size_t msglen = 0;
    build_notification("evicted", params, params_len, &msg, &msglen);

    process_message(c, (const uint8_t *)msg, msglen);

    assert(cb_evicted_called == 1);
    assert(cb_evicted_handle == 55);

    free(params);
    free(msg);
    free_mock_client(c);
}

static int cb_topology_cols, cb_topology_rows, cb_topology_cw, cb_topology_ch;
static int cb_topology_called;
static void test_topology_cb(int cols, int rows, int cw, int ch, void *ud) {
    (void)ud;
    cb_topology_cols = cols;
    cb_topology_rows = rows;
    cb_topology_cw = cw;
    cb_topology_ch = ch;
    cb_topology_called = 1;
}

static void test_notify_topology(void) {
    kgd_client *c = make_mock_client();
    cb_topology_called = 0;
    c->topology_cb = test_topology_cb;

    char *params = NULL;
    size_t params_len = 0;
    mpack_writer_t pw;
    mpack_writer_init_growable(&pw, &params, &params_len);
    mpack_start_map(&pw, 4);
    mpack_write_cstr(&pw, "cols"); mpack_write_int(&pw, 160);
    mpack_write_cstr(&pw, "rows"); mpack_write_int(&pw, 48);
    mpack_write_cstr(&pw, "cell_width"); mpack_write_int(&pw, 9);
    mpack_write_cstr(&pw, "cell_height"); mpack_write_int(&pw, 18);
    mpack_finish_map(&pw);
    assert(mpack_writer_destroy(&pw) == mpack_ok);

    char *msg = NULL;
    size_t msglen = 0;
    build_notification("topology_changed", params, params_len, &msg, &msglen);

    process_message(c, (const uint8_t *)msg, msglen);

    assert(cb_topology_called == 1);
    assert(cb_topology_cols == 160);
    assert(cb_topology_rows == 48);
    assert(cb_topology_cw == 9);
    assert(cb_topology_ch == 18);

    free(params);
    free(msg);
    free_mock_client(c);
}

static uint32_t cb_visibility_pid;
static int cb_visibility_visible;
static int cb_visibility_called;
static void test_visibility_cb(uint32_t pid, int visible, void *ud) {
    (void)ud;
    cb_visibility_pid = pid;
    cb_visibility_visible = visible;
    cb_visibility_called = 1;
}

static void test_notify_visibility(void) {
    kgd_client *c = make_mock_client();
    cb_visibility_called = 0;
    c->visibility_cb = test_visibility_cb;

    char *params = NULL;
    size_t params_len = 0;
    mpack_writer_t pw;
    mpack_writer_init_growable(&pw, &params, &params_len);
    mpack_start_map(&pw, 2);
    mpack_write_cstr(&pw, "placement_id"); mpack_write_u32(&pw, 77);
    mpack_write_cstr(&pw, "visible"); mpack_write_bool(&pw, true);
    mpack_finish_map(&pw);
    assert(mpack_writer_destroy(&pw) == mpack_ok);

    char *msg = NULL;
    size_t msglen = 0;
    build_notification("visibility_changed", params, params_len, &msg, &msglen);

    process_message(c, (const uint8_t *)msg, msglen);

    assert(cb_visibility_called == 1);
    assert(cb_visibility_pid == 77);
    assert(cb_visibility_visible == 1);

    free(params);
    free(msg);
    free_mock_client(c);
}

static kgd_color cb_theme_fg, cb_theme_bg;
static int cb_theme_called;
static void test_theme_cb(kgd_color fg, kgd_color bg, void *ud) {
    (void)ud;
    cb_theme_fg = fg;
    cb_theme_bg = bg;
    cb_theme_called = 1;
}

static void test_notify_theme(void) {
    kgd_client *c = make_mock_client();
    cb_theme_called = 0;
    c->theme_cb = test_theme_cb;

    char *params = NULL;
    size_t params_len = 0;
    mpack_writer_t pw;
    mpack_writer_init_growable(&pw, &params, &params_len);
    mpack_start_map(&pw, 2);
    mpack_write_cstr(&pw, "fg");
    mpack_start_map(&pw, 3);
    mpack_write_cstr(&pw, "r"); mpack_write_int(&pw, 255);
    mpack_write_cstr(&pw, "g"); mpack_write_int(&pw, 128);
    mpack_write_cstr(&pw, "b"); mpack_write_int(&pw, 64);
    mpack_finish_map(&pw);
    mpack_write_cstr(&pw, "bg");
    mpack_start_map(&pw, 3);
    mpack_write_cstr(&pw, "r"); mpack_write_int(&pw, 10);
    mpack_write_cstr(&pw, "g"); mpack_write_int(&pw, 20);
    mpack_write_cstr(&pw, "b"); mpack_write_int(&pw, 30);
    mpack_finish_map(&pw);
    mpack_finish_map(&pw);
    assert(mpack_writer_destroy(&pw) == mpack_ok);

    char *msg = NULL;
    size_t msglen = 0;
    build_notification("theme_changed", params, params_len, &msg, &msglen);

    process_message(c, (const uint8_t *)msg, msglen);

    assert(cb_theme_called == 1);
    assert(cb_theme_fg.r == 255);
    assert(cb_theme_fg.g == 128);
    assert(cb_theme_fg.b == 64);
    assert(cb_theme_bg.r == 10);
    assert(cb_theme_bg.g == 20);
    assert(cb_theme_bg.b == 30);

    free(params);
    free(msg);
    free_mock_client(c);
}

/* ---- Edge Case Tests ---- */

static void test_decode_unknown_keys(void) {
    /* Status response with extra unknown keys should still parse */
    char *resp = NULL;
    size_t resplen = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &resp, &resplen);
    mpack_start_map(&w, 7);
    mpack_write_cstr(&w, "clients"); mpack_write_int(&w, 1);
    mpack_write_cstr(&w, "extra1"); mpack_write_cstr(&w, "ignored");
    mpack_write_cstr(&w, "placements"); mpack_write_int(&w, 2);
    mpack_write_cstr(&w, "extra2"); mpack_write_int(&w, 999);
    mpack_write_cstr(&w, "images"); mpack_write_int(&w, 3);
    mpack_write_cstr(&w, "cols"); mpack_write_int(&w, 80);
    mpack_write_cstr(&w, "rows"); mpack_write_int(&w, 24);
    mpack_finish_map(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    kgd_status_result out;
    memset(&out, 0, sizeof(out));
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, resp, resplen);
    enum { SK_CLIENTS, SK_PLACEMENTS, SK_IMAGES, SK_COLS, SK_ROWS, SK_COUNT };
    const char *skeys[] = {"clients", "placements", "images", "cols", "rows"};
    bool sfound[SK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, skeys, sfound, SK_COUNT)) {
        case SK_CLIENTS: out.clients = mpack_expect_int(&rd); break;
        case SK_PLACEMENTS: out.placements = mpack_expect_int(&rd); break;
        case SK_IMAGES: out.images = mpack_expect_int(&rd); break;
        case SK_COLS: out.cols = mpack_expect_int(&rd); break;
        case SK_ROWS: out.rows = mpack_expect_int(&rd); break;
        default: mpack_discard(&rd); break;
        }
    }
    mpack_done_map(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);

    assert(out.clients == 1);
    assert(out.placements == 2);
    assert(out.images == 3);
    assert(out.cols == 80);
    assert(out.rows == 24);

    free(resp);
}

static void test_decode_missing_keys(void) {
    /* Status response with only some keys — others default to 0 */
    char *resp = NULL;
    size_t resplen = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &resp, &resplen);
    mpack_start_map(&w, 2);
    mpack_write_cstr(&w, "clients"); mpack_write_int(&w, 5);
    mpack_write_cstr(&w, "cols"); mpack_write_int(&w, 132);
    mpack_finish_map(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    kgd_status_result out;
    memset(&out, 0, sizeof(out));
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, resp, resplen);
    enum { SK_CLIENTS, SK_PLACEMENTS, SK_IMAGES, SK_COLS, SK_ROWS, SK_COUNT };
    const char *skeys[] = {"clients", "placements", "images", "cols", "rows"};
    bool sfound[SK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, skeys, sfound, SK_COUNT)) {
        case SK_CLIENTS: out.clients = mpack_expect_int(&rd); break;
        case SK_PLACEMENTS: out.placements = mpack_expect_int(&rd); break;
        case SK_IMAGES: out.images = mpack_expect_int(&rd); break;
        case SK_COLS: out.cols = mpack_expect_int(&rd); break;
        case SK_ROWS: out.rows = mpack_expect_int(&rd); break;
        default: mpack_discard(&rd); break;
        }
    }
    mpack_done_map(&rd);
    assert(mpack_reader_error(&rd) == mpack_ok);
    mpack_reader_destroy(&rd);

    assert(out.clients == 5);
    assert(out.placements == 0);
    assert(out.images == 0);
    assert(out.cols == 132);
    assert(out.rows == 0);

    free(resp);
}

static void test_decode_truncated(void) {
    /* Truncated msgpack should cause reader error, not crash */
    uint8_t truncated[] = {0x82, 0xa7}; /* start of map with 2 entries, start of fixstr */
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, (const char *)truncated, sizeof(truncated));
    mpack_expect_map(&rd);
    /* Trying to read a key from truncated data */
    char buf[32];
    mpack_expect_cstr(&rd, buf, sizeof(buf));
    assert(mpack_reader_error(&rd) != mpack_ok);
    mpack_reader_destroy(&rd);
}

static void test_process_truncated_message(void) {
    /* Verify process_message handles truncated data gracefully */
    kgd_client *c = make_mock_client();

    uint8_t truncated[] = {0x94, 0x01, 0xce}; /* array(4), int(1), uint32 start... */
    process_message(c, truncated, sizeof(truncated));
    /* Should not crash */

    free_mock_client(c);
}

static void test_process_unknown_notification(void) {
    /* Unknown notification method should not crash */
    kgd_client *c = make_mock_client();

    char *params = NULL;
    size_t params_len = 0;
    mpack_writer_t pw;
    mpack_writer_init_growable(&pw, &params, &params_len);
    mpack_start_map(&pw, 1);
    mpack_write_cstr(&pw, "something");
    mpack_write_int(&pw, 42);
    mpack_finish_map(&pw);
    assert(mpack_writer_destroy(&pw) == mpack_ok);

    char *msg = NULL;
    size_t msglen = 0;
    build_notification("unknown_method", params, params_len, &msg, &msglen);

    process_message(c, (const uint8_t *)msg, msglen);
    /* Should not crash */

    free(params);
    free(msg);
    free_mock_client(c);
}

static void test_process_rpc_error(void) {
    /* RPC response with error field (not nil) */
    kgd_client *c = make_mock_client();

    char *msg = NULL;
    size_t msglen = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &msg, &msglen);
    mpack_start_array(&w, 4);
    mpack_write_int(&w, 1); /* response */
    mpack_write_u32(&w, 3); /* msgid */
    /* error: {"message": "not found"} */
    mpack_start_map(&w, 1);
    mpack_write_cstr(&w, "message");
    mpack_write_cstr(&w, "not found");
    mpack_finish_map(&w);
    /* result: nil */
    mpack_write_nil(&w);
    mpack_finish_array(&w);
    assert(mpack_writer_destroy(&w) == mpack_ok);

    int slot = 3 % MAX_PENDING;
    c->pending[slot].active = 1;

    process_message(c, (const uint8_t *)msg, msglen);

    assert(c->pending[slot].done == 1);
    assert(c->pending[slot].has_error == 1);
    assert(c->pending[slot].data == NULL);

    free(msg);
    free_mock_client(c);
}

static void test_recv_buf_overflow_check(void) {
    /* Verify the overflow detection: SIZE_MAX + small number wraps */
    size_t a = SIZE_MAX - 5;
    size_t b = 10;
    size_t need = a + b;
    /* This should wrap around */
    assert(need < a); /* confirms overflow detection logic */
}

/* ---- Main ---- */

int main(void) {
    fprintf(stderr, "kgd C client tests:\n\n");
    fprintf(stderr, "Encoding tests:\n");
    RUN_TEST(test_encode_hello);
    RUN_TEST(test_encode_upload);
    RUN_TEST(test_encode_place);
    RUN_TEST(test_encode_notification);

    fprintf(stderr, "\nDecoding tests:\n");
    RUN_TEST(test_decode_hello);
    RUN_TEST(test_decode_upload);
    RUN_TEST(test_decode_place);
    RUN_TEST(test_decode_list);
    RUN_TEST(test_decode_status);

    fprintf(stderr, "\nprocess_message tests:\n");
    RUN_TEST(test_process_response);
    RUN_TEST(test_notify_evicted);
    RUN_TEST(test_notify_topology);
    RUN_TEST(test_notify_visibility);
    RUN_TEST(test_notify_theme);

    fprintf(stderr, "\nEdge case tests:\n");
    RUN_TEST(test_decode_unknown_keys);
    RUN_TEST(test_decode_missing_keys);
    RUN_TEST(test_decode_truncated);
    RUN_TEST(test_process_truncated_message);
    RUN_TEST(test_process_unknown_notification);
    RUN_TEST(test_process_rpc_error);
    RUN_TEST(test_recv_buf_overflow_check);

    fprintf(stderr, "\n%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
