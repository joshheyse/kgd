/*
 * kgd.c — C client for kgd (Kitty Graphics Daemon)
 *
 * Msgpack-rpc over Unix sockets using MPack for encode/decode.
 */

#define _POSIX_C_SOURCE 199309L

#include "kgd.h"
#include "mpack.h"

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* ---------- client internals ---------- */

#define MAX_PENDING 64
#define RECV_BUF_SIZE 65536

static _Thread_local char tls_error[256] = {0};

static void set_error(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(tls_error, sizeof(tls_error), fmt, ap);
    va_end(ap);
}

typedef struct {
    int active;
    pthread_mutex_t mtx;
    pthread_cond_t cond;
    uint8_t *data;
    size_t len;
    int done;
    int has_error;
} pending_entry;

struct kgd_client {
    int fd;
    pthread_mutex_t write_lock;
    atomic_uint_fast32_t next_id;

    pending_entry pending[MAX_PENDING];

    kgd_hello_result hello;

    pthread_t reader;
    atomic_int closed;

    /*
     * Callbacks — set these before the client is used from multiple threads.
     * The reader thread reads these without locks, so they must be fully
     * configured before any notifications can arrive (i.e. before the first
     * RPC call returns). Modifying callbacks after kgd_connect() returns is
     * a data race unless the caller serializes with the reader thread.
     */
    kgd_evicted_cb evicted_cb;
    void *evicted_ud;
    kgd_topology_cb topology_cb;
    void *topology_ud;
    kgd_visibility_cb visibility_cb;
    void *visibility_ud;
    kgd_theme_cb theme_cb;
    void *theme_ud;

    /* Read buffer for streaming (dynamically sized) */
    uint8_t *recv_buf;
    size_t recv_len;
    size_t recv_cap;
};

/* Forward declarations */
static void *reader_thread(void *arg);
static kgd_error do_call(kgd_client *c, const uint8_t *req, size_t reqlen, uint32_t msgid,
                         uint8_t **out, size_t *outlen);
static kgd_error send_all(kgd_client *c, const uint8_t *data, size_t len);
static void process_message(kgd_client *c, const uint8_t *data, size_t len);

/* ---------- public API ---------- */

const char *kgd_last_error(void) {
    return tls_error;
}

kgd_client *kgd_connect(const kgd_options *opts) {
    const char *path = NULL;
    const char *client_type = "";
    const char *label = "";
    const char *session_id = NULL;

    if (opts) {
        path = opts->socket_path;
        if (opts->client_type)
            client_type = opts->client_type;
        if (opts->label)
            label = opts->label;
        session_id = opts->session_id;
    }

    if (!path || !*path) {
        path = getenv("KGD_SOCKET");
    }
    if (!path || !*path) {
        set_error("no socket path (set KGD_SOCKET or pass socket_path)");
        return NULL;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        set_error("socket: %s", strerror(errno));
        return NULL;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        set_error("connect %s: %s", path, strerror(errno));
        close(fd);
        return NULL;
    }

    kgd_client *c = calloc(1, sizeof(*c));
    if (!c) {
        close(fd);
        set_error("out of memory");
        return NULL;
    }

    c->fd = fd;
    pthread_mutex_init(&c->write_lock, NULL);

    for (int i = 0; i < MAX_PENDING; i++) {
        pthread_mutex_init(&c->pending[i].mtx, NULL);
        pthread_cond_init(&c->pending[i].cond, NULL);
    }

    /* Start reader thread */
    if (pthread_create(&c->reader, NULL, reader_thread, c) != 0) {
        set_error("pthread_create: %s", strerror(errno));
        close(fd);
        free(c);
        return NULL;
    }

    /* Send hello */
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 4);
    mpack_write_int(&w, 0); /* request */
    uint32_t msgid = c->next_id++;
    mpack_write_u32(&w, msgid);
    mpack_write_cstr(&w, "hello");
    mpack_start_array(&w, 1);
    mpack_build_map(&w);
    mpack_write_cstr(&w, "client_type");
    mpack_write_cstr(&w, client_type);
    mpack_write_cstr(&w, "pid");
    mpack_write_int(&w, (int)getpid());
    mpack_write_cstr(&w, "label");
    mpack_write_cstr(&w, label);
    if (session_id && *session_id) {
        mpack_write_cstr(&w, "session_id");
        mpack_write_cstr(&w, session_id);
    }
    mpack_complete_map(&w);
    mpack_finish_array(&w);
    mpack_finish_array(&w);

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        kgd_close(c);
        set_error("encode hello: out of memory");
        return NULL;
    }

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, (const uint8_t *)data, size, msgid, &resp, &resplen);
    free(data);

    if (err != KGD_OK) {
        kgd_close(c);
        return NULL;
    }

    /* Parse hello result */
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, (const char *)resp, resplen);
    enum { HK_CLIENT_ID, HK_COLS, HK_ROWS, HK_CELL_WIDTH, HK_CELL_HEIGHT, HK_IN_TMUX, HK_COUNT };
    const char *hkeys[] = {"client_id", "cols", "rows", "cell_width", "cell_height", "in_tmux"};
    bool hfound[HK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, hkeys, hfound, HK_COUNT)) {
        case HK_CLIENT_ID:
            mpack_expect_cstr(&rd, c->hello.client_id, sizeof(c->hello.client_id));
            break;
        case HK_COLS:
            c->hello.cols = mpack_expect_int(&rd);
            break;
        case HK_ROWS:
            c->hello.rows = mpack_expect_int(&rd);
            break;
        case HK_CELL_WIDTH:
            c->hello.cell_width = mpack_expect_int(&rd);
            break;
        case HK_CELL_HEIGHT:
            c->hello.cell_height = mpack_expect_int(&rd);
            break;
        case HK_IN_TMUX:
            c->hello.in_tmux = mpack_expect_bool(&rd) ? 1 : 0;
            break;
        default:
            mpack_discard(&rd);
            break;
        }
    }
    mpack_done_map(&rd);
    mpack_reader_destroy(&rd);
    free(resp);

    return c;
}

