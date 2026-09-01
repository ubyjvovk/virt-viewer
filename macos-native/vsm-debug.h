/*
 * vsm-debug.h: developer aids that are compiled in but inert unless their
 * environment variable is set.  They exist because a headless/locked macOS
 * session cannot be screenshotted or typed into, and a PoC still has to be
 * able to prove what it puts on screen and what it sends to the guest.
 */
#ifndef VSM_DEBUG_H
#define VSM_DEBUG_H

#import <Cocoa/Cocoa.h>

#include "vsm-spice.h"

/* Writes the current guest framebuffer to @path as a PNG.  Returns NO and
 * logs if there is no surface yet.  VSM_DUMP_DIR + SIGUSR1 drives this. */
BOOL vsm_dump_surface(VsmSpice *spice, NSString *path);

@class VsmView;

/* Replays a fixed, deliberately benign input script through @view's real
 * NSResponder entry points (keyDown:/keyUp:/flagsChanged:/mouse*), so the
 * keycode table, the flagsChanged modifier synthesis and the cross-thread
 * marshalling are all exercised exactly as they are for hardware events.
 * Enabled with VSM_SELFTEST=1. */
void vsm_run_input_selftest(VsmView *view, NSWindow *window);

/* Replays the whole relative-mouse gesture through @view's real entry
 * points: the click that takes the pointer grab, a run of hardware-delta
 * mouse-moved events (including sub-pixel ones), a button and a scroll while
 * grabbed, and the ctrl-opt chord that releases it.  Dumps the guest
 * framebuffer before and after the motion run into @dumpDir when it is
 * non-nil, which is the evidence that the guest pointer actually moved.
 * Enabled with VSM_GRAB_SELFTEST=1, and only useful together with
 * VSM_FORCE_RELATIVE=1 -- a guest running an agent is in absolute mode, where
 * there is no grab to take. */
void vsm_run_grab_selftest(VsmView *view, NSWindow *window, NSString *dumpDir);

/* Replays a synthetic cursor-channel script -- two shapes with different
 * hotspots, then hide, then reset -- through @view's real cursor entry
 * points.  Enabled with VSM_CURSOR_SELFTEST=1.  It exists because a guest
 * that draws its pointer into the framebuffer never sends a cursor shape at
 * all, and the AppKit half still has to be provable on such a target. */
void vsm_run_cursor_selftest(VsmView *view);

/* Sends one deliberately harmless chord -- Shift+F11 -- through the same
 * -[VsmView sendChord:] path the Send Key menu uses.  Enabled with
 * VSM_SENDKEY_SELFTEST=1.  It exists because the real menu entries include
 * chords (Ctrl+Alt+Del) that must never be fired at a live guest, so the
 * ordered-press / reverse-release behaviour has to be provable some other
 * way; with VSM_TRACE=1 the scancode order is in the log. */
void vsm_run_sendkey_selftest(VsmView *view);

#endif /* VSM_DEBUG_H */
