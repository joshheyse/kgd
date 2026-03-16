/*
 * kgd.c — C client for kgd (Kitty Graphics Daemon)
 *
 * Minimal msgpack-rpc implementation over Unix sockets.
 * No external dependencies beyond POSIX and libc.
 */

#include "kgd.h"

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* ---------- msgpack encoding helpers ---------- */

typedef struct {
    uint8_t *buf;
    size_t len;
    size_t cap;
} mpbuf;

static void mp_init(mpbuf *b) {
    b->buf = NULL;
    b->len = 0;
    b->cap = 0;
}

static void mp_free(mpbuf *b) {
    free(b->buf);
    b->buf = NULL;
    b->len = b->cap = 0;
}

static int mp_ensure(mpbuf *b, size_t need) {
    if (b->len + need <= b->cap) return 0;
    size_t newcap = b->cap ? b->cap * 2 : 256;
    while (newcap < b->len + need) newcap *= 2;
    uint8_t *p = realloc(b->buf, newcap);
    if (!p) return -1;
    b->buf = p;
    b->cap = newcap;
    return 0;
}

static void mp_byte(mpbuf *b, uint8_t v) {
    if (mp_ensure(b, 1)) return;
    b->buf[b->len++] = v;
}

static void mp_uint32(mpbuf *b, uint32_t v) {
    if (mp_ensure(b, 5)) return;
    b->buf[b->len++] = 0xce;
    b->buf[b->len++] = (v >> 24) & 0xff;
    b->buf[b->len++] = (v >> 16) & 0xff;
    b->buf[b->len++] = (v >> 8) & 0xff;
    b->buf[b->len++] = v & 0xff;
}

static void mp_int(mpbuf *b, int v) {
    if (v >= 0 && v <= 127) {
        mp_byte(b, (uint8_t)v);
    } else if (v >= -32 && v < 0) {
        mp_byte(b, (uint8_t)(v & 0xff));
    } else if (v >= -128 && v <= 127) {
        if (mp_ensure(b, 2)) return;
        b->buf[b->len++] = 0xd0;
        b->buf[b->len++] = (uint8_t)(v & 0xff);
    } else if (v >= -32768 && v <= 32767) {
        if (mp_ensure(b, 3)) return;
        b->buf[b->len++] = 0xd1;
        b->buf[b->len++] = (v >> 8) & 0xff;
        b->buf[b->len++] = v & 0xff;
    } else {
        if (mp_ensure(b, 5)) return;
        b->buf[b->len++] = 0xd2;
        b->buf[b->len++] = (v >> 24) & 0xff;
        b->buf[b->len++] = (v >> 16) & 0xff;
        b->buf[b->len++] = (v >> 8) & 0xff;
        b->buf[b->len++] = v & 0xff;
    }
}

static void mp_str(mpbuf *b, const char *s) {
    size_t n = s ? strlen(s) : 0;
    if (n <= 31) {
        mp_byte(b, 0xa0 | (uint8_t)n);
    } else if (n <= 255) {
        if (mp_ensure(b, 2)) return;
        b->buf[b->len++] = 0xd9;
        b->buf[b->len++] = (uint8_t)n;
    } else if (n <= 65535) {
        if (mp_ensure(b, 3)) return;
        b->buf[b->len++] = 0xda;
        b->buf[b->len++] = (n >> 8) & 0xff;
        b->buf[b->len++] = n & 0xff;
    } else {
        if (mp_ensure(b, 5)) return;
        b->buf[b->len++] = 0xdb;
        b->buf[b->len++] = (n >> 24) & 0xff;
        b->buf[b->len++] = (n >> 16) & 0xff;
        b->buf[b->len++] = (n >> 8) & 0xff;
        b->buf[b->len++] = n & 0xff;
    }
    if (n > 0) {
        if (mp_ensure(b, n)) return;
        memcpy(b->buf + b->len, s, n);
        b->len += n;
    }
}

static void mp_bin(mpbuf *b, const void *data, size_t n) {
    if (n <= 255) {
        if (mp_ensure(b, 2)) return;
        b->buf[b->len++] = 0xc4;
        b->buf[b->len++] = (uint8_t)n;
    } else if (n <= 65535) {
        if (mp_ensure(b, 3)) return;
        b->buf[b->len++] = 0xc5;
        b->buf[b->len++] = (n >> 8) & 0xff;
        b->buf[b->len++] = n & 0xff;
    } else {
        if (mp_ensure(b, 5)) return;
        b->buf[b->len++] = 0xc6;
        b->buf[b->len++] = (n >> 24) & 0xff;
        b->buf[b->len++] = (n >> 16) & 0xff;
        b->buf[b->len++] = (n >> 8) & 0xff;
        b->buf[b->len++] = n & 0xff;
    }
    if (n > 0) {
        if (mp_ensure(b, n)) return;
        memcpy(b->buf + b->len, data, n);
        b->len += n;
    }
}

