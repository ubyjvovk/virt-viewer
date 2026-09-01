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
#include <spice/vd_agent.h>
#include <string.h>

struct _VsmSpice {
    char               *uri;
    char               *password;  /* set before start(), wiped on free() */
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
    SpiceCursorChannel *cursor;
    guint8             *fb;        /* guest primary surface buffer */
    int                 fb_stride;
    int                 fb_width;
    int                 fb_height;
    GHashTable         *pressed;   /* scancode -> held, for release-all */
    gboolean            stopping;
    gboolean            forced_relative;  /* VSM_FORCE_RELATIVE asked once */
    gboolean            agent_connected;  /* last state pushed to the host */
    gboolean            agent_reported;   /* the state above has been said out loud */
    guint               agent_probe_id;   /* one-shot "is there an agent?" timeout */

    /* Shared: surface handoff and damage coalescing. */
    GMutex              lock;
    IOSurfaceRef        surface;
    gboolean            damage_pending;
    int                 dx0, dy0, dx1, dy1;   /* union rect, half-open */
};

/* ---------------------------------------------------------------- helpers */

/* VSM_FORCE_RELATIVE=1: request server (relative) mouse mode at connect.
 * Inert unless the variable is exactly "1". */
static gboolean vsm_force_relative(void)
{
    const char *env = g_getenv("VSM_FORCE_RELATIVE");
    return env && *env == '1';
}

/* VSM_TRACE=1, read the same way main.m reads it. */
static gboolean vsm_spice_trace(void)
{
    const char *env = g_getenv("VSM_TRACE");
    return env && *env == '1';
}

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

/* ---------------------------------------------------------------- cursor */

/* The cursor channel hands us a shape it still owns, from the GLib thread.
 * Copy it here and let the main thread own the copy: by the time the block
 * runs, spice-client-glib may already have replaced or freed the original.
 * malloc() rather than g_malloc() because main.m free()s it and does not
 * link against GLib's allocator vocabulary. */
static void deliver_cursor_define(VsmSpice *self, int width, int height,
                                  int hot_x, int hot_y, const guint8 *rgba)
{
    void (*define)(void *, int, int, int, int, const uint8_t *) = self->cb.cursor_define;
    void *user = self->user;
    size_t size;
    uint8_t *copy;

    if (!define || width <= 0 || height <= 0 || !rgba)
        return;

    size = (size_t)width * (size_t)height * 4;
    copy = malloc(size);
    if (!copy) {
        notify_status(self, "out of memory for a %dx%d cursor shape", width, height);
        return;
    }
    memcpy(copy, rgba, size);

    dispatch_async(dispatch_get_main_queue(), ^{
        define(user, width, height, hot_x, hot_y, copy);
    });
}

/* notify::cursor rather than the ::cursor-set signal: the latter is
 * deprecated since spice-gtk 0.34 and carries the same payload. */
static void on_cursor_notify(GObject *object, GParamSpec *pspec G_GNUC_UNUSED,
                             gpointer data)
{
    VsmSpice *self = data;
    SpiceCursorShape *shape = NULL;

    g_object_get(object, "cursor", &shape, NULL);
    if (!shape)
        return;
    if (shape->data)
        deliver_cursor_define(self, shape->width, shape->height,
                              shape->hot_spot_x, shape->hot_spot_y,
                              shape->data);
    g_boxed_free(SPICE_TYPE_CURSOR_SHAPE, shape);
}

static void on_cursor_hide(SpiceCursorChannel *channel G_GNUC_UNUSED,
                           gpointer data)
{
    VsmSpice *self = data;
    void (*hide)(void *) = self->cb.cursor_hide;
    void *user = self->user;

    if (!hide)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{ hide(user); });
}

static void on_cursor_reset(SpiceCursorChannel *channel G_GNUC_UNUSED,
                            gpointer data)
{
    VsmSpice *self = data;
    void (*reset)(void *) = self->cb.cursor_reset;
    void *user = self->user;

    if (!reset)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{ reset(user); });
}

/* ------------------------------------------------------------- clipboard */

