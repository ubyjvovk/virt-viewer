/*
 * vsm-spice.c: the GLib half of the native macOS SPICE viewer.
 *
 * See vsm-spice.h for the threading contract.  Nothing in this file touches
 * AppKit; the only main-thread interaction is dispatch_async() of the
 * VsmSpiceCallbacks.
 */
#include "vsm-spice.h"

#include <dispatch/dispatch.h>
#include <spice-client.h>
#include <string.h>

struct _VsmSpice {
    char               *uri;
    VsmSpiceCallbacks   cb;
    void               *user;

    GMainContext       *ctx;
    GMainLoop          *loop;
    GThread            *thread;

    /* GLib thread only. */
    SpiceSession       *session;
    SpiceMainChannel   *main_channel;
    SpiceDisplayChannel *display;
    SpiceInputsChannel *inputs;
    guint8             *fb;        /* guest primary surface buffer */
    int                 fb_stride;
    int                 fb_width;
    int                 fb_height;
    GHashTable         *pressed;   /* scancode -> held, for release-all */
    gboolean            stopping;

    /* Shared: surface handoff and damage coalescing. */
    GMutex              lock;
    IOSurfaceRef        surface;
    gboolean            damage_pending;
    int                 dx0, dy0, dx1, dy1;   /* union rect, half-open */
};

/* ---------------------------------------------------------------- helpers */

static void notify_status(VsmSpice *self, const char *fmt, ...) G_GNUC_PRINTF(2, 3);

static void notify_status(VsmSpice *self, const char *fmt, ...)
{
    va_list ap;
    char *text;

    va_start(ap, fmt);
    text = g_strdup_vprintf(fmt, ap);
    va_end(ap);

    g_message("%s", text);
    if (self->cb.status) {
        void (*status)(void *, const char *) = self->cb.status;
        void *user = self->user;
        dispatch_async(dispatch_get_main_queue(), ^{
            status(user, text);
            g_free(text);
        });
    } else {
        g_free(text);
    }
}

/* ------------------------------------------------------------- rendering */

/* Copy the damaged rows out of the guest buffer into the IOSurface.  Runs on
 * the GLib thread, which is the thread that owns @fb, so no tearing against
 * the decoder.  Only the damaged rectangle is touched -- this is what makes
 * the update damage-driven rather than a full-frame repaint. */
static void blit_damage(VsmSpice *self, int x, int y, int w, int h)
{
    IOSurfaceRef surface;
    guint8 *dst;
    size_t dst_stride;
    int row;

    g_mutex_lock(&self->lock);
    surface = self->surface ? (IOSurfaceRef)CFRetain(self->surface) : NULL;
    g_mutex_unlock(&self->lock);

    if (!surface || !self->fb)
        return;

    /* Clamp: the server is trusted but a damage rect outside the surface
     * would be an out-of-bounds write. */
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > self->fb_width)  w = self->fb_width - x;
    if (y + h > self->fb_height) h = self->fb_height - y;
    if (w <= 0 || h <= 0) {
        CFRelease(surface);
        return;
    }

    IOSurfaceLock(surface, 0, NULL);
    dst = IOSurfaceGetBaseAddress(surface);
    dst_stride = IOSurfaceGetBytesPerRow(surface);
    for (row = 0; row < h; row++) {
        memcpy(dst + (size_t)(y + row) * dst_stride + (size_t)x * 4,
               self->fb + (size_t)(y + row) * self->fb_stride + (size_t)x * 4,
               (size_t)w * 4);
    }
    IOSurfaceUnlock(surface, 0, NULL);
    CFRelease(surface);

    /* Coalesce: at most one main-thread hop is in flight at a time, so a
     * burst of small damage rects costs one CA transaction, not fifty. */
    g_mutex_lock(&self->lock);
    if (self->damage_pending) {
        self->dx0 = MIN(self->dx0, x);
        self->dy0 = MIN(self->dy0, y);
        self->dx1 = MAX(self->dx1, x + w);
        self->dy1 = MAX(self->dy1, y + h);
        g_mutex_unlock(&self->lock);
        return;
    }
    self->damage_pending = TRUE;
    self->dx0 = x; self->dy0 = y; self->dx1 = x + w; self->dy1 = y + h;
    g_mutex_unlock(&self->lock);

    dispatch_async(dispatch_get_main_queue(), ^{
        int rx, ry, rw, rh;
        g_mutex_lock(&self->lock);
        rx = self->dx0; ry = self->dy0;
        rw = self->dx1 - self->dx0; rh = self->dy1 - self->dy0;
        self->damage_pending = FALSE;
        g_mutex_unlock(&self->lock);
        if (self->cb.damaged)
            self->cb.damaged(self->user, rx, ry, rw, rh);
    });
}