const kgd_hello_result *kgd_get_hello(const kgd_client *c) {
    return &c->hello;
}

kgd_error kgd_upload(kgd_client *c, const void *imgdata, size_t len, const char *format, int width,
                     int height, uint32_t *out_handle) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 4);
    mpack_write_int(&w, 0);
    uint32_t msgid = c->next_id++;
    mpack_write_u32(&w, msgid);
    mpack_write_cstr(&w, "upload");
    mpack_start_array(&w, 1);
    mpack_start_map(&w, 4);
    mpack_write_cstr(&w, "data");
    mpack_write_bin(&w, (const char *)imgdata, len);
    mpack_write_cstr(&w, "format");
    mpack_write_cstr(&w, format);
    mpack_write_cstr(&w, "width");
    mpack_write_int(&w, width);
    mpack_write_cstr(&w, "height");
    mpack_write_int(&w, height);
    mpack_finish_map(&w);
    mpack_finish_array(&w);
    mpack_finish_array(&w);

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        return KGD_ERR_NOMEM;
    }

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, (const uint8_t *)data, size, msgid, &resp, &resplen);
    free(data);
    if (err != KGD_OK)
        return err;

    /* Parse: {"handle": uint32} */
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, (const char *)resp, resplen);
    enum { UK_HANDLE, UK_COUNT };
    const char *ukeys[] = {"handle"};
    bool ufound[UK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, ukeys, ufound, UK_COUNT)) {
        case UK_HANDLE:
            *out_handle = mpack_expect_u32(&rd);
            break;
        default:
            mpack_discard(&rd);
            break;
        }
    }
    mpack_done_map(&rd);
    mpack_reader_destroy(&rd);
    free(resp);
    return KGD_OK;
}