/* Plain UTF-8 text on the CLIPBOARD selection, nothing else: no PRIMARY (the
 * macOS pasteboard has no equivalent) and no images or file lists.  Every
 * handler below runs on the GLib thread and only marshals to the main thread;
 * the reverse direction is the vsm_spice_clipboard_* entry points at the
 * bottom of the file.  Nothing here ever logs clipboard CONTENTS -- the trace
 * carries the direction, the type and a byte count.
 *
 * The whole feature is inert without a guest agent: the server drops agent
 * messages on the floor when spice-vdagent is not running, so the host side
 * is told through the clipboard_agent callback and stops polling instead of
 * shouting into a void. */
static const guint VSM_CLIPBOARD_SELECTION = VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD;

/* GLib thread only. */
static void notify_agent(VsmSpice *self, gboolean connected)
{
    if (self->agent_reported && self->agent_connected == connected)
        return;
    self->agent_connected = connected;
    self->agent_reported = TRUE;
    notify_status(self, "guest agent %s: clipboard %s",
                  connected ? "connected (clipboard capable)" : "absent",
                  connected ? "enabled" : "disabled");
    if (self->cb.clipboard_agent) {
        void (*cb)(void *, int) = self->cb.clipboard_agent;
        void *user = self->user;
        int on = connected ? 1 : 0;
        dispatch_async(dispatch_get_main_queue(), ^{ cb(user, on); });
    }
}

/* "Is there an agent this client can exchange a clipboard with?"  Two things
 * have to be true, and they become true at different moments: the agent has
 * to be connected, and it has to have announced CLIPBOARD_BY_DEMAND -- the
 * capability behind the whole grab/request/notify handshake.  Grabbing before
 * the capability set arrives trips a g_return_if_fail inside spice-client-glib
 * (GSpice-CRITICAL agent_clipboard_grab), so the host side is told the agent
 * is there only once BOTH hold. */
static gboolean agent_clipboard_ready(VsmSpice *self)
{
    gboolean connected = FALSE;

    if (!self->main_channel)
        return FALSE;
    g_object_get(self->main_channel, "agent-connected", &connected, NULL);
    return connected &&
        spice_main_channel_agent_test_capability(self->main_channel,
                                                 VD_AGENT_CAP_CLIPBOARD_BY_DEMAND);
}

/* Both "agent-connected" and "agent-caps-0" land here; either can be the one
 * that completes the pair. */
static void on_agent_notify(GObject *object G_GNUC_UNUSED,
                            GParamSpec *pspec G_GNUC_UNUSED, gpointer data)
{
    VsmSpice *self = data;
    gboolean ready = agent_clipboard_ready(self);

    /* "agent-connected" goes true a beat before the capabilities arrive, so
     * the first notify of a perfectly healthy agent reads as not-ready.
     * Announcing an absent agent on that beat would put a retracted "no
     * agent" line in every log; the absence is announced once, by the probe
     * timeout, and only for a guest that really has none. */
    if (!ready && !self->agent_reported)
        return;
    notify_agent(self, ready);
}

/* A guest WITH an agent announces it in the main channel's init message and
 * the notify above fires; a guest without one says nothing at all, and
 * silence is exactly the state the host side has to be told about so it can
 * skip the pasteboard poll.  So the state is read out once, shortly after the
 * main channel opens, and reported whatever it is.  The id is kept so a
 * session torn down inside the window cancels it. */
static gboolean probe_agent(gpointer data)
{
    VsmSpice *self = data;

    self->agent_probe_id = 0;
    if (self->main_channel)
        notify_agent(self, agent_clipboard_ready(self));
    return G_SOURCE_REMOVE;
}

/* How long to give the guest agent to announce itself before declaring it
 * absent.  The announcement rides the main channel's init message, so this is
 * a generous margin rather than a guess at a negotiation. */
#define VSM_AGENT_PROBE_MS 1500

/* The guest took its clipboard.  @types is the list of formats it offers;
 * this client answers for UTF-8 text and ignores every other offer, which is
 * also why TRUE (handled) is only returned when text is on the list. */
static gboolean on_clipboard_grab(SpiceMainChannel *channel G_GNUC_UNUSED,
                                  guint selection, guint32 *types, guint ntypes,
                                  gpointer data)
{
    VsmSpice *self = data;
    guint i;

    if (selection != VSM_CLIPBOARD_SELECTION)
        return FALSE;
    for (i = 0; i < ntypes; i++)
        if (types[i] == VD_AGENT_CLIPBOARD_UTF8_TEXT)
            break;
    if (i == ntypes) {
        if (vsm_spice_trace())
            g_message("clipboard: guest grab with no UTF8 type (%u offered)",
                      ntypes);
        return FALSE;
    }

    if (vsm_spice_trace())
        g_message("clipboard: guest grab, UTF8 text offered");
    if (self->cb.clipboard_grab) {
        void (*cb)(void *) = self->cb.clipboard_grab;
        void *user = self->user;
        dispatch_async(dispatch_get_main_queue(), ^{ cb(user); });
    }
    return TRUE;
}