static void mp_array(mpbuf *b, size_t n) {
    if (n <= 15) {
        mp_byte(b, 0x90 | (uint8_t)n);
    } else if (n <= 65535) {
        if (mp_ensure(b, 3)) return;
        b->buf[b->len++] = 0xdc;
        b->buf[b->len++] = (n >> 8) & 0xff;
        b->buf[b->len++] = n & 0xff;
    } else {
        if (mp_ensure(b, 5)) return;
        b->buf[b->len++] = 0xdd;
        b->buf[b->len++] = (n >> 24) & 0xff;
        b->buf[b->len++] = (n >> 16) & 0xff;
        b->buf[b->len++] = (n >> 8) & 0xff;
        b->buf[b->len++] = n & 0xff;
    }
}

static void mp_map(mpbuf *b, size_t n) {
    if (n <= 15) {
        mp_byte(b, 0x80 | (uint8_t)n);
    } else if (n <= 65535) {
        if (mp_ensure(b, 3)) return;
        b->buf[b->len++] = 0xde;
        b->buf[b->len++] = (n >> 8) & 0xff;
        b->buf[b->len++] = n & 0xff;
    } else {
        if (mp_ensure(b, 5)) return;
        b->buf[b->len++] = 0xdf;
        b->buf[b->len++] = (n >> 24) & 0xff;
        b->buf[b->len++] = (n >> 16) & 0xff;
        b->buf[b->len++] = (n >> 8) & 0xff;
        b->buf[b->len++] = n & 0xff;
    }
}

/* ---------- msgpack decoding ---------- */

typedef struct {
    const uint8_t *buf;
    size_t len;
    size_t pos;
} mpreader;

typedef enum {
    MP_NIL, MP_BOOL, MP_INT, MP_UINT, MP_STR, MP_BIN,
    MP_ARRAY, MP_MAP, MP_ERROR
} mptype;

typedef struct {
    mptype type;
    union {
        int64_t i;
        uint64_t u;
        int b;
        struct { const char *ptr; size_t len; } str;
        size_t count; /* array/map element count */
    } v;
} mpval;

static mpval mp_read(mpreader *r) {
    mpval val = { .type = MP_ERROR };
    if (r->pos >= r->len) return val;

    uint8_t tag = r->buf[r->pos++];

    /* positive fixint */
    if (tag <= 0x7f) {
        val.type = MP_UINT;
        val.v.u = tag;
        return val;
    }
    /* negative fixint */
    if (tag >= 0xe0) {
        val.type = MP_INT;
        val.v.i = (int8_t)tag;
        return val;
    }
    /* fixstr */
    if ((tag & 0xe0) == 0xa0) {
        size_t n = tag & 0x1f;
        if (r->pos + n > r->len) return val;
        val.type = MP_STR;
        val.v.str.ptr = (const char *)(r->buf + r->pos);
        val.v.str.len = n;
        r->pos += n;
        return val;
    }
    /* fixarray */
    if ((tag & 0xf0) == 0x90) {
        val.type = MP_ARRAY;
        val.v.count = tag & 0x0f;
        return val;
    }
    /* fixmap */
    if ((tag & 0xf0) == 0x80) {
        val.type = MP_MAP;
        val.v.count = tag & 0x0f;
        return val;
    }

    switch (tag) {
    case 0xc0: val.type = MP_NIL; return val;
    case 0xc2: val.type = MP_BOOL; val.v.b = 0; return val;
    case 0xc3: val.type = MP_BOOL; val.v.b = 1; return val;

    /* bin 8/16/32 */
    case 0xc4: case 0xc5: case 0xc6: {
        size_t hlen = 1 << (tag - 0xc4);
        if (r->pos + hlen > r->len) return val;
        size_t n = 0;
        for (size_t i = 0; i < hlen; i++) n = (n << 8) | r->buf[r->pos++];
        if (r->pos + n > r->len) return val;
        val.type = MP_BIN;
        val.v.str.ptr = (const char *)(r->buf + r->pos);
        val.v.str.len = n;
        r->pos += n;
        return val;
    }

    /* uint 8/16/32/64 */
    case 0xcc:
        if (r->pos + 1 > r->len) return val;
        val.type = MP_UINT; val.v.u = r->buf[r->pos++]; return val;
    case 0xcd:
        if (r->pos + 2 > r->len) return val;
        val.type = MP_UINT;
        val.v.u = ((uint64_t)r->buf[r->pos] << 8) | r->buf[r->pos+1];
        r->pos += 2; return val;
    case 0xce:
        if (r->pos + 4 > r->len) return val;
        val.type = MP_UINT;
        val.v.u = ((uint64_t)r->buf[r->pos] << 24) | ((uint64_t)r->buf[r->pos+1] << 16) |
                  ((uint64_t)r->buf[r->pos+2] << 8) | r->buf[r->pos+3];
        r->pos += 4; return val;
    case 0xcf:
        if (r->pos + 8 > r->len) return val;
        val.type = MP_UINT; val.v.u = 0;
        for (int i = 0; i < 8; i++) val.v.u = (val.v.u << 8) | r->buf[r->pos++];
        return val;

    /* int 8/16/32/64 */
    case 0xd0:
        if (r->pos + 1 > r->len) return val;
        val.type = MP_INT; val.v.i = (int8_t)r->buf[r->pos++]; return val;
    case 0xd1:
        if (r->pos + 2 > r->len) return val;
        val.type = MP_INT;
        val.v.i = (int16_t)(((uint16_t)r->buf[r->pos] << 8) | r->buf[r->pos+1]);
        r->pos += 2; return val;
    case 0xd2:
        if (r->pos + 4 > r->len) return val;
        val.type = MP_INT;
        val.v.i = (int32_t)(((uint32_t)r->buf[r->pos] << 24) | ((uint32_t)r->buf[r->pos+1] << 16) |
                   ((uint32_t)r->buf[r->pos+2] << 8) | r->buf[r->pos+3]);
        r->pos += 4; return val;
    case 0xd3:
        if (r->pos + 8 > r->len) return val;
        val.type = MP_INT; val.v.i = 0;
        for (int i = 0; i < 8; i++) val.v.i = (val.v.i << 8) | r->buf[r->pos++];
        return val;

    /* str 8/16/32 */
    case 0xd9: case 0xda: case 0xdb: {
        size_t hlen = (tag == 0xd9) ? 1 : (tag == 0xda) ? 2 : 4;
        if (r->pos + hlen > r->len) return val;
        size_t n = 0;
        for (size_t i = 0; i < hlen; i++) n = (n << 8) | r->buf[r->pos++];
        if (r->pos + n > r->len) return val;
        val.type = MP_STR;
        val.v.str.ptr = (const char *)(r->buf + r->pos);
        val.v.str.len = n;
        r->pos += n;
        return val;
    }

    /* array 16/32 */
    case 0xdc:
        if (r->pos + 2 > r->len) return val;
        val.type = MP_ARRAY;
        val.v.count = ((size_t)r->buf[r->pos] << 8) | r->buf[r->pos+1];
        r->pos += 2; return val;
    case 0xdd:
        if (r->pos + 4 > r->len) return val;
        val.type = MP_ARRAY;
        val.v.count = ((size_t)r->buf[r->pos] << 24) | ((size_t)r->buf[r->pos+1] << 16) |
                      ((size_t)r->buf[r->pos+2] << 8) | r->buf[r->pos+3];
        r->pos += 4; return val;

    /* map 16/32 */
    case 0xde:
        if (r->pos + 2 > r->len) return val;
        val.type = MP_MAP;
        val.v.count = ((size_t)r->buf[r->pos] << 8) | r->buf[r->pos+1];
        r->pos += 2; return val;
    case 0xdf:
        if (r->pos + 4 > r->len) return val;
        val.type = MP_MAP;
        val.v.count = ((size_t)r->buf[r->pos] << 24) | ((size_t)r->buf[r->pos+1] << 16) |
                      ((size_t)r->buf[r->pos+2] << 8) | r->buf[r->pos+3];
        r->pos += 4; return val;

    default:
        return val;
    }
}