kgd_error kgd_place(kgd_client *c, uint32_t handle, const kgd_anchor *anchor, int width, int height,
                    const kgd_place_opts *opts, uint32_t *out_id) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 4);
    mpack_write_int(&w, 0);
    uint32_t msgid = c->next_id++;
    mpack_write_u32(&w, msgid);
    mpack_write_cstr(&w, "place");
    mpack_start_array(&w, 1);

    /* Use build_map for variable field count */
    mpack_build_map(&w);

    mpack_write_cstr(&w, "handle");
    mpack_write_u32(&w, handle);

    mpack_write_cstr(&w, "anchor");
    mpack_build_map(&w);
    if (anchor->type == KGD_ANCHOR_PANE) {
        mpack_write_cstr(&w, "type");
        mpack_write_cstr(&w, "pane");
        if (anchor->pane_id) {
            mpack_write_cstr(&w, "pane_id");
            mpack_write_cstr(&w, anchor->pane_id);
        }
        if (anchor->row) {
            mpack_write_cstr(&w, "row");
            mpack_write_int(&w, anchor->row);
        }
        if (anchor->col) {
            mpack_write_cstr(&w, "col");
            mpack_write_int(&w, anchor->col);
        }
    } else if (anchor->type == KGD_ANCHOR_NVIM_WIN) {
        mpack_write_cstr(&w, "type");
        mpack_write_cstr(&w, "nvim_win");
        if (anchor->win_id) {
            mpack_write_cstr(&w, "win_id");
            mpack_write_int(&w, anchor->win_id);
        }
        if (anchor->buf_line) {
            mpack_write_cstr(&w, "buf_line");
            mpack_write_int(&w, anchor->buf_line);
        }
        if (anchor->col) {
            mpack_write_cstr(&w, "col");
            mpack_write_int(&w, anchor->col);
        }
    } else {
        mpack_write_cstr(&w, "type");
        mpack_write_cstr(&w, "absolute");
        if (anchor->row) {
            mpack_write_cstr(&w, "row");
            mpack_write_int(&w, anchor->row);
        }
        if (anchor->col) {
            mpack_write_cstr(&w, "col");
            mpack_write_int(&w, anchor->col);
        }
    }
    mpack_complete_map(&w);

    mpack_write_cstr(&w, "width");
    mpack_write_int(&w, width);
    mpack_write_cstr(&w, "height");
    mpack_write_int(&w, height);

    if (opts) {
        if (opts->src_x) {
            mpack_write_cstr(&w, "src_x");
            mpack_write_int(&w, opts->src_x);
        }
        if (opts->src_y) {
            mpack_write_cstr(&w, "src_y");
            mpack_write_int(&w, opts->src_y);
        }
        if (opts->src_w) {
            mpack_write_cstr(&w, "src_w");
            mpack_write_int(&w, opts->src_w);
        }
        if (opts->src_h) {
            mpack_write_cstr(&w, "src_h");
            mpack_write_int(&w, opts->src_h);
        }
        if (opts->z_index) {
            mpack_write_cstr(&w, "z_index");
            mpack_write_int(&w, opts->z_index);
        }
    }
    mpack_complete_map(&w);

    mpack_finish_array(&w);
    mpack_finish_array(&w);

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        return KGD_ERR_NOMEM;
    }

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, (const uint8_t *)data, size, msgid, &resp, &resplen);
    free(data);
    if (err != KGD_OK)
        return err;

    /* Parse: {"placement_id": uint32} */
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, (const char *)resp, resplen);
    enum { PLK_PLACEMENT_ID, PLK_COUNT };
    const char *plkeys[] = {"placement_id"};
    bool plfound[PLK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, plkeys, plfound, PLK_COUNT)) {
        case PLK_PLACEMENT_ID:
            *out_id = mpack_expect_u32(&rd);
            break;
        default:
            mpack_discard(&rd);
            break;
        }
    }
    mpack_done_map(&rd);
    mpack_reader_destroy(&rd);
    free(resp);
    return KGD_OK;
}

static kgd_error send_simple_call(kgd_client *c, const char *method, const char *key,
                                  uint32_t val) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 4);
    mpack_write_int(&w, 0);
    uint32_t msgid = c->next_id++;
    mpack_write_u32(&w, msgid);
    mpack_write_cstr(&w, method);
    mpack_start_array(&w, 1);
    mpack_start_map(&w, 1);
    mpack_write_cstr(&w, key);
    mpack_write_u32(&w, val);
    mpack_finish_map(&w);
    mpack_finish_array(&w);
    mpack_finish_array(&w);

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        return KGD_ERR_NOMEM;
    }

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, (const uint8_t *)data, size, msgid, &resp, &resplen);
    free(data);
    free(resp);
    return err;
}

kgd_error kgd_unplace(kgd_client *c, uint32_t placement_id) {
    return send_simple_call(c, "unplace", "placement_id", placement_id);
}

kgd_error kgd_unplace_all(kgd_client *c) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 3);
    mpack_write_int(&w, 2); /* notification */
    mpack_write_cstr(&w, "unplace_all");
    mpack_start_array(&w, 0);
    mpack_finish_array(&w);
    mpack_finish_array(&w);

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        return KGD_ERR_NOMEM;
    }

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, (const uint8_t *)data, size);
    pthread_mutex_unlock(&c->write_lock);
    free(data);
    return err;
}

kgd_error kgd_free_handle(kgd_client *c, uint32_t handle) {
    return send_simple_call(c, "free", "handle", handle);
}

kgd_error kgd_register_win(kgd_client *c, int win_id, const char *pane_id, int top, int left,
                           int width, int height, int scroll_top) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 3);
    mpack_write_int(&w, 2); /* notification */
    mpack_write_cstr(&w, "register_win");
    mpack_start_array(&w, 1);
    mpack_build_map(&w);
    mpack_write_cstr(&w, "win_id");
    mpack_write_int(&w, win_id);
    if (pane_id && *pane_id) {
        mpack_write_cstr(&w, "pane_id");
        mpack_write_cstr(&w, pane_id);
    }
    mpack_write_cstr(&w, "top");
    mpack_write_int(&w, top);
    mpack_write_cstr(&w, "left");
    mpack_write_int(&w, left);
    mpack_write_cstr(&w, "width");
    mpack_write_int(&w, width);
    mpack_write_cstr(&w, "height");
    mpack_write_int(&w, height);
    mpack_write_cstr(&w, "scroll_top");
    mpack_write_int(&w, scroll_top);
    mpack_complete_map(&w);
    mpack_finish_array(&w);
    mpack_finish_array(&w);

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        return KGD_ERR_NOMEM;
    }

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, (const uint8_t *)data, size);
    pthread_mutex_unlock(&c->write_lock);
    free(data);
    return err;
}