static void on_clipboard_release(SpiceMainChannel *channel G_GNUC_UNUSED,
                                 guint selection, gpointer data)
{
    VsmSpice *self = data;

    if (selection != VSM_CLIPBOARD_SELECTION)
        return;
    if (vsm_spice_trace())
        g_message("clipboard: guest release");
    if (self->cb.clipboard_release) {
        void (*cb)(void *) = self->cb.clipboard_release;
        void *user = self->user;
        dispatch_async(dispatch_get_main_queue(), ^{ cb(user); });
    }
}

/* The bytes this client asked for.  spice-client-glib owns @data only for the
 * duration of the signal, and the agent does not promise a trailing NUL, so
 * the copy handed to the main thread is made here and NUL-terminated. */
static void on_clipboard_data(SpiceMainChannel *channel G_GNUC_UNUSED,
                              guint selection, guint type,
                              gpointer cdata, guint size, gpointer data)
{
    VsmSpice *self = data;
    char *text;

    if (selection != VSM_CLIPBOARD_SELECTION ||
        type != VD_AGENT_CLIPBOARD_UTF8_TEXT)
        return;
    if (!self->cb.clipboard_data)
        return;

    text = g_malloc(size + 1);
    if (size)
        memcpy(text, cdata, size);
    text[size] = '\0';
    if (vsm_spice_trace())
        g_message("clipboard: guest -> host, %u byte%s", size,
                  size == 1 ? "" : "s");
    {
        void (*cb)(void *, char *) = self->cb.clipboard_data;
        void *user = self->user;
        dispatch_async(dispatch_get_main_queue(), ^{ cb(user, text); });
    }
}

/* The guest asks for what this client offered.  Answering is the main
 * thread's job (only it may touch NSPasteboard), so the request is forwarded
 * and TRUE returned: the answer arrives asynchronously through
 * vsm_spice_clipboard_send(). */
static gboolean on_clipboard_request(SpiceMainChannel *channel G_GNUC_UNUSED,
                                     guint selection, guint type, gpointer data)
{
    VsmSpice *self = data;

    if (selection != VSM_CLIPBOARD_SELECTION ||
        type != VD_AGENT_CLIPBOARD_UTF8_TEXT)
        return FALSE;
    if (!self->cb.clipboard_request)
        return FALSE;

    if (vsm_spice_trace())
        g_message("clipboard: guest requested UTF8 text");
    {
        void (*cb)(void *) = self->cb.clipboard_request;
        void *user = self->user;
        dispatch_async(dispatch_get_main_queue(), ^{ cb(user); });
    }
    return TRUE;
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

/* GLib thread only.  The mode the server has actually put us in, pushed to
 * the main thread so the view can enter or leave its pointer grab. */
static void notify_mouse_mode(VsmSpice *self, gboolean relative)
{
    notify_status(self, "mouse mode: %s",
                  relative ? "server (relative) - grab the pointer to steer it"
                           : "client (absolute)");
    if (self->cb.mouse_mode) {
        void (*cb)(void *, int) = self->cb.mouse_mode;
        void *user = self->user;
        int rel = relative ? 1 : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(user, rel);
        });
    }
}

static void on_mouse_mode(GObject *object, GParamSpec *pspec G_GNUC_UNUSED,
                          gpointer data)
{
    VsmSpice *self = data;
    gint mode = 0;

    g_object_get(object, "mouse-mode", &mode, NULL);
    notify_mouse_mode(self, mode == SPICE_MOUSE_MODE_SERVER);

    /* Debug aid: most guests run an agent and therefore negotiate
     * client/absolute mode, which leaves the relative-mode code untestable
     * against a real server.  VSM_FORCE_RELATIVE=1 asks for server mode --
     * here, and not at channel-new, because the request is a message on the
     * main channel and there is nothing to send it down until the server has
     * announced a mode.  Asked once: if the server refuses, a retry on every
     * announcement would be a loop. */
    if (mode != SPICE_MOUSE_MODE_SERVER && vsm_force_relative() &&
        !self->forced_relative) {
        self->forced_relative = TRUE;
        notify_status(self, "VSM_FORCE_RELATIVE=1: requesting server "
                            "(relative) mouse mode");
        spice_main_channel_request_mouse_mode(self->main_channel,
                                              SPICE_MOUSE_MODE_SERVER);
    }
}