/* Skip one msgpack value (recursively for containers). */
static int mp_skip(mpreader *r) {
    mpval v = mp_read(r);
    if (v.type == MP_ERROR) return -1;
    if (v.type == MP_ARRAY) {
        for (size_t i = 0; i < v.v.count; i++)
            if (mp_skip(r)) return -1;
    } else if (v.type == MP_MAP) {
        for (size_t i = 0; i < v.v.count * 2; i++)
            if (mp_skip(r)) return -1;
    }
    return 0;
}

/* Read an integer (signed or unsigned). */
static int mp_read_int(mpreader *r, int *out) {
    mpval v = mp_read(r);
    if (v.type == MP_UINT) { *out = (int)v.v.u; return 0; }
    if (v.type == MP_INT) { *out = (int)v.v.i; return 0; }
    return -1;
}

static int mp_read_uint32(mpreader *r, uint32_t *out) {
    mpval v = mp_read(r);
    if (v.type == MP_UINT) { *out = (uint32_t)v.v.u; return 0; }
    if (v.type == MP_INT && v.v.i >= 0) { *out = (uint32_t)v.v.i; return 0; }
    return -1;
}

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
    volatile int closed;

    /* Callbacks */
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
static kgd_error do_call(kgd_client *c, const uint8_t *req, size_t reqlen,
                         uint32_t msgid, uint8_t **out, size_t *outlen);