kgd_error kgd_update_scroll(kgd_client *c, int win_id, int scroll_top) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 3);
    mpack_write_int(&w, 2);
    mpack_write_cstr(&w, "update_scroll");
    mpack_start_array(&w, 1);
    mpack_start_map(&w, 2);
    mpack_write_cstr(&w, "win_id");
    mpack_write_int(&w, win_id);
    mpack_write_cstr(&w, "scroll_top");
    mpack_write_int(&w, scroll_top);
    mpack_finish_map(&w);
    mpack_finish_array(&w);
    mpack_finish_array(&w);

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        return KGD_ERR_NOMEM;
    }

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, (const uint8_t *)data, size);
    pthread_mutex_unlock(&c->write_lock);
    free(data);
    return err;
}

kgd_error kgd_unregister_win(kgd_client *c, int win_id) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 3);
    mpack_write_int(&w, 2);
    mpack_write_cstr(&w, "unregister_win");
    mpack_start_array(&w, 1);
    mpack_start_map(&w, 1);
    mpack_write_cstr(&w, "win_id");
    mpack_write_int(&w, win_id);
    mpack_finish_map(&w);
    mpack_finish_array(&w);
    mpack_finish_array(&w);

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        return KGD_ERR_NOMEM;
    }

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, (const uint8_t *)data, size);
    pthread_mutex_unlock(&c->write_lock);
    free(data);
    return err;
}

kgd_error kgd_list(kgd_client *c, kgd_placement_info **out, int *out_count) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 4);
    mpack_write_int(&w, 0);
    uint32_t msgid = c->next_id++;
    mpack_write_u32(&w, msgid);
    mpack_write_cstr(&w, "list");
    mpack_start_array(&w, 0);
    mpack_finish_array(&w);
    mpack_finish_array(&w);

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        return KGD_ERR_NOMEM;
    }

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, (const uint8_t *)data, size, msgid, &resp, &resplen);
    free(data);
    if (err != KGD_OK)
        return err;

    *out = NULL;
    *out_count = 0;

    mpack_reader_t rd;
    mpack_reader_init_data(&rd, (const char *)resp, resplen);
    enum { LK_PLACEMENTS, LK_COUNT };
    const char *lkeys[] = {"placements"};
    bool lfound[LK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, lkeys, lfound, LK_COUNT)) {
        case LK_PLACEMENTS: {
            uint32_t arr_count = mpack_expect_array_max(&rd, 4096);
            if (mpack_reader_error(&rd) != mpack_ok)
                break;
            if (arr_count > 0) {
                *out = calloc(arr_count, sizeof(kgd_placement_info));
                if (!*out) {
                    mpack_reader_destroy(&rd);
                    free(resp);
                    return KGD_ERR_NOMEM;
                }
                *out_count = (int)arr_count;
                enum {
                    PK_PLACEMENT_ID,
                    PK_CLIENT_ID,
                    PK_HANDLE,
                    PK_VISIBLE,
                    PK_ROW,
                    PK_COL,
                    PK_COUNT
                };
                const char *pkeys[] = {"placement_id", "client_id", "handle",
                                       "visible",      "row",       "col"};
                for (uint32_t j = 0; j < arr_count && mpack_reader_error(&rd) == mpack_ok; j++) {
                    bool pfound[PK_COUNT] = {0};
                    uint32_t mkeys = mpack_expect_map_max(&rd, 32);
                    for (uint32_t k = 0; k < mkeys && mpack_reader_error(&rd) == mpack_ok; k++) {
                        switch (mpack_expect_key_cstr(&rd, pkeys, pfound, PK_COUNT)) {
                        case PK_PLACEMENT_ID:
                            (*out)[j].placement_id = mpack_expect_u32(&rd);
                            break;
                        case PK_CLIENT_ID:
                            mpack_expect_cstr(&rd, (*out)[j].client_id,
                                              sizeof((*out)[j].client_id));
                            break;
                        case PK_HANDLE:
                            (*out)[j].handle = mpack_expect_u32(&rd);
                            break;
                        case PK_VISIBLE:
                            (*out)[j].visible = mpack_expect_bool(&rd) ? 1 : 0;
                            break;
                        case PK_ROW:
                            (*out)[j].row = mpack_expect_int(&rd);
                            break;
                        case PK_COL:
                            (*out)[j].col = mpack_expect_int(&rd);
                            break;
                        default:
                            mpack_discard(&rd);
                            break;
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
    mpack_reader_destroy(&rd);
    free(resp);
    return KGD_OK;
}

void kgd_free_list(kgd_placement_info *list) {
    free(list);
}

kgd_error kgd_status(kgd_client *c, kgd_status_result *out) {
    char *data = NULL;
    size_t size = 0;
    mpack_writer_t w;
    mpack_writer_init_growable(&w, &data, &size);

    mpack_start_array(&w, 4);
    mpack_write_int(&w, 0);
    uint32_t msgid = c->next_id++;
    mpack_write_u32(&w, msgid);
    mpack_write_cstr(&w, "status");
    mpack_start_array(&w, 0);
    mpack_finish_array(&w);
    mpack_finish_array(&w);

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        return KGD_ERR_NOMEM;
    }

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, (const uint8_t *)data, size, msgid, &resp, &resplen);
    free(data);
    if (err != KGD_OK)
        return err;

    memset(out, 0, sizeof(*out));
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, (const char *)resp, resplen);
    enum { SK_CLIENTS, SK_PLACEMENTS, SK_IMAGES, SK_COLS, SK_ROWS, SK_COUNT };
    const char *skeys[] = {"clients", "placements", "images", "cols", "rows"};
    bool sfound[SK_COUNT] = {0};
    uint32_t nkeys = mpack_expect_map_max(&rd, 32);
    for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
        switch (mpack_expect_key_cstr(&rd, skeys, sfound, SK_COUNT)) {
        case SK_CLIENTS:
            out->clients = mpack_expect_int(&rd);
            break;
        case SK_PLACEMENTS:
            out->placements = mpack_expect_int(&rd);
            break;
        case SK_IMAGES:
            out->images = mpack_expect_int(&rd);
            break;
        case SK_COLS:
            out->cols = mpack_expect_int(&rd);
            break;
        case SK_ROWS:
            out->rows = mpack_expect_int(&rd);
            break;
        default:
            mpack_discard(&rd);
            break;
        }
    }
    mpack_done_map(&rd);
    mpack_reader_destroy(&rd);
    free(resp);
    return KGD_OK;
}

kgd_error kgd_stop(kgd_client *c) {
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

    if (mpack_writer_destroy(&w) != mpack_ok) {
        free(data);
        return KGD_ERR_NOMEM;
    }

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, (const uint8_t *)data, size);
    pthread_mutex_unlock(&c->write_lock);
    free(data);
    return err;
}

