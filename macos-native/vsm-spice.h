/*
 * vsm-spice.h: SPICE session driven on a private GLib main context thread.
 *
 * Threading contract (the CocoaSpice shape):
 *   - Everything spice-client-glib is touched on ONE dedicated thread that
 *     runs a private GMainContext.  The AppKit main thread never blocks on
 *     it and never calls a spice_* function directly.
 *   - Guest framebuffer damage is copied into an IOSurface on the GLib
 *     thread (where the surface buffer is stable), and only the "this
 *     IOSurface changed" notification is marshalled to the main thread.
 *   - Input travels the other way: the vsm_spice_send_* functions are safe
 *     to call from the main thread and marshal onto the GLib thread with
 *     g_main_context_invoke().
 */
#ifndef VSM_SPICE_H
#define VSM_SPICE_H

#include <IOSurface/IOSurface.h>
#include <stdint.h>

typedef struct _VsmSpice VsmSpice;

/* All callbacks are delivered on the AppKit main thread. */
typedef struct {
    /* A new primary surface exists; @width/@height are guest pixels. */
    void (*primary_create)(void *user, int width, int height);
    /* The IOSurface content changed; the union of damage since the last
     * call is @x/@y/@w/@h in guest pixels. */
    void (*damaged)(void *user, int x, int y, int w, int h);
    /* Human-readable status/title updates and terminal disconnection. */
    void (*title)(void *user, const char *title);
    void (*status)(void *user, const char *status);
    /* The session went down and will not come back on its own.  @reason is a
     * short human-readable phrase; @auth_failed is 1 when the server rejected
     * the credentials (SPICE_CHANNEL_ERROR_AUTH), which is the one failure a
     * password prompt can fix, and 0 for every other cause. */
    void (*disconnected)(void *user, const char *reason, int auth_failed);

    /* Cursor channel.  The guest defined a new pointer shape: @width x
     * @height pixels of non-planar RGBA (byte order R,G,B,A; alpha is
     * premultiplied), with the hotspot at @hot_x/@hot_y in the same pixels.
     * @rgba is a malloc()'d copy that the callee OWNS and must free() --
     * spice-client-glib owns the original and may recycle it as soon as the
     * signal handler returns, so the copy is taken on the GLib thread. */
    void (*cursor_define)(void *user, int width, int height,
                          int hot_x, int hot_y, const uint8_t *rgba);
    /* The guest hid the pointer; show nothing over the guest area. */
    void (*cursor_hide)(void *user);
    /* The cursor channel was reset; revert to the default system arrow. */
    void (*cursor_reset)(void *user);

    /* The negotiated mouse mode changed.  @relative is 1 for SPICE server
     * mode (the guest has no absolute pointing device: the client must grab
     * the pointer and send deltas) and 0 for client/absolute mode.  Fires
     * once when the server announces the mode at connect and again on every
     * later switch, so the view can enter and leave its grab state. */
    void (*mouse_mode)(void *user, int relative);

    /* Clipboard, guest agent (spice-vdagent) side.  Plain UTF-8 text on the
     * CLIPBOARD selection only; everything else is ignored on both ends.
     *
     * The agent came up (@connected 1) or went away (0).  Fires once per
     * transition, including the initial state once the main channel has
     * negotiated it.  While it is 0 every clipboard entry point below is a
     * no-op, so the host side can simply stop polling. */
    void (*clipboard_agent)(void *user, int connected);
    /* The guest took ownership of its clipboard and offers UTF-8 text.  The
     * host answers by calling vsm_spice_clipboard_request() -- data is never
     * pushed unrequested in either direction. */
    void (*clipboard_grab)(void *user);
    /* The guest dropped its clipboard ownership. */
    void (*clipboard_release)(void *user);
    /* The text a previous vsm_spice_clipboard_request() asked for.  @text is
     * a NUL-terminated UTF-8 g_malloc() block that the callee OWNS and must
     * release with g_free(). */
    void (*clipboard_data)(void *user, char *text);
    /* The guest wants the host clipboard's UTF-8 text.  EVERY request must
     * be answered exactly once: with vsm_spice_clipboard_send() when there
     * is text, and with vsm_spice_clipboard_send_none() when there is not.
     * An unanswered request leaves the guest agent waiting on a reply that
     * never comes, and a wedged agent ignores every later grab. */
    void (*clipboard_request)(void *user);
} VsmSpiceCallbacks;

/* Lifecycle.  vsm_spice_new() does not touch the network; vsm_spice_start()
 * spawns the GLib thread and begins connecting. */