static kgd_error send_all(kgd_client *c, const uint8_t *data, size_t len);

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
        if (opts->client_type) client_type = opts->client_type;
        if (opts->label) label = opts->label;
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
    mpbuf b;
    mp_init(&b);

    int nfields = 3; /* client_type, pid, label */
    if (session_id && *session_id) nfields++;

    mp_array(&b, 4);              /* [type, msgid, method, [params]] */
    mp_int(&b, 0);               /* request */
    uint32_t msgid = c->next_id++;
    mp_uint32(&b, msgid);
    mp_str(&b, "hello");
    mp_array(&b, 1);             /* params array */
    mp_map(&b, nfields);
    mp_str(&b, "client_type"); mp_str(&b, client_type);
    mp_str(&b, "pid"); mp_int(&b, (int)getpid());
    mp_str(&b, "label"); mp_str(&b, label);
    if (session_id && *session_id) {
        mp_str(&b, "session_id"); mp_str(&b, session_id);
    }

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, b.buf, b.len, msgid, &resp, &resplen);
    mp_free(&b);

    if (err != KGD_OK) {
        kgd_close(c);
        return NULL;
    }

    /* Parse hello result */
    mpreader rd = { .buf = resp, .len = resplen, .pos = 0 };
    mpval v = mp_read(&rd);
    if (v.type == MP_MAP) {
        for (size_t i = 0; i < v.v.count; i++) {
            mpval key = mp_read(&rd);
            if (key.type != MP_STR) { mp_skip(&rd); continue; }

            if (key.v.str.len == 9 && memcmp(key.v.str.ptr, "client_id", 9) == 0) {
                mpval val2 = mp_read(&rd);
                if (val2.type == MP_STR) {
                    size_t n = val2.v.str.len < 63 ? val2.v.str.len : 63;
                    memcpy(c->hello.client_id, val2.v.str.ptr, n);
                    c->hello.client_id[n] = 0;
                }
            } else if (key.v.str.len == 4 && memcmp(key.v.str.ptr, "cols", 4) == 0) {
                mp_read_int(&rd, &c->hello.cols);
            } else if (key.v.str.len == 4 && memcmp(key.v.str.ptr, "rows", 4) == 0) {
                mp_read_int(&rd, &c->hello.rows);
            } else if (key.v.str.len == 10 && memcmp(key.v.str.ptr, "cell_width", 10) == 0) {
                mp_read_int(&rd, &c->hello.cell_width);
            } else if (key.v.str.len == 11 && memcmp(key.v.str.ptr, "cell_height", 11) == 0) {
                mp_read_int(&rd, &c->hello.cell_height);
            } else if (key.v.str.len == 7 && memcmp(key.v.str.ptr, "in_tmux", 7) == 0) {
                mpval val2 = mp_read(&rd);
                if (val2.type == MP_BOOL) c->hello.in_tmux = val2.v.b;
            } else {
                mp_skip(&rd);
            }
        }
    }
    free(resp);

    return c;
}

const kgd_hello_result *kgd_get_hello(const kgd_client *c) {
    return &c->hello;
}

kgd_error kgd_upload(kgd_client *c, const void *data, size_t len,
                     const char *format, int width, int height,
                     uint32_t *out_handle) {
    mpbuf b;
    mp_init(&b);
    uint32_t msgid = c->next_id++;
    mp_array(&b, 4);
    mp_int(&b, 0);
    mp_uint32(&b, msgid);
    mp_str(&b, "upload");
    mp_array(&b, 1);
    mp_map(&b, 4);
    mp_str(&b, "data"); mp_bin(&b, data, len);
    mp_str(&b, "format"); mp_str(&b, format);
    mp_str(&b, "width"); mp_int(&b, width);
    mp_str(&b, "height"); mp_int(&b, height);

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, b.buf, b.len, msgid, &resp, &resplen);
    mp_free(&b);
    if (err != KGD_OK) return err;

    /* Parse: {"handle": uint32} */
    mpreader rd = { .buf = resp, .len = resplen, .pos = 0 };
    mpval v = mp_read(&rd);
    if (v.type == MP_MAP) {
        for (size_t i = 0; i < v.v.count; i++) {
            mpval key = mp_read(&rd);
            if (key.type == MP_STR && key.v.str.len == 6 &&
                memcmp(key.v.str.ptr, "handle", 6) == 0) {
                mp_read_uint32(&rd, out_handle);
            } else {
                mp_skip(&rd);
            }
        }
    }
    free(resp);
    return KGD_OK;
}