/* VSM_TRACE=1: log where the guest says its pointer now is. */
static void on_cursor_move(SpiceCursorChannel *channel G_GNUC_UNUSED,
                           gint x, gint y, gpointer data G_GNUC_UNUSED)
{
    if (vsm_spice_trace())
        g_message("cursor-move %d,%d", x, y);
}

static void on_channel_event(SpiceChannel *channel G_GNUC_UNUSED,
                             SpiceChannelEvent event, gpointer data)
{
    VsmSpice *self = data;
    const char *reason = NULL;
    int auth_failed = 0;

    switch (event) {
    case SPICE_CHANNEL_OPENED:
        notify_status(self, "main channel opened");
        if (!self->agent_probe_id && !self->agent_reported)
            self->agent_probe_id = g_timeout_add(VSM_AGENT_PROBE_MS,
                                                 probe_agent, self);
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
        auth_failed = 1;
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
        void (*cb)(void *, const char *, int) = self->cb.disconnected;
        void *user = self->user;
        char *copy = g_strdup(reason);
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(user, copy, auth_failed);
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
        g_signal_connect(channel, "notify::agent-connected",
                         G_CALLBACK(on_agent_notify), self);
        g_signal_connect(channel, "notify::agent-caps-0",
                         G_CALLBACK(on_agent_notify), self);
        g_signal_connect(channel, "main-clipboard-selection-grab",
                         G_CALLBACK(on_clipboard_grab), self);
        g_signal_connect(channel, "main-clipboard-selection-release",
                         G_CALLBACK(on_clipboard_release), self);
        g_signal_connect(channel, "main-clipboard-selection",
                         G_CALLBACK(on_clipboard_data), self);
        g_signal_connect(channel, "main-clipboard-selection-request",
                         G_CALLBACK(on_clipboard_request), self);
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

    if (SPICE_IS_CURSOR_CHANNEL(channel)) {
        if (id != 0)
            return;                   /* only the primary display's cursor */
        self->cursor = SPICE_CURSOR_CHANNEL(channel);
        g_signal_connect(channel, "notify::cursor",
                         G_CALLBACK(on_cursor_notify), self);
        g_signal_connect(channel, "cursor-hide",
                         G_CALLBACK(on_cursor_hide), self);
        g_signal_connect(channel, "cursor-reset",
                         G_CALLBACK(on_cursor_reset), self);
        /* Trace only.  In server/relative mode the guest's pointer position
         * is known to the client ONLY through this signal -- a guest that
         * puts its pointer on the cursor plane never draws it into the
         * framebuffer -- so it is the direct evidence that the deltas this
         * client sends are moving the guest pointer.  Rendering it is a
         * separate job; see the gap noted in README.md. */
        g_signal_connect(channel, "cursor-move",
                         G_CALLBACK(on_cursor_move), self);
        spice_channel_connect(channel);
        notify_status(self, "cursor channel ready");
        return;
    }

    if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        self->inputs = SPICE_INPUTS_CHANNEL(channel);
        spice_channel_connect(channel);
        notify_status(self, "inputs channel ready");
        return;
    }

    /* Everything else (playback, record, usbredir, webdav, smartcard) is
     * deliberately left unconnected: this build is screen, keyboard, mouse
     * and cursor shape only. */
}

