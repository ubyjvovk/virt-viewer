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
    void (*disconnected)(void *user, const char *reason);
} VsmSpiceCallbacks;

/* Lifecycle.  vsm_spice_new() does not touch the network; vsm_spice_start()
 * spawns the GLib thread and begins connecting. */
VsmSpice *vsm_spice_new(const char *uri, const VsmSpiceCallbacks *cb, void *user);
void      vsm_spice_start(VsmSpice *self);
/* Releases every held key, disconnects the session and joins the thread.
 * Safe to call twice; must be called from the main thread. */
void      vsm_spice_stop(VsmSpice *self);
void      vsm_spice_free(VsmSpice *self);

/* Retained IOSurface holding the guest framebuffer, or NULL before the
 * first primary-create.  Caller owns the reference. */
IOSurfaceRef vsm_spice_copy_surface(VsmSpice *self);

/* Input.  @scancode is an XT (AT set 1) code, 0xe0-prefixed for extended
 * keys, exactly as spice_inputs_channel_key_press() expects. */
void vsm_spice_send_key(VsmSpice *self, unsigned scancode, int down);
void vsm_spice_release_all_keys(VsmSpice *self);
void vsm_spice_send_position(VsmSpice *self, int x, int y, int button_state);
void vsm_spice_send_button(VsmSpice *self, int button, int down, int button_state);
/* @steps > 0 scrolls up, < 0 scrolls down. */
void vsm_spice_send_scroll(VsmSpice *self, int steps, int button_state);

/* SPICE button numbers, re-exported so main.m need not include the
 * protocol headers. */
#define VSM_BUTTON_LEFT   1
#define VSM_BUTTON_MIDDLE 2
#define VSM_BUTTON_RIGHT  3
#define VSM_MASK_LEFT     (1 << 0)
#define VSM_MASK_MIDDLE   (1 << 1)
#define VSM_MASK_RIGHT    (1 << 2)

#endif /* VSM_SPICE_H */