VsmSpice *vsm_spice_new(const char *uri, const VsmSpiceCallbacks *cb, void *user);
/* Credentials for the next vsm_spice_start().  Must be called BEFORE start:
 * the string is copied here and applied to the session's "password" property
 * on the GLib thread, so there is no cross-thread access to it.  A retry after
 * SPICE_CHANNEL_ERROR_AUTH is a fresh new/set_password/start cycle, not a
 * mutation of the running session.  The copy is wiped before it is released;
 * it is never logged, traced or persisted. */
void      vsm_spice_set_password(VsmSpice *self, const char *password);
void      vsm_spice_start(VsmSpice *self);
/* Releases every held key, disconnects the session and joins the thread.
 * Safe to call twice; must be called from the main thread. */
void      vsm_spice_stop(VsmSpice *self);
/* Stops the session and releases it.  The release itself is deferred to the
 * main queue, because callbacks already dispatched from the GLib thread still
 * hold @self and must run first; @self must not be touched after this call.
 * Must be called from the main thread. */
void      vsm_spice_free(VsmSpice *self);

/* Retained IOSurface holding the guest framebuffer, or NULL before the
 * first primary-create.  Caller owns the reference. */
IOSurfaceRef vsm_spice_copy_surface(VsmSpice *self);

/* Input.  @scancode is an XT (AT set 1) code, 0xe0-prefixed for extended
 * keys, exactly as spice_inputs_channel_key_press() expects.  Every entry
 * point below (and vsm_spice_copy_surface) tolerates a NULL @self, so a view
 * whose session has been torn down can keep handling events harmlessly. */
void vsm_spice_send_key(VsmSpice *self, unsigned scancode, int down);
void vsm_spice_release_all_keys(VsmSpice *self);
void vsm_spice_send_position(VsmSpice *self, int x, int y, int button_state);
/* Relative (server mouse mode) motion: @dx/@dy are pointer deltas in guest
 * pixels, right/down positive.  Only meaningful while the session is in
 * server mode; the server ignores it in client mode. */
void vsm_spice_send_motion(VsmSpice *self, int dx, int dy, int button_state);
void vsm_spice_send_button(VsmSpice *self, int button, int down, int button_state);
/* @steps > 0 scrolls up, < 0 scrolls down. */
void vsm_spice_send_scroll(VsmSpice *self, int steps, int button_state);

/* Ask the server to switch mouse mode: @relative 1 requests server
 * (relative) mode, 0 requests client (absolute) mode.  The server answers
 * with a mouse-mode change, which arrives back as the mouse_mode callback --
 * it may refuse, so never assume the mode from the request.  Used by the
 * VSM_FORCE_RELATIVE debug path and by the Input menu item it installs. */
void vsm_spice_request_mouse_mode(VsmSpice *self, int relative);

/* Clipboard.  All five are safe to call from the main thread with a NULL
 * @self, and all five are silently dropped while no guest agent is connected
 * -- the caller never has to track that state to stay correct.  Contents are
 * never logged: the trace records types and byte counts only.
 *
 * Offer the host clipboard's UTF-8 text to the guest.  This announces
 * availability only; the bytes travel later, in answer to the guest's
 * request. */
void vsm_spice_clipboard_grab(VsmSpice *self);
/* Withdraw a previous offer (the host clipboard no longer holds text). */
void vsm_spice_clipboard_release(VsmSpice *self);
/* Ask the guest for the UTF-8 text it grabbed; it arrives as the
 * clipboard_data callback. */
void vsm_spice_clipboard_request(VsmSpice *self);
/* Answer a clipboard_request callback.  @utf8 is NUL-terminated and is
 * copied; NULL or "" sends nothing -- use vsm_spice_clipboard_send_none()
 * for those, or the request goes unanswered. */
void vsm_spice_clipboard_send(VsmSpice *self, const char *utf8);
/* Answer a clipboard_request callback that cannot be fulfilled: an empty
 * VD_AGENT_CLIPBOARD_NONE notify, which is how spice-gtk closes the same
 * case (src/spice-gtk-session.c, clipboard_received_cb).  The guest agent
 * needs one reply per request; without it its clipboard state machine stays
 * blocked on the outstanding one. */
void vsm_spice_clipboard_send_none(VsmSpice *self);

/* SPICE button numbers, re-exported so main.m need not include the
 * protocol headers. */
#define VSM_BUTTON_LEFT   1
#define VSM_BUTTON_MIDDLE 2
#define VSM_BUTTON_RIGHT  3
#define VSM_MASK_LEFT     (1 << 0)
#define VSM_MASK_MIDDLE   (1 << 1)
#define VSM_MASK_RIGHT    (1 << 2)

#endif /* VSM_SPICE_H */