static void on_primary_create(SpiceDisplayChannel *channel G_GNUC_UNUSED,
                              gint format, gint width, gint height,
                              gint stride, gint shmid G_GNUC_UNUSED,
                              gpointer imgdata, gpointer data)
{
    VsmSpice *self = data;
    IOSurfaceRef old;
    IOSurfaceRef surface;

    if (format != SPICE_SURFACE_FMT_32_xRGB) {
        notify_status(self, "unsupported primary surface format %d "
                            "(only 32-bit xRGB is handled)", format);
        return;
    }

    self->fb = imgdata;
    self->fb_stride = stride;
    self->fb_width = width;
    self->fb_height = height;

    /* BGRA32 matches SPICE_SURFACE_FMT_32_xRGB byte-for-byte on
     * little-endian, so the per-damage blit is a plain memcpy. */
    {
        const void *keys[] = {
            kIOSurfaceWidth, kIOSurfaceHeight,
            kIOSurfaceBytesPerElement, kIOSurfacePixelFormat,
        };
        int32_t fmt = 'BGRA', bpe = 4;
        const void *values[4];
        CFDictionaryRef props;

        values[0] = CFNumberCreate(NULL, kCFNumberIntType, &width);
        values[1] = CFNumberCreate(NULL, kCFNumberIntType, &height);
        values[2] = CFNumberCreate(NULL, kCFNumberSInt32Type, &bpe);
        values[3] = CFNumberCreate(NULL, kCFNumberSInt32Type, &fmt);
        props = CFDictionaryCreate(NULL, keys, values, 4,
                                   &kCFTypeDictionaryKeyCallBacks,
                                   &kCFTypeDictionaryValueCallBacks);
        surface = IOSurfaceCreate(props);
        CFRelease(props);
        for (int i = 0; i < 4; i++)
            CFRelease(values[i]);
    }
    if (!surface) {
        notify_status(self, "IOSurfaceCreate failed for %dx%d", width, height);
        return;
    }

    g_mutex_lock(&self->lock);
    old = self->surface;
    self->surface = surface;
    self->damage_pending = FALSE;
    g_mutex_unlock(&self->lock);
    if (old)
        CFRelease(old);

    if (self->cb.primary_create) {
        void (*create)(void *, int, int) = self->cb.primary_create;
        void *user = self->user;
        dispatch_async(dispatch_get_main_queue(), ^{
            create(user, width, height);
        });
    }
    blit_damage(self, 0, 0, width, height);
}

static void on_primary_destroy(SpiceDisplayChannel *channel G_GNUC_UNUSED,
                               gpointer data)
{
    VsmSpice *self = data;
    self->fb = NULL;
}

static void on_invalidate(SpiceDisplayChannel *channel G_GNUC_UNUSED,
                          gint x, gint y, gint w, gint h, gpointer data)
{
    blit_damage(data, x, y, w, h);
}

/* --------------------------------------------------------------- session */

static void update_title(VsmSpice *self)
{
    gchar *name = NULL;
    char *title;

    if (self->session)
        g_object_get(self->session, "name", &name, NULL);
    title = (name && *name) ? g_strdup_printf("%s - %s", name, self->uri)
                            : g_strdup(self->uri);
    g_free(name);

    if (self->cb.title) {
        void (*cb)(void *, const char *) = self->cb.title;
        void *user = self->user;
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(user, title);
            g_free(title);
        });
    } else {
        g_free(title);
    }
}

static void on_mouse_mode(GObject *object, GParamSpec *pspec G_GNUC_UNUSED,
                          gpointer data)
{
    VsmSpice *self = data;
    gint mode = 0;

    g_object_get(object, "mouse-mode", &mode, NULL);
    if (mode == SPICE_MOUSE_MODE_SERVER) {
        /* Milestone 1 is absolute-only; relative/server mode is logged and
         * ignored rather than half-implemented. */
        notify_status(self, "guest requested server (relative) mouse mode - "
                            "ignored, this build is absolute-mode only");
    } else {
        notify_status(self, "mouse mode: client (absolute)");
    }
}

static void on_channel_event(SpiceChannel *channel G_GNUC_UNUSED,
                             SpiceChannelEvent event, gpointer data)
{
    VsmSpice *self = data;
    const char *reason = NULL;

    switch (event) {
    case SPICE_CHANNEL_OPENED:
        notify_status(self, "main channel opened");
        return;
    case SPICE_CHANNEL_CLOSED:
        reason = "connection closed by peer";
        break;
    case SPICE_CHANNEL_ERROR_CONNECT:
        reason = "connection failed";
        break;
    case SPICE_CHANNEL_ERROR_TLS:
        reason = "TLS error";
        break;
    case SPICE_CHANNEL_ERROR_AUTH:
        reason = "authentication failed";
        break;
    case SPICE_CHANNEL_ERROR_IO:
        reason = "I/O error";
        break;
    default:
        reason = "channel error";
        break;
    }

    if (self->stopping)
        return;
    if (self->cb.disconnected) {
        void (*cb)(void *, const char *) = self->cb.disconnected;
        void *user = self->user;
        char *copy = g_strdup(reason);
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(user, copy);
            g_free(copy);
        });
    }
}