void kgd_close(kgd_client *c) {
    if (!c)
        return;
    c->closed = 1;
    shutdown(c->fd, SHUT_RDWR);
    close(c->fd);
    pthread_join(c->reader, NULL);
    pthread_mutex_destroy(&c->write_lock);
    for (int i = 0; i < MAX_PENDING; i++) {
        pthread_mutex_destroy(&c->pending[i].mtx);
        pthread_cond_destroy(&c->pending[i].cond);
        free(c->pending[i].data);
    }
    free(c->recv_buf);
    free(c);
}

void kgd_set_evicted_cb(kgd_client *c, kgd_evicted_cb cb, void *ud) {
    c->evicted_cb = cb;
    c->evicted_ud = ud;
}

void kgd_set_topology_cb(kgd_client *c, kgd_topology_cb cb, void *ud) {
    c->topology_cb = cb;
    c->topology_ud = ud;
}

void kgd_set_visibility_cb(kgd_client *c, kgd_visibility_cb cb, void *ud) {
    c->visibility_cb = cb;
    c->visibility_ud = ud;
}

void kgd_set_theme_cb(kgd_client *c, kgd_theme_cb cb, void *ud) {
    c->theme_cb = cb;
    c->theme_ud = ud;
}

/* ---------- internal helpers ---------- */

static kgd_error send_all(kgd_client *c, const uint8_t *data, size_t len) {
    while (len > 0) {
        ssize_t n = write(c->fd, data, len);
        if (n <= 0) {
            set_error("write: %s", strerror(errno));
            return KGD_ERR_SEND;
        }
        data += n;
        len -= (size_t)n;
    }
    return KGD_OK;
}