kgd_error kgd_place(kgd_client *c, uint32_t handle, const kgd_anchor *anchor,
                    int width, int height, const kgd_place_opts *opts,
                    uint32_t *out_id) {
    /* Count anchor map fields */
    int afields = 1; /* type */
    const char *type_str = "absolute";
    if (anchor->type == KGD_ANCHOR_PANE) {
        type_str = "pane";
        if (anchor->pane_id) afields++;
        if (anchor->row) afields++;
        if (anchor->col) afields++;
    } else if (anchor->type == KGD_ANCHOR_NVIM_WIN) {
        type_str = "nvim_win";
        if (anchor->win_id) afields++;
        if (anchor->buf_line) afields++;
        if (anchor->col) afields++;
    } else {
        if (anchor->row) afields++;
        if (anchor->col) afields++;
    }

    int pfields = 4; /* handle, anchor, width, height */
    if (opts) {
        if (opts->src_x) pfields++;
        if (opts->src_y) pfields++;
        if (opts->src_w) pfields++;
        if (opts->src_h) pfields++;
        if (opts->z_index) pfields++;
    }

    mpbuf b;
    mp_init(&b);
    uint32_t msgid = c->next_id++;
    mp_array(&b, 4);
    mp_int(&b, 0);
    mp_uint32(&b, msgid);
    mp_str(&b, "place");
    mp_array(&b, 1);
    mp_map(&b, pfields);

    mp_str(&b, "handle"); mp_uint32(&b, handle);
    mp_str(&b, "anchor");
    mp_map(&b, afields);
    mp_str(&b, "type"); mp_str(&b, type_str);
    if (anchor->type == KGD_ANCHOR_PANE) {
        if (anchor->pane_id) { mp_str(&b, "pane_id"); mp_str(&b, anchor->pane_id); }
        if (anchor->row) { mp_str(&b, "row"); mp_int(&b, anchor->row); }
        if (anchor->col) { mp_str(&b, "col"); mp_int(&b, anchor->col); }
    } else if (anchor->type == KGD_ANCHOR_NVIM_WIN) {
        if (anchor->win_id) { mp_str(&b, "win_id"); mp_int(&b, anchor->win_id); }
        if (anchor->buf_line) { mp_str(&b, "buf_line"); mp_int(&b, anchor->buf_line); }
        if (anchor->col) { mp_str(&b, "col"); mp_int(&b, anchor->col); }
    } else {
        if (anchor->row) { mp_str(&b, "row"); mp_int(&b, anchor->row); }
        if (anchor->col) { mp_str(&b, "col"); mp_int(&b, anchor->col); }
    }
    mp_str(&b, "width"); mp_int(&b, width);
    mp_str(&b, "height"); mp_int(&b, height);

    if (opts) {
        if (opts->src_x) { mp_str(&b, "src_x"); mp_int(&b, opts->src_x); }
        if (opts->src_y) { mp_str(&b, "src_y"); mp_int(&b, opts->src_y); }
        if (opts->src_w) { mp_str(&b, "src_w"); mp_int(&b, opts->src_w); }
        if (opts->src_h) { mp_str(&b, "src_h"); mp_int(&b, opts->src_h); }
        if (opts->z_index) { mp_str(&b, "z_index"); mp_int(&b, opts->z_index); }
    }

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, b.buf, b.len, msgid, &resp, &resplen);
    mp_free(&b);
    if (err != KGD_OK) return err;

    /* Parse: {"placement_id": uint32} */
    mpreader rd = { .buf = resp, .len = resplen, .pos = 0 };
    mpval v = mp_read(&rd);
    if (v.type == MP_MAP) {
        for (size_t i = 0; i < v.v.count; i++) {
            mpval key = mp_read(&rd);
            if (key.type == MP_STR && key.v.str.len == 12 &&
                memcmp(key.v.str.ptr, "placement_id", 12) == 0) {
                mp_read_uint32(&rd, out_id);
            } else {
                mp_skip(&rd);
            }
        }
    }
    free(resp);
    return KGD_OK;
}

static kgd_error send_simple_call(kgd_client *c, const char *method,
                                   const char *key, uint32_t val) {
    mpbuf b;
    mp_init(&b);
    uint32_t msgid = c->next_id++;
    mp_array(&b, 4);
    mp_int(&b, 0);
    mp_uint32(&b, msgid);
    mp_str(&b, method);
    mp_array(&b, 1);
    mp_map(&b, 1);
    mp_str(&b, key);
    mp_uint32(&b, val);

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, b.buf, b.len, msgid, &resp, &resplen);
    mp_free(&b);
    free(resp);
    return err;
}

kgd_error kgd_unplace(kgd_client *c, uint32_t placement_id) {
    return send_simple_call(c, "unplace", "placement_id", placement_id);
}

kgd_error kgd_unplace_all(kgd_client *c) {
    mpbuf b;
    mp_init(&b);
    mp_array(&b, 3);
    mp_int(&b, 2); /* notification */
    mp_str(&b, "unplace_all");
    mp_array(&b, 0);

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, b.buf, b.len);
    pthread_mutex_unlock(&c->write_lock);
    mp_free(&b);
    return err;
}

kgd_error kgd_free_handle(kgd_client *c, uint32_t handle) {
    return send_simple_call(c, "free", "handle", handle);
}

kgd_error kgd_register_win(kgd_client *c, int win_id, const char *pane_id,
                           int top, int left, int width, int height,
                           int scroll_top) {
    mpbuf b;
    mp_init(&b);
    mp_array(&b, 3);
    mp_int(&b, 2); /* notification */
    mp_str(&b, "register_win");
    mp_array(&b, 1);

    int nfields = 6; /* win_id, top, left, width, height, scroll_top */
    if (pane_id && *pane_id) nfields++;
    mp_map(&b, nfields);
    mp_str(&b, "win_id"); mp_int(&b, win_id);
    if (pane_id && *pane_id) { mp_str(&b, "pane_id"); mp_str(&b, pane_id); }
    mp_str(&b, "top"); mp_int(&b, top);
    mp_str(&b, "left"); mp_int(&b, left);
    mp_str(&b, "width"); mp_int(&b, width);
    mp_str(&b, "height"); mp_int(&b, height);
    mp_str(&b, "scroll_top"); mp_int(&b, scroll_top);

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, b.buf, b.len);
    pthread_mutex_unlock(&c->write_lock);
    mp_free(&b);
    return err;
}

kgd_error kgd_update_scroll(kgd_client *c, int win_id, int scroll_top) {
    mpbuf b;
    mp_init(&b);
    mp_array(&b, 3);
    mp_int(&b, 2);
    mp_str(&b, "update_scroll");
    mp_array(&b, 1);
    mp_map(&b, 2);
    mp_str(&b, "win_id"); mp_int(&b, win_id);
    mp_str(&b, "scroll_top"); mp_int(&b, scroll_top);

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, b.buf, b.len);
    pthread_mutex_unlock(&c->write_lock);
    mp_free(&b);
    return err;
}

