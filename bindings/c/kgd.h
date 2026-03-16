/*
 * kgd.h — C client for kgd (Kitty Graphics Daemon)
 *
 * Stable ABI, FFI-friendly. All functions are thread-safe except where noted.
 *
 * Usage:
 *   kgd_client *c = kgd_connect(NULL);  // uses $KGD_SOCKET
 *   uint32_t handle;
 *   kgd_upload(c, data, len, "png", w, h, &handle);
 *   kgd_anchor anchor = { .type = KGD_ANCHOR_ABSOLUTE, .row = 5, .col = 10 };
 *   uint32_t pid;
 *   kgd_place(c, handle, &anchor, 20, 15, NULL, &pid);
 *   kgd_unplace(c, pid);
 *   kgd_free_handle(c, handle);
 *   kgd_close(c);
 */

#ifndef KGD_H
#define KGD_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque client handle */
typedef struct kgd_client kgd_client;

/* Error codes */
typedef enum {
    KGD_OK = 0,
    KGD_ERR_CONNECT = -1,
    KGD_ERR_HELLO = -2,
    KGD_ERR_SEND = -3,
    KGD_ERR_RECV = -4,
    KGD_ERR_DECODE = -5,
    KGD_ERR_RPC = -6,
    KGD_ERR_TIMEOUT = -7,
    KGD_ERR_NOMEM = -8,
} kgd_error;

/* Anchor types */
typedef enum {
    KGD_ANCHOR_ABSOLUTE = 0,
    KGD_ANCHOR_PANE = 1,
    KGD_ANCHOR_NVIM_WIN = 2,
} kgd_anchor_type;

/* RGB color (16-bit per channel) */
typedef struct {
    uint16_t r, g, b;
} kgd_color;

/* Logical position for a placement */
typedef struct {
    kgd_anchor_type type;
    const char *pane_id;  /* for KGD_ANCHOR_PANE */
    int win_id;           /* for KGD_ANCHOR_NVIM_WIN */
    int buf_line;         /* for KGD_ANCHOR_NVIM_WIN */
    int row;
    int col;
} kgd_anchor;

/* Optional placement parameters */
typedef struct {
    int src_x, src_y, src_w, src_h;
    int32_t z_index;
} kgd_place_opts;

/* Connection options */
typedef struct {
    const char *socket_path;  /* NULL = use $KGD_SOCKET */
    const char *session_id;   /* NULL = stateful mode */
    const char *client_type;  /* e.g. "myapp" */
    const char *label;        /* human-readable label */
} kgd_options;

/* Hello result (populated after connect) */
typedef struct {
    char client_id[64];
    int cols, rows;
    int cell_width, cell_height;
    int in_tmux;
    kgd_color fg, bg;
} kgd_hello_result;

/* Placement info (from list) */
typedef struct {
    uint32_t placement_id;
    char client_id[64];
    uint32_t handle;
    int visible;
    int row, col;
} kgd_placement_info;

/* Status result */
typedef struct {
    int clients;
    int placements;
    int images;
    int cols, rows;
} kgd_status_result;

/* Notification callbacks */
typedef void (*kgd_evicted_cb)(uint32_t handle, void *userdata);
typedef void (*kgd_topology_cb)(int cols, int rows, int cell_w, int cell_h, void *userdata);
typedef void (*kgd_visibility_cb)(uint32_t placement_id, int visible, void *userdata);
typedef void (*kgd_theme_cb)(kgd_color fg, kgd_color bg, void *userdata);

/*
 * Connect to the kgd daemon. Pass NULL for default options.
 * Returns NULL on failure; call kgd_last_error() for details.
 */
kgd_client *kgd_connect(const kgd_options *opts);

/* Get hello result from the connection. */
const kgd_hello_result *kgd_get_hello(const kgd_client *c);

/* Upload image data. Returns handle via out_handle. */
kgd_error kgd_upload(kgd_client *c, const void *data, size_t len,
                     const char *format, int width, int height,
                     uint32_t *out_handle);

/* Place an image. opts may be NULL. Returns placement ID via out_id. */
kgd_error kgd_place(kgd_client *c, uint32_t handle, const kgd_anchor *anchor,
                    int width, int height, const kgd_place_opts *opts,
                    uint32_t *out_id);

/* Remove a placement. */
kgd_error kgd_unplace(kgd_client *c, uint32_t placement_id);

/* Remove all placements for this client. */
kgd_error kgd_unplace_all(kgd_client *c);

/* Release an uploaded image handle. */
kgd_error kgd_free_handle(kgd_client *c, uint32_t handle);

/* Register a neovim window. */
kgd_error kgd_register_win(kgd_client *c, int win_id, const char *pane_id,
                           int top, int left, int width, int height,
                           int scroll_top);

/* Update scroll position. */
kgd_error kgd_update_scroll(kgd_client *c, int win_id, int scroll_top);

/* Unregister a neovim window. */
kgd_error kgd_unregister_win(kgd_client *c, int win_id);

/* Get active placements. Caller must free *out with kgd_free_list(). */
kgd_error kgd_list(kgd_client *c, kgd_placement_info **out, int *out_count);

/* Free memory returned by kgd_list(). */
void kgd_free_list(kgd_placement_info *list);

/* Get daemon status. */
kgd_error kgd_status(kgd_client *c, kgd_status_result *out);

/* Request daemon shutdown. */
kgd_error kgd_stop(kgd_client *c);

/* Close connection and free resources. */
void kgd_close(kgd_client *c);

/* Get last error message (thread-local). */
const char *kgd_last_error(void);

/* Set notification callbacks. Callbacks are invoked from the reader thread. */
void kgd_set_evicted_cb(kgd_client *c, kgd_evicted_cb cb, void *userdata);
void kgd_set_topology_cb(kgd_client *c, kgd_topology_cb cb, void *userdata);
void kgd_set_visibility_cb(kgd_client *c, kgd_visibility_cb cb, void *userdata);
void kgd_set_theme_cb(kgd_client *c, kgd_theme_cb cb, void *userdata);

#ifdef __cplusplus
}
#endif

#endif /* KGD_H */