static kgd_error do_call(kgd_client *c, const uint8_t *req, size_t reqlen, uint32_t msgid,
                         uint8_t **out, size_t *outlen) {
    int slot = (int)(msgid % MAX_PENDING);
    pending_entry *pe = &c->pending[slot];

    pthread_mutex_lock(&pe->mtx);
    if (pe->active) {
        pthread_mutex_unlock(&pe->mtx);
        set_error("pending slot %d busy", slot);
        return KGD_ERR_SEND;
    }
    pe->active = 1;
    pe->done = 0;
    pe->has_error = 0;
    free(pe->data);
    pe->data = NULL;
    pe->len = 0;
    pthread_mutex_unlock(&pe->mtx);

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, req, reqlen);
    pthread_mutex_unlock(&c->write_lock);

    if (err != KGD_OK) {
        pthread_mutex_lock(&pe->mtx);
        pe->active = 0;
        pthread_mutex_unlock(&pe->mtx);
        return err;
    }

    pthread_mutex_lock(&pe->mtx);
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 10;
    while (!pe->done && !c->closed) {
        int rc = pthread_cond_timedwait(&pe->cond, &pe->mtx, &deadline);
        if (rc == ETIMEDOUT && !pe->done) {
            pe->active = 0;
            pthread_mutex_unlock(&pe->mtx);
            set_error("RPC call timed out");
            return KGD_ERR_TIMEOUT;
        }
    }

    if (c->closed && !pe->done) {
        pthread_mutex_unlock(&pe->mtx);
        pe->active = 0;
        set_error("connection closed");
        return KGD_ERR_RECV;
    }

    if (pe->has_error) {
        free(pe->data);
        pthread_mutex_unlock(&pe->mtx);
        pe->active = 0;
        return KGD_ERR_RPC;
    }

    *out = pe->data;
    *outlen = pe->len;
    pe->data = NULL;
    pe->active = 0;
    pthread_mutex_unlock(&pe->mtx);
    return KGD_OK;
}