kgd_error kgd_unregister_win(kgd_client *c, int win_id) {
    mpbuf b;
    mp_init(&b);
    mp_array(&b, 3);
    mp_int(&b, 2);
    mp_str(&b, "unregister_win");
    mp_array(&b, 1);
    mp_map(&b, 1);
    mp_str(&b, "win_id"); mp_int(&b, win_id);

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, b.buf, b.len);
    pthread_mutex_unlock(&c->write_lock);
    mp_free(&b);
    return err;
}

kgd_error kgd_list(kgd_client *c, kgd_placement_info **out, int *out_count) {
    mpbuf b;
    mp_init(&b);
    uint32_t msgid = c->next_id++;
    mp_array(&b, 4);
    mp_int(&b, 0);
    mp_uint32(&b, msgid);
    mp_str(&b, "list");
    mp_array(&b, 0);

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, b.buf, b.len, msgid, &resp, &resplen);
    mp_free(&b);
    if (err != KGD_OK) return err;

    *out = NULL;
    *out_count = 0;

    mpreader rd = { .buf = resp, .len = resplen, .pos = 0 };
    mpval v = mp_read(&rd);
    if (v.type == MP_MAP) {
        for (size_t i = 0; i < v.v.count; i++) {
            mpval key = mp_read(&rd);
            if (key.type == MP_STR && key.v.str.len == 10 &&
                memcmp(key.v.str.ptr, "placements", 10) == 0) {
                mpval arr = mp_read(&rd);
                if (arr.type == MP_ARRAY && arr.v.count > 0) {
                    *out = calloc(arr.v.count, sizeof(kgd_placement_info));
                    if (!*out) { free(resp); return KGD_ERR_NOMEM; }
                    *out_count = (int)arr.v.count;
                    for (size_t j = 0; j < arr.v.count; j++) {
                        mpval m = mp_read(&rd);
                        if (m.type != MP_MAP) { mp_skip(&rd); continue; }
                        for (size_t k = 0; k < m.v.count; k++) {
                            mpval mk = mp_read(&rd);
                            if (mk.type != MP_STR) { mp_skip(&rd); continue; }
                            if (mk.v.str.len == 12 && memcmp(mk.v.str.ptr, "placement_id", 12) == 0) {
                                mp_read_uint32(&rd, &(*out)[j].placement_id);
                            } else if (mk.v.str.len == 9 && memcmp(mk.v.str.ptr, "client_id", 9) == 0) {
                                mpval sv = mp_read(&rd);
                                if (sv.type == MP_STR) {
                                    size_t n = sv.v.str.len < 63 ? sv.v.str.len : 63;
                                    memcpy((*out)[j].client_id, sv.v.str.ptr, n);
                                }
                            } else if (mk.v.str.len == 6 && memcmp(mk.v.str.ptr, "handle", 6) == 0) {
                                mp_read_uint32(&rd, &(*out)[j].handle);
                            } else if (mk.v.str.len == 7 && memcmp(mk.v.str.ptr, "visible", 7) == 0) {
                                mpval bv = mp_read(&rd);
                                if (bv.type == MP_BOOL) (*out)[j].visible = bv.v.b;
                            } else if (mk.v.str.len == 3 && memcmp(mk.v.str.ptr, "row", 3) == 0) {
                                mp_read_int(&rd, &(*out)[j].row);
                            } else if (mk.v.str.len == 3 && memcmp(mk.v.str.ptr, "col", 3) == 0) {
                                mp_read_int(&rd, &(*out)[j].col);
                            } else {
                                mp_skip(&rd);
                            }
                        }
                    }
                }
            } else {
                mp_skip(&rd);
            }
        }
    }
    free(resp);
    return KGD_OK;
}

void kgd_free_list(kgd_placement_info *list) {
    free(list);
}

kgd_error kgd_status(kgd_client *c, kgd_status_result *out) {
    mpbuf b;
    mp_init(&b);
    uint32_t msgid = c->next_id++;
    mp_array(&b, 4);
    mp_int(&b, 0);
    mp_uint32(&b, msgid);
    mp_str(&b, "status");
    mp_array(&b, 0);

    uint8_t *resp = NULL;
    size_t resplen = 0;
    kgd_error err = do_call(c, b.buf, b.len, msgid, &resp, &resplen);
    mp_free(&b);
    if (err != KGD_OK) return err;

    memset(out, 0, sizeof(*out));
    mpreader rd = { .buf = resp, .len = resplen, .pos = 0 };
    mpval v = mp_read(&rd);
    if (v.type == MP_MAP) {
        for (size_t i = 0; i < v.v.count; i++) {
            mpval key = mp_read(&rd);
            if (key.type != MP_STR) { mp_skip(&rd); continue; }
            if (key.v.str.len == 7 && memcmp(key.v.str.ptr, "clients", 7) == 0) {
                mp_read_int(&rd, &out->clients);
            } else if (key.v.str.len == 10 && memcmp(key.v.str.ptr, "placements", 10) == 0) {
                mp_read_int(&rd, &out->placements);
            } else if (key.v.str.len == 6 && memcmp(key.v.str.ptr, "images", 6) == 0) {
                mp_read_int(&rd, &out->images);
            } else if (key.v.str.len == 4 && memcmp(key.v.str.ptr, "cols", 4) == 0) {
                mp_read_int(&rd, &out->cols);
            } else if (key.v.str.len == 4 && memcmp(key.v.str.ptr, "rows", 4) == 0) {
                mp_read_int(&rd, &out->rows);
            } else {
                mp_skip(&rd);
            }
        }
    }
    free(resp);
    return KGD_OK;
}

