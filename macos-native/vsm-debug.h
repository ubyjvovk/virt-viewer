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

#endif /* VSM_DEBUG_H */