/* Process a complete msgpack response/notification. */
static void process_message(kgd_client *c, const uint8_t *data, size_t len) {
    mpack_reader_t rd;
    mpack_reader_init_data(&rd, (const char *)data, len);

    uint32_t arr_count = mpack_expect_array_max(&rd, 8);
    if (arr_count < 3 || mpack_reader_error(&rd) != mpack_ok) {
        mpack_reader_destroy(&rd);
        return;
    }

    int msgtype = mpack_expect_int(&rd);
    if (mpack_reader_error(&rd) != mpack_ok) {
        mpack_reader_destroy(&rd);
        return;
    }

    if (msgtype == 1) { /* response: [1, msgid, error, result] */
        uint32_t msgid = mpack_expect_u32(&rd);
        if (mpack_reader_error(&rd) != mpack_ok) {
            mpack_reader_destroy(&rd);
            return;
        }

        /* Read error field — check if it's nil */
        mpack_tag_t err_tag = mpack_read_tag(&rd);
        int has_rpc_error = (err_tag.type != mpack_type_nil);

        if (has_rpc_error && err_tag.type == mpack_type_map) {
            uint32_t ecount = mpack_tag_map_count(&err_tag);
            for (uint32_t i = 0; i < ecount && mpack_reader_error(&rd) == mpack_ok; i++) {
                /* Read key */
                char keybuf[32];
                mpack_expect_cstr(&rd, keybuf, sizeof(keybuf));
                if (mpack_reader_error(&rd) != mpack_ok) {
                    /* Key too large or not a string; skip remaining */
                    mpack_reader_destroy(&rd);
                    return;
                }
                if (strcmp(keybuf, "message") == 0) {
                    char msgbuf[256];
                    mpack_expect_cstr(&rd, msgbuf, sizeof(msgbuf));
                    if (mpack_reader_error(&rd) == mpack_ok) {
                        set_error("%s", msgbuf);
                    }
                } else {
                    mpack_discard(&rd);
                }
            }
            mpack_done_map(&rd);
        } else if (has_rpc_error) {
            /* Error is not nil and not a map — skip it */
            mpack_discard(&rd);
        }

        /* Read result — capture raw bytes for the pending slot */
        const char *remaining = NULL;
        size_t rem_len = mpack_reader_remaining(&rd, &remaining);
        /* The result is everything from here to end of message, minus any
         * trailing data. We need to figure out the result's encoded size. */
        mpack_reader_t result_rd;
        mpack_reader_init_data(&result_rd, remaining, rem_len);
        mpack_discard(&result_rd);
        size_t result_len = 0;
        if (mpack_reader_error(&result_rd) == mpack_ok) {
            const char *after_result = NULL;
            size_t after_len = mpack_reader_remaining(&result_rd, &after_result);
            result_len = rem_len - after_len;
        }
        mpack_reader_destroy(&result_rd);

        /* Also skip past it in the main reader */
        mpack_discard(&rd);

        int slot = (int)(msgid % MAX_PENDING);
        pending_entry *pe = &c->pending[slot];

        pthread_mutex_lock(&pe->mtx);
        if (pe->active) {
            pe->has_error = has_rpc_error;
            if (!has_rpc_error && result_len > 0) {
                pe->data = malloc(result_len);
                if (pe->data) {
                    memcpy(pe->data, remaining, result_len);
                    pe->len = result_len;
                }
            }
            pe->done = 1;
            pthread_cond_signal(&pe->cond);
        }
        pthread_mutex_unlock(&pe->mtx);
    } else if (msgtype == 2) { /* notification: [2, method, [params]] */
        char method[64];
        mpack_expect_cstr(&rd, method, sizeof(method));
        if (mpack_reader_error(&rd) != mpack_ok) {
            mpack_reader_destroy(&rd);
            return;
        }

        uint32_t params_arr_count = mpack_expect_array_max(&rd, 16);
        if (mpack_reader_error(&rd) != mpack_ok) {
            mpack_reader_destroy(&rd);
            return;
        }
        if (params_arr_count == 0) {
            mpack_done_array(&rd); /* params array */
            mpack_done_array(&rd); /* outer array */
            mpack_reader_destroy(&rd);
            return;
        }

        if (strcmp(method, "evicted") == 0 && c->evicted_cb) {
            uint32_t handle = 0;
            enum { EK_HANDLE, EK_COUNT };
            const char *ekeys[] = {"handle"};
            bool efound[EK_COUNT] = {0};
            uint32_t nkeys = mpack_expect_map_max(&rd, 32);
            for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
                switch (mpack_expect_key_cstr(&rd, ekeys, efound, EK_COUNT)) {
                case EK_HANDLE:
                    handle = mpack_expect_u32(&rd);
                    break;
                default:
                    mpack_discard(&rd);
                    break;
                }
            }
            mpack_done_map(&rd);
            /* Skip remaining params */
            for (uint32_t i = 1; i < params_arr_count; i++)
                mpack_discard(&rd);
            mpack_done_array(&rd);
            mpack_done_array(&rd);
            mpack_reader_destroy(&rd);
            c->evicted_cb(handle, c->evicted_ud);
            return;
        } else if (strcmp(method, "topology_changed") == 0 && c->topology_cb) {
            int cols = 0, rows = 0, cw = 0, ch = 0;
            enum { TK_COLS, TK_ROWS, TK_CELL_WIDTH, TK_CELL_HEIGHT, TK_COUNT };
            const char *tkeys[] = {"cols", "rows", "cell_width", "cell_height"};
            bool tfound[TK_COUNT] = {0};
            uint32_t nkeys = mpack_expect_map_max(&rd, 32);
            for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
                switch (mpack_expect_key_cstr(&rd, tkeys, tfound, TK_COUNT)) {
                case TK_COLS:
                    cols = mpack_expect_int(&rd);
                    break;
                case TK_ROWS:
                    rows = mpack_expect_int(&rd);
                    break;
                case TK_CELL_WIDTH:
                    cw = mpack_expect_int(&rd);
                    break;
                case TK_CELL_HEIGHT:
                    ch = mpack_expect_int(&rd);
                    break;
                default:
                    mpack_discard(&rd);
                    break;
                }
            }
            mpack_done_map(&rd);
            for (uint32_t i = 1; i < params_arr_count; i++)
                mpack_discard(&rd);
            mpack_done_array(&rd);
            mpack_done_array(&rd);
            mpack_reader_destroy(&rd);
            c->topology_cb(cols, rows, cw, ch, c->topology_ud);
            return;
        } else if (strcmp(method, "visibility_changed") == 0 && c->visibility_cb) {
            uint32_t pid = 0;
            int visible = 0;
            enum { VK_PLACEMENT_ID, VK_VISIBLE, VK_COUNT };
            const char *vkeys[] = {"placement_id", "visible"};
            bool vfound[VK_COUNT] = {0};
            uint32_t nkeys = mpack_expect_map_max(&rd, 32);
            for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
                switch (mpack_expect_key_cstr(&rd, vkeys, vfound, VK_COUNT)) {
                case VK_PLACEMENT_ID:
                    pid = mpack_expect_u32(&rd);
                    break;
                case VK_VISIBLE:
                    visible = mpack_expect_bool(&rd) ? 1 : 0;
                    break;
                default:
                    mpack_discard(&rd);
                    break;
                }
            }
            mpack_done_map(&rd);
            for (uint32_t i = 1; i < params_arr_count; i++)
                mpack_discard(&rd);
            mpack_done_array(&rd);
            mpack_done_array(&rd);
            mpack_reader_destroy(&rd);
            c->visibility_cb(pid, visible, c->visibility_ud);
            return;
        } else if (strcmp(method, "theme_changed") == 0 && c->theme_cb) {
            kgd_color fg = {0}, bg = {0};
            enum { THK_FG, THK_BG, THK_COUNT };
            const char *thkeys[] = {"fg", "bg"};
            bool thfound[THK_COUNT] = {0};
            uint32_t nkeys = mpack_expect_map_max(&rd, 32);
            for (uint32_t i = 0; i < nkeys && mpack_reader_error(&rd) == mpack_ok; i++) {
                kgd_color *target = NULL;
                switch (mpack_expect_key_cstr(&rd, thkeys, thfound, THK_COUNT)) {
                case THK_FG:
                    target = &fg;
                    goto parse_color;
                case THK_BG:
                    target = &bg;
                    goto parse_color;
                parse_color: {
                    enum { CK_R, CK_G, CK_B, CK_COUNT };
                    const char *cnames[] = {"r", "g", "b"};
                    bool cfound[CK_COUNT] = {0};
                    uint32_t ckeys = mpack_expect_map_max(&rd, 8);
                    for (uint32_t j = 0; j < ckeys && mpack_reader_error(&rd) == mpack_ok; j++) {
                        switch (mpack_expect_key_cstr(&rd, cnames, cfound, CK_COUNT)) {
                        case CK_R:
                            target->r = (uint16_t)mpack_expect_int(&rd);
                            break;
                        case CK_G:
                            target->g = (uint16_t)mpack_expect_int(&rd);
                            break;
                        case CK_B:
                            target->b = (uint16_t)mpack_expect_int(&rd);
                            break;
                        default:
                            mpack_discard(&rd);
                            break;
                        }
                    }
                    mpack_done_map(&rd);
                    break;
                }
                default:
                    mpack_discard(&rd);
                    break;
                }
            }
            mpack_done_map(&rd);
            for (uint32_t i = 1; i < params_arr_count; i++)
                mpack_discard(&rd);
            mpack_done_array(&rd);
            mpack_done_array(&rd);
            mpack_reader_destroy(&rd);
            c->theme_cb(fg, bg, c->theme_ud);
            return;
        } else {
            /* Unknown notification — skip all params */
            for (uint32_t i = 0; i < params_arr_count; i++)
                mpack_discard(&rd);
        }

        mpack_done_array(&rd); /* params array */
    }

    mpack_done_array(&rd); /* outer array */
    mpack_reader_destroy(&rd);
}