kgd_error kgd_stop(kgd_client *c) {
    mpbuf b;
    mp_init(&b);
    mp_array(&b, 3);
    mp_int(&b, 2);
    mp_str(&b, "stop");
    mp_array(&b, 0);

    pthread_mutex_lock(&c->write_lock);
    kgd_error err = send_all(c, b.buf, b.len);
    pthread_mutex_unlock(&c->write_lock);
    mp_free(&b);
    return err;
}

void kgd_close(kgd_client *c) {
    if (!c) return;
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
    c->evicted_cb = cb; c->evicted_ud = ud;
}

void kgd_set_topology_cb(kgd_client *c, kgd_topology_cb cb, void *ud) {
    c->topology_cb = cb; c->topology_ud = ud;
}

void kgd_set_visibility_cb(kgd_client *c, kgd_visibility_cb cb, void *ud) {
    c->visibility_cb = cb; c->visibility_ud = ud;
}

void kgd_set_theme_cb(kgd_client *c, kgd_theme_cb cb, void *ud) {
    c->theme_cb = cb; c->theme_ud = ud;
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

static kgd_error do_call(kgd_client *c, const uint8_t *req, size_t reqlen,
                         uint32_t msgid, uint8_t **out, size_t *outlen) {
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

/* Process a complete msgpack response/notification from the read buffer. */
static void process_message(kgd_client *c, mpreader *rd) {
    mpval arr = mp_read(rd);
    if (arr.type != MP_ARRAY || arr.v.count < 3) return;

    mpval mtype = mp_read(rd);
    if (mtype.type != MP_UINT && mtype.type != MP_INT) return;
    int msgtype = (int)(mtype.type == MP_UINT ? (int64_t)mtype.v.u : mtype.v.i);

    if (msgtype == 1) { /* response: [1, msgid, error, result] */
        uint32_t msgid;
        if (mp_read_uint32(rd, &msgid) != 0) return;

        /* Read error field */
        size_t err_start = rd->pos;
        mpval errv = mp_read(rd);
        int has_rpc_error = (errv.type != MP_NIL);

        if (has_rpc_error && errv.type == MP_MAP) {
            /* Try to extract error message for set_error */
            mpreader sub = { .buf = rd->buf + err_start, .len = rd->pos - err_start, .pos = 0 };
            mpval em = mp_read(&sub);
            if (em.type == MP_MAP) {
                for (size_t i = 0; i < em.v.count; i++) {
                    mpval ek = mp_read(&sub);
                    if (ek.type == MP_STR && ek.v.str.len == 7 &&
                        memcmp(ek.v.str.ptr, "message", 7) == 0) {
                        mpval ev = mp_read(&sub);
                        if (ev.type == MP_STR) {
                            size_t n = ev.v.str.len < 255 ? ev.v.str.len : 255;
                            char tmp[256];
                            memcpy(tmp, ev.v.str.ptr, n);
                            tmp[n] = 0;
                            set_error("%s", tmp);
                        }
                    } else {
                        mp_skip(&sub);
                    }
                }
            }
        }

        /* Read result field */
        size_t result_start = rd->pos;
        mp_skip(rd); /* skip to find end position */
        size_t result_len = rd->pos - result_start;

        int slot = (int)(msgid % MAX_PENDING);
        pending_entry *pe = &c->pending[slot];

        pthread_mutex_lock(&pe->mtx);
        if (pe->active) {
            pe->has_error = has_rpc_error;
            if (!has_rpc_error && result_len > 0) {
                pe->data = malloc(result_len);
                if (pe->data) {
                    memcpy(pe->data, rd->buf + result_start, result_len);
                    pe->len = result_len;
                }
            }
            pe->done = 1;
            pthread_cond_signal(&pe->cond);
        }
        pthread_mutex_unlock(&pe->mtx);
    } else if (msgtype == 2) { /* notification: [2, method, [params]] */
        mpval method = mp_read(rd);
        if (method.type != MP_STR) return;

        mpval params_arr = mp_read(rd);
        if (params_arr.type != MP_ARRAY || params_arr.v.count == 0) return;

        mpval params = mp_read(rd);
        if (params.type != MP_MAP) return;

        if (method.v.str.len == 7 && memcmp(method.v.str.ptr, "evicted", 7) == 0 &&
            c->evicted_cb) {
            uint32_t handle = 0;
            for (size_t i = 0; i < params.v.count; i++) {
                mpval k = mp_read(rd);
                if (k.type == MP_STR && k.v.str.len == 6 &&
                    memcmp(k.v.str.ptr, "handle", 6) == 0) {
                    mp_read_uint32(rd, &handle);
                } else {
                    mp_skip(rd);
                }
            }
            c->evicted_cb(handle, c->evicted_ud);
        } else if (method.v.str.len == 16 &&
                   memcmp(method.v.str.ptr, "topology_changed", 16) == 0 &&
                   c->topology_cb) {
            int cols = 0, rows = 0, cw = 0, ch = 0;
            for (size_t i = 0; i < params.v.count; i++) {
                mpval k = mp_read(rd);
                if (k.type != MP_STR) { mp_skip(rd); continue; }
                if (k.v.str.len == 4 && memcmp(k.v.str.ptr, "cols", 4) == 0) mp_read_int(rd, &cols);
                else if (k.v.str.len == 4 && memcmp(k.v.str.ptr, "rows", 4) == 0) mp_read_int(rd, &rows);
                else if (k.v.str.len == 10 && memcmp(k.v.str.ptr, "cell_width", 10) == 0) mp_read_int(rd, &cw);
                else if (k.v.str.len == 11 && memcmp(k.v.str.ptr, "cell_height", 11) == 0) mp_read_int(rd, &ch);
                else mp_skip(rd);
            }
            c->topology_cb(cols, rows, cw, ch, c->topology_ud);
        } else if (method.v.str.len == 18 &&
                   memcmp(method.v.str.ptr, "visibility_changed", 18) == 0 &&
                   c->visibility_cb) {
            uint32_t pid = 0;
            int visible = 0;
            for (size_t i = 0; i < params.v.count; i++) {
                mpval k = mp_read(rd);
                if (k.type != MP_STR) { mp_skip(rd); continue; }
                if (k.v.str.len == 12 && memcmp(k.v.str.ptr, "placement_id", 12) == 0) mp_read_uint32(rd, &pid);
                else if (k.v.str.len == 7 && memcmp(k.v.str.ptr, "visible", 7) == 0) {
                    mpval bv = mp_read(rd);
                    if (bv.type == MP_BOOL) visible = bv.v.b;
                }
                else mp_skip(rd);
            }
            c->visibility_cb(pid, visible, c->visibility_ud);
        } else if (method.v.str.len == 13 &&
                   memcmp(method.v.str.ptr, "theme_changed", 13) == 0 &&
                   c->theme_cb) {
            kgd_color fg = {0}, bg = {0};
            for (size_t i = 0; i < params.v.count; i++) {
                mpval k = mp_read(rd);
                if (k.type != MP_STR) { mp_skip(rd); continue; }
                kgd_color *target = NULL;
                if (k.v.str.len == 2 && memcmp(k.v.str.ptr, "fg", 2) == 0) target = &fg;
                else if (k.v.str.len == 2 && memcmp(k.v.str.ptr, "bg", 2) == 0) target = &bg;
                if (target) {
                    mpval cm = mp_read(rd);
                    if (cm.type == MP_MAP) {
                        for (size_t j = 0; j < cm.v.count; j++) {
                            mpval ck = mp_read(rd);
                            int val = 0;
                            mp_read_int(rd, &val);
                            if (ck.type == MP_STR && ck.v.str.len == 1) {
                                if (ck.v.str.ptr[0] == 'r') target->r = (uint16_t)val;
                                else if (ck.v.str.ptr[0] == 'g') target->g = (uint16_t)val;
                                else if (ck.v.str.ptr[0] == 'b') target->b = (uint16_t)val;
                            }
                        }
                    }
                } else {
                    mp_skip(rd);
                }
            }
            c->theme_cb(fg, bg, c->theme_ud);
        } else {
            /* Skip unknown notification params */
            for (size_t i = 0; i < params.v.count; i++) {
                mp_skip(rd); mp_skip(rd);
            }
        }
    }
}

static void *reader_thread(void *arg) {
    kgd_client *c = (kgd_client *)arg;
    uint8_t tmp[RECV_BUF_SIZE];

    while (!c->closed) {
        ssize_t n = read(c->fd, tmp, sizeof(tmp));
        if (n <= 0) break;

        /* Grow recv buffer if needed */
        size_t need = c->recv_len + (size_t)n;
        if (need > c->recv_cap) {
            size_t newcap = c->recv_cap ? c->recv_cap * 2 : RECV_BUF_SIZE;
            while (newcap < need) newcap *= 2;
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

        /* Try to decode complete messages */
        while (c->recv_len > 0) {
            mpreader rd = { .buf = c->recv_buf, .len = c->recv_len, .pos = 0 };
            size_t start = rd.pos;
            /* Try to read one complete message */
            if (mp_skip(&rd) != 0) break; /* incomplete */
            size_t msg_end = rd.pos;

            /* Process the complete message */
            mpreader msg_rd = { .buf = c->recv_buf + start, .len = msg_end - start, .pos = 0 };
            process_message(c, &msg_rd);

            /* Remove processed bytes */
            size_t remaining = c->recv_len - msg_end;
            if (remaining > 0) {
                memmove(c->recv_buf, c->recv_buf + msg_end, remaining);
            }
            c->recv_len = remaining;
        }
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
