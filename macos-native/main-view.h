/*
 * main-view.h: the framebuffer view, shared with the debug helpers.
 */
#ifndef MAIN_VIEW_H
#define MAIN_VIEW_H

#import <Cocoa/Cocoa.h>

#include "vsm-spice.h"

/* What the view needs from the window it lives in.  The app delegate
 * implements it; the view holds it weakly because the delegate owns the
 * window that owns the view. */
@protocol VsmViewOwner <NSObject>
/* The pointer grab was taken or released, so the window title has to gain or
 * lose its "press <ctrl-opt> to release" suffix. */
- (void)viewDidChangePointerGrab:(BOOL)grabbed;
@end

/* Layer-backed view whose layer contents is the guest framebuffer IOSurface,
 * and whose responder methods forward keyboard and absolute mouse input to
 * the SPICE inputs channel. */
@interface VsmView : NSView
@property (nonatomic, weak) id<VsmViewOwner> owner;
@property (nonatomic, assign) VsmSpice *spice;
@property (nonatomic, assign) int guestWidth;
@property (nonatomic, assign) int guestHeight;
/* While YES (the default) and a session is connected and this view is the
 * key window's first responder, every Cmd chord is swallowed by
 * -performKeyEquivalent: and forwarded to the guest as scancodes instead of
 * being handled by the app -- Cmd-Q included.  The Input menu toggles it. */
@property (nonatomic, assign) BOOL captureKeyboard;
/* Single source rule: set while a live CGEventTap forwards the keyboard on
 * this view's behalf (see vsm-tap.h).  The responder methods then do nothing,
 * so a chord the tap already consumed and forwarded can never be sent a
 * second time from AppKit's own dispatch of the same keystroke.  Cleared
 * whenever the tap is gone, which restores the responder-only behaviour
 * exactly. */
@property (nonatomic, assign) BOOL tapOwnsKeyboard;

/* Rebind the layer to the current IOSurface so CA re-reads its bytes. */
- (void)refreshSurface;
/* Forward one macOS virtual keycode to the guest as a scancode.  The tap
 * path calls this directly: its events never reach the responder chain. */
- (void)sendKeyCode:(unsigned short)keyCode down:(BOOL)down;
/* The body of -flagsChanged:, without the tapOwnsKeyboard guard, so the tap
 * path shares the left/right modifier synthesis instead of copying it. */
- (void)handleFlagsChanged:(NSEvent *)event;
/* Release every key the guest still thinks is held (focus loss, quit). */
- (void)releaseAllKeys;
/* Send @scancodes (XT/AT set 1, 0x1xx for the 0xe0-prefixed extended keys)
 * as one chord: every code pressed in order, then released in reverse order,
 * which is what a human pressing the same combination produces.  Used by the
 * Send Key menu and by the send-key selftest. */
- (void)sendChord:(NSArray<NSNumber *> *)scancodes;

/* ------------------------------------------------------- pointer grab */

/* SPICE server (relative) mouse mode.  In relative mode the guest has no
 * absolute pointing device, so the view stops sending positions and instead
 * grabs the hardware pointer and sends deltas; in absolute mode (the
 * default) nothing about the existing behaviour changes.  Driven by the
 * session's mouse_mode callback. */
- (void)setRelativeMouseMode:(BOOL)relative;
/* YES while the hardware pointer is tied to this view. */
@property (nonatomic, readonly) BOOL pointerGrabbed;
/* Take the pointer: freeze it at the view's centre, hide it locally and
 * route mouse deltas to the guest.  No-op unless relative mode is on, a
 * session is live and this view's window is key. */
- (void)grabPointer;
/* Give the pointer back.  THE single un-grab path: every exit -- the
 * ctrl-opt chord, losing key, app deactivation, a mode switch back to
 * absolute, disconnect and quit -- goes through here, because failing to
 * re-associate the pointer leaves the user's whole desktop wedged.  Safe and
 * idempotent when nothing is grabbed: it re-associates anyway. */
- (void)ungrabPointer:(NSString *)reason;

/* Feed one flagsChanged event to the ctrl-opt release chord recogniser.
 * Returns YES when this event completed the chord, in which case the pointer
 * has already been un-grabbed and every held key released, and the caller
 * must not forward the event to the guest. */
- (BOOL)noteEscapeChord:(NSEvent *)event;
/* Disarm the recogniser: whatever was physically held is no longer this
 * view's business (focus loss, a capture toggle, a session teardown). */
- (void)resetEscapeChord;

/* Cursor channel.  @cursor is the guest's pointer shape, or nil to fall back
 * to the system arrow; the shape applies only while the pointer is inside
 * the view. */
- (void)setGuestCursor:(NSCursor *)cursor;
/* Show nothing over the guest area (guest hid its pointer). */
- (void)hideGuestCursor;
/* Forget the guest shape and go back to the system arrow. */
- (void)resetGuestCursor;
@end

/* Build an NSCursor from @width x @height premultiplied RGBA bytes with the
 * hotspot at @hot_x/@hot_y, exactly as the cursor channel delivers them.
 * Shared with the debug helper so a synthetic shape takes the same path as a
 * guest one.  Returns nil if the bitmap could not be allocated. */
NSCursor *vsm_cursor_from_rgba(int width, int height, int hot_x, int hot_y,
                               const uint8_t *rgba);

#endif /* MAIN_VIEW_H */