static void on_channel_new(SpiceSession *session G_GNUC_UNUSED,
                           SpiceChannel *channel, gpointer data)
{
    VsmSpice *self = data;
    gint id = 0;

    g_object_get(channel, "channel-id", &id, NULL);
    notify_status(self, "channel-new: %s id %d",
                  g_type_name_from_instance((GTypeInstance *)channel), id);

    if (SPICE_IS_MAIN_CHANNEL(channel)) {
        self->main_channel = SPICE_MAIN_CHANNEL(channel);
        g_signal_connect(channel, "channel-event",
                         G_CALLBACK(on_channel_event), self);
        g_signal_connect(channel, "notify::mouse-mode",
                         G_CALLBACK(on_mouse_mode), self);
        return;
    }

    if (SPICE_IS_DISPLAY_CHANNEL(channel) && id == 0) {
        self->display = SPICE_DISPLAY_CHANNEL(channel);
        g_signal_connect(channel, "display-primary-create",
                         G_CALLBACK(on_primary_create), self);
        g_signal_connect(channel, "display-primary-destroy",
                         G_CALLBACK(on_primary_destroy), self);
        g_signal_connect(channel, "display-invalidate",
                         G_CALLBACK(on_invalidate), self);
        spice_channel_connect(channel);
        update_title(self);
        return;
    }

    if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        self->inputs = SPICE_INPUTS_CHANNEL(channel);
        spice_channel_connect(channel);
        notify_status(self, "inputs channel ready");
        return;
    }

    /* Everything else (cursor, cursor-less playback, record, usbredir,
     * webdav, smartcard) is deliberately left unconnected: milestone 1 is
     * screen + keyboard + mouse only. */
}

static void on_channel_destroy(SpiceSession *session G_GNUC_UNUSED,
                               SpiceChannel *channel, gpointer data)
{
    VsmSpice *self = data;

    if (SPICE_CHANNEL(self->display) == channel)
        self->display = NULL;
    else if (SPICE_CHANNEL(self->inputs) == channel)
        self->inputs = NULL;
    else if (SPICE_CHANNEL(self->main_channel) == channel)
        self->main_channel = NULL;
}

static gpointer spice_thread(gpointer data)
{
    VsmSpice *self = data;

    /* Take ownership of the default context on this thread for the lifetime
     * of the loop; g_main_loop_run() acquires it for us. */
    self->session = spice_session_new();
    /* Milestone 1 is screen + keyboard + mouse.  Turning audio and usbredir
     * off at the session keeps spice-gtk from constructing those channels at
     * all -- otherwise it spins up GStreamer and libusb for pipelines this
     * client never reads. */
    g_object_set(self->session,
                 "uri", self->uri,
                 "enable-audio", FALSE,
                 "enable-usbredir", FALSE,
                 NULL);
    g_signal_connect(self->session, "channel-new",
                     G_CALLBACK(on_channel_new), self);
    g_signal_connect(self->session, "channel-destroy",
                     G_CALLBACK(on_channel_destroy), self);

    notify_status(self, "connecting to %s", self->uri);
    if (!spice_session_connect(self->session))
        notify_status(self, "spice_session_connect() refused the URI");

    g_main_loop_run(self->loop);

    g_clear_object(&self->session);
    return NULL;
}

/* ----------------------------------------------------------------- input */

/* Every input entry point packs its arguments here and hands the struct to
 * g_main_context_invoke_full() on the GLib context. */
typedef struct {
    VsmSpice *self;
    int a, b, c, d;
} InputOp;

static InputOp *input_op(VsmSpice *self, int a, int b, int c, int d)
{
    InputOp *op = g_new0(InputOp, 1);
    op->self = self;
    op->a = a; op->b = b; op->c = c; op->d = d;
    return op;
}

static gboolean do_key(gpointer data)
{
    InputOp *op = data;
    VsmSpice *self = op->self;
    guint scancode = (guint)op->a;

    if (!self->inputs)
        return G_SOURCE_REMOVE;

    if (op->b) {
        spice_inputs_channel_key_press(self->inputs, scancode);
        g_hash_table_add(self->pressed, GUINT_TO_POINTER(scancode));
    } else {
        spice_inputs_channel_key_release(self->inputs, scancode);
        g_hash_table_remove(self->pressed, GUINT_TO_POINTER(scancode));
    }
    return G_SOURCE_REMOVE;
}