static void on_channel_destroy(SpiceSession *session G_GNUC_UNUSED,
                               SpiceChannel *channel, gpointer data)
{
    VsmSpice *self = data;

    if (SPICE_CHANNEL(self->display) == channel)
        self->display = NULL;
    else if (SPICE_CHANNEL(self->inputs) == channel)
        self->inputs = NULL;
    else if (SPICE_CHANNEL(self->cursor) == channel)
        self->cursor = NULL;
    else if (SPICE_CHANNEL(self->main_channel) == channel) {
        self->main_channel = NULL;
        /* No main channel, no agent: tell the host side to stop polling
         * rather than leave it offering a clipboard nobody can collect. */
        notify_agent(self, FALSE);
    }
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
    /* Set separately so the property is left untouched (rather than
     * explicitly cleared) when no password was supplied -- a URI may carry
     * one of its own. */
    if (self->password)
        g_object_set(self->session, "password", self->password, NULL);
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
    guint released = 0;

    if (self->inputs) {
        g_hash_table_iter_init(&iter, self->pressed);
        while (g_hash_table_iter_next(&iter, &key, NULL)) {
            spice_inputs_channel_key_release(self->inputs, GPOINTER_TO_UINT(key));
            released++;
        }
    }
    /* Silent when there was nothing held -- this runs on every focus change.
     * When there was, saying so is the only evidence a caller (the escape
     * chord, hold-to-quit, losing focus mid-chord) has that the guest was
     * not left holding a modifier. */
    if (released)
        notify_status(self, "released %u held key%s", released,
                      released == 1 ? "" : "s");
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

static gboolean do_motion(gpointer data)
{
    InputOp *op = data;
    if (op->self->inputs)
        spice_inputs_channel_motion(op->self->inputs, op->a, op->b, op->c);
    return G_SOURCE_REMOVE;
}

static gboolean do_request_mouse_mode(gpointer data)
{
    InputOp *op = data;
    if (op->self->main_channel)
        spice_main_channel_request_mouse_mode(op->self->main_channel,
                                              op->a ? SPICE_MOUSE_MODE_SERVER
                                                    : SPICE_MOUSE_MODE_CLIENT);
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
    if (!self || !scancode)
        return;
    invoke(self, do_key, input_op(self, (int)scancode, down, 0, 0));
}

void vsm_spice_release_all_keys(VsmSpice *self)
{
    if (!self)
        return;
    invoke(self, do_release_all, input_op(self, 0, 0, 0, 0));
}

void vsm_spice_send_position(VsmSpice *self, int x, int y, int button_state)
{
    if (!self)
        return;
    invoke(self, do_position, input_op(self, x, y, button_state, 0));
}

void vsm_spice_send_motion(VsmSpice *self, int dx, int dy, int button_state)
{
    if (!self || (!dx && !dy))
        return;
    invoke(self, do_motion, input_op(self, dx, dy, button_state, 0));
}

void vsm_spice_request_mouse_mode(VsmSpice *self, int relative)
{
    if (!self)
        return;
    invoke(self, do_request_mouse_mode, input_op(self, relative, 0, 0, 0));
}

void vsm_spice_send_button(VsmSpice *self, int button, int down, int button_state)
{
    if (!self)
        return;
    invoke(self, do_button, input_op(self, button, down, button_state, 0));
}

void vsm_spice_send_scroll(VsmSpice *self, int steps, int button_state)
{
    if (!self || !steps)
        return;
    invoke(self, do_scroll, input_op(self, steps, button_state, 0, 0));
}

/* Clipboard sends.  These carry a payload rather than four ints, so they get
 * their own op struct; the destroy notify frees both halves whether or not
 * the source function ever ran. */
typedef struct {
    VsmSpice *self;
    guint8   *data;
    gsize     size;
} DataOp;

static void data_op_free(gpointer p)
{
    DataOp *op = p;

    g_free(op->data);
    g_free(op);
}

static gboolean do_clipboard_grab(gpointer data)
{
    VsmSpice *self = ((InputOp *)data)->self;
    guint32 types[] = { VD_AGENT_CLIPBOARD_UTF8_TEXT };

    if (self->main_channel && self->agent_connected)
        spice_main_channel_clipboard_selection_grab(self->main_channel,
                                                    VSM_CLIPBOARD_SELECTION,
                                                    types, G_N_ELEMENTS(types));
    return G_SOURCE_REMOVE;
}

static gboolean do_clipboard_release(gpointer data)
{
    VsmSpice *self = ((InputOp *)data)->self;

    if (self->main_channel && self->agent_connected)
        spice_main_channel_clipboard_selection_release(self->main_channel,
                                                       VSM_CLIPBOARD_SELECTION);
    return G_SOURCE_REMOVE;
}

static gboolean do_clipboard_request(gpointer data)
{
    VsmSpice *self = ((InputOp *)data)->self;

    if (self->main_channel && self->agent_connected)
        spice_main_channel_clipboard_selection_request(self->main_channel,
                                                       VSM_CLIPBOARD_SELECTION,
                                                       VD_AGENT_CLIPBOARD_UTF8_TEXT);
    return G_SOURCE_REMOVE;
}

static gboolean do_clipboard_send(gpointer data)
{
    DataOp *op = data;

    if (op->self->main_channel && op->self->agent_connected) {
        if (vsm_spice_trace())
            g_message("clipboard: host -> guest, %zu byte%s", op->size,
                      op->size == 1 ? "" : "s");
        spice_main_channel_clipboard_selection_notify(op->self->main_channel,
                                                      VSM_CLIPBOARD_SELECTION,
                                                      VD_AGENT_CLIPBOARD_UTF8_TEXT,
                                                      op->data, op->size);
    }
    return G_SOURCE_REMOVE;
}

void vsm_spice_clipboard_grab(VsmSpice *self)
{
    if (!self)
        return;
    invoke(self, do_clipboard_grab, input_op(self, 0, 0, 0, 0));
}

void vsm_spice_clipboard_release(VsmSpice *self)
{
    if (!self)
        return;
    invoke(self, do_clipboard_release, input_op(self, 0, 0, 0, 0));
}

void vsm_spice_clipboard_request(VsmSpice *self)
{
    if (!self)
        return;
    invoke(self, do_clipboard_request, input_op(self, 0, 0, 0, 0));
}

void vsm_spice_clipboard_send(VsmSpice *self, const char *utf8)
{
    DataOp *op;

    if (!self || !utf8 || !*utf8)
        return;
    op = g_new0(DataOp, 1);
    op->self = self;
    /* The agent's UTF8_TEXT payload is not NUL-terminated on the wire, so the
     * copy is exactly the text bytes. */
    op->size = strlen(utf8);
    op->data = (guint8 *)g_memdup2(utf8, op->size);
    g_main_context_invoke_full(self->ctx, G_PRIORITY_DEFAULT, do_clipboard_send,
                               op, data_op_free);
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

/* Overwrite the password copy before releasing it.  The writes go through a
 * volatile pointer so the compiler may not drop them as dead stores to memory
 * that is about to be freed. */
static void wipe_password(VsmSpice *self)
{
    volatile char *p = (volatile char *)self->password;

    if (!p)
        return;
    while (*p)
        *p++ = '\0';
    g_free(self->password);
    self->password = NULL;
}

void vsm_spice_set_password(VsmSpice *self, const char *password)
{
    if (!self)
        return;
    g_return_if_fail(self->thread == NULL);   /* start() already applied it */
    wipe_password(self);
    self->password = g_strdup(password);
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
    if (self->agent_probe_id) {
        g_source_remove(self->agent_probe_id);
        self->agent_probe_id = 0;
    }
    if (self->session)
        spice_session_disconnect(self->session);
    g_main_loop_quit(self->loop);
    return G_SOURCE_REMOVE;
}

void vsm_spice_stop(VsmSpice *self)
{
    if (!self || !self->thread)
        return;
    self->stopping = TRUE;
    g_main_context_invoke_full(self->ctx, G_PRIORITY_HIGH, do_stop, self, NULL);
    g_thread_join(self->thread);
    self->thread = NULL;
}

IOSurfaceRef vsm_spice_copy_surface(VsmSpice *self)
{
    IOSurfaceRef surface;

    if (!self)
        return NULL;
    g_mutex_lock(&self->lock);
    surface = self->surface ? (IOSurfaceRef)CFRetain(self->surface) : NULL;
    g_mutex_unlock(&self->lock);
    return surface;
}

static void release_spice(VsmSpice *self)
{
    if (self->surface)
        CFRelease(self->surface);
    g_hash_table_unref(self->pressed);
    g_main_loop_unref(self->loop);
    g_main_context_unref(self->ctx);
    g_mutex_clear(&self->lock);
    wipe_password(self);
    g_free(self->uri);
    g_free(self);
}

void vsm_spice_free(VsmSpice *self)
{
    if (!self)
        return;
    vsm_spice_stop(self);
    /* The thread is joined, so nothing can enqueue another callback -- but the
     * damage/status/cursor blocks already sitting on the main queue captured
     * @self and dereference it.  The main queue is FIFO, so a block appended
     * now runs strictly after all of them, which makes this the earliest point
     * at which the struct is provably unreferenced. */
    dispatch_async(dispatch_get_main_queue(), ^{ release_spice(self); });
}