static void *reader_thread(void *arg) {
    kgd_client *c = (kgd_client *)arg;
    uint8_t tmp[RECV_BUF_SIZE];

    while (!c->closed) {
        ssize_t n = read(c->fd, tmp, sizeof(tmp));
        if (n <= 0)
            break;

        /* Grow recv buffer if needed — with overflow check */
        size_t need = c->recv_len + (size_t)n;
        if (need < c->recv_len) {
            /* size_t overflow */
            c->recv_len = 0;
            continue;
        }
        if (need > c->recv_cap) {
            size_t newcap = c->recv_cap ? c->recv_cap : RECV_BUF_SIZE;
            while (newcap < need) {
                if (newcap > SIZE_MAX / 2) {
                    c->recv_len = 0;
                    goto next_read;
                }
                newcap *= 2;
            }
            uint8_t *p = realloc(c->recv_buf, newcap);
            if (!p) {
                c->recv_len = 0;
                continue;
            }
            c->recv_buf = p;
            c->recv_cap = newcap;
        }
        memcpy(c->recv_buf + c->recv_len, tmp, (size_t)n);
        c->recv_len += (size_t)n;

        /* Try to decode complete messages using MPack for framing */
        while (c->recv_len > 0) {
            mpack_reader_t rd;
            mpack_reader_init_data(&rd, (const char *)c->recv_buf, c->recv_len);
            mpack_discard(&rd);
            if (mpack_reader_error(&rd) != mpack_ok) {
                mpack_reader_destroy(&rd);
                break; /* incomplete message */
            }
            size_t msg_len = c->recv_len - mpack_reader_remaining(&rd, NULL);
            mpack_reader_destroy(&rd);

            /* Process the complete message */
            process_message(c, c->recv_buf, msg_len);

            /* Remove processed bytes */
            size_t remaining = c->recv_len - msg_len;
            if (remaining > 0) {
                memmove(c->recv_buf, c->recv_buf + msg_len, remaining);
            }
            c->recv_len = remaining;
        }
    next_read:;
    }

    /* Wake pending calls */
    for (int i = 0; i < MAX_PENDING; i++) {
        pthread_mutex_lock(&c->pending[i].mtx);
        if (c->pending[i].active) {
            c->pending[i].done = 1;
            pthread_cond_signal(&c->pending[i].cond);
        }
        pthread_mutex_unlock(&c->pending[i].mtx);
    }

    return NULL;
}