/* GLib thread only. */
static void release_all_keys(VsmSpice *self)
{
    GHashTableIter iter;
    gpointer key;

    if (self->inputs) {
        g_hash_table_iter_init(&iter, self->pressed);
        while (g_hash_table_iter_next(&iter, &key, NULL))
            spice_inputs_channel_key_release(self->inputs, GPOINTER_TO_UINT(key));
    }
    g_hash_table_remove_all(self->pressed);
}

static gboolean do_release_all(gpointer data)
{
    release_all_keys(((InputOp *)data)->self);
    return G_SOURCE_REMOVE;
}

static gboolean do_position(gpointer data)
{
    InputOp *op = data;
    if (op->self->inputs)
        spice_inputs_channel_position(op->self->inputs, op->a, op->b, 0, op->c);
    return G_SOURCE_REMOVE;
}

static gboolean do_button(gpointer data)
{
    InputOp *op = data;
    if (!op->self->inputs)
        return G_SOURCE_REMOVE;
    if (op->b)
        spice_inputs_channel_button_press(op->self->inputs, op->a, op->c);
    else
        spice_inputs_channel_button_release(op->self->inputs, op->a, op->c);
    return G_SOURCE_REMOVE;
}

static gboolean do_scroll(gpointer data)
{
    InputOp *op = data;
    int button = op->a > 0 ? SPICE_MOUSE_BUTTON_UP : SPICE_MOUSE_BUTTON_DOWN;
    int steps = ABS(op->a);

    if (!op->self->inputs)
        return G_SOURCE_REMOVE;
    for (int i = 0; i < steps; i++) {
        spice_inputs_channel_button_press(op->self->inputs, button, op->b);
        spice_inputs_channel_button_release(op->self->inputs, button, op->b);
    }
    return G_SOURCE_REMOVE;
}

static void invoke(VsmSpice *self, GSourceFunc fn, InputOp *op)
{
    g_main_context_invoke_full(self->ctx, G_PRIORITY_DEFAULT, fn, op, g_free);
}

void vsm_spice_send_key(VsmSpice *self, unsigned scancode, int down)
{
    if (!scancode)
        return;
    invoke(self, do_key, input_op(self, (int)scancode, down, 0, 0));
}

void vsm_spice_release_all_keys(VsmSpice *self)
{
    invoke(self, do_release_all, input_op(self, 0, 0, 0, 0));
}

void vsm_spice_send_position(VsmSpice *self, int x, int y, int button_state)
{
    invoke(self, do_position, input_op(self, x, y, button_state, 0));
}

void vsm_spice_send_button(VsmSpice *self, int button, int down, int button_state)
{
    invoke(self, do_button, input_op(self, button, down, button_state, 0));
}

void vsm_spice_send_scroll(VsmSpice *self, int steps, int button_state)
{
    if (!steps)
        return;
    invoke(self, do_scroll, input_op(self, steps, button_state, 0, 0));
}

/* ------------------------------------------------------------- lifecycle */

VsmSpice *vsm_spice_new(const char *uri, const VsmSpiceCallbacks *cb, void *user)
{
    VsmSpice *self = g_new0(VsmSpice, 1);

    self->uri = g_strdup(uri);
    self->cb = *cb;
    self->user = user;
    self->ctx = g_main_context_ref(g_main_context_default());
    self->loop = g_main_loop_new(self->ctx, FALSE);
    self->pressed = g_hash_table_new(g_direct_hash, g_direct_equal);
    g_mutex_init(&self->lock);
    return self;
}

void vsm_spice_start(VsmSpice *self)
{
    if (self->thread)
        return;
    self->thread = g_thread_new("vsm-spice", spice_thread, self);
}

static gboolean do_stop(gpointer data)
{
    VsmSpice *self = data;

    release_all_keys(self);
    if (self->session)
        spice_session_disconnect(self->session);
    g_main_loop_quit(self->loop);
    return G_SOURCE_REMOVE;
}

void vsm_spice_stop(VsmSpice *self)
{
    if (!self->thread)
        return;
    self->stopping = TRUE;
    g_main_context_invoke_full(self->ctx, G_PRIORITY_HIGH, do_stop, self, NULL);
    g_thread_join(self->thread);
    self->thread = NULL;
}

IOSurfaceRef vsm_spice_copy_surface(VsmSpice *self)
{
    IOSurfaceRef surface;

    g_mutex_lock(&self->lock);
    surface = self->surface ? (IOSurfaceRef)CFRetain(self->surface) : NULL;
    g_mutex_unlock(&self->lock);
    return surface;
}

void vsm_spice_free(VsmSpice *self)
{
    if (!self)
        return;
    vsm_spice_stop(self);
    if (self->surface)
        CFRelease(self->surface);
    g_hash_table_unref(self->pressed);
    g_main_loop_unref(self->loop);
    g_main_context_unref(self->ctx);
    g_mutex_clear(&self->lock);
    g_free(self->uri);
    g_free(self);
}
