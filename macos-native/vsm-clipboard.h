/*
 * vsm-clipboard.h: the AppKit half of the guest <-> host text clipboard.
 *
 * Plain UTF-8 text on NSPasteboard.general and the SPICE CLIPBOARD
 * selection, in both directions.  Images, rich text, file lists and the X11
 * PRIMARY selection are deliberately out: macOS has no PRIMARY, and anything
 * that is not text is dropped rather than mistranslated.
 *
 * Everything in here runs on the main thread, which is the only thread
 * allowed to touch NSPasteboard.  The guest side arrives as the
 * VsmSpiceCallbacks clipboard_* entries (already marshalled onto the main
 * thread by vsm-spice.c) and leaves through the vsm_spice_clipboard_*
 * functions (which marshal back).
 *
 * Clipboard CONTENTS are never logged.  The trace records direction and byte
 * or character counts only.
 */
#ifndef VSM_CLIPBOARD_H
#define VSM_CLIPBOARD_H

#import <Cocoa/Cocoa.h>

#include "vsm-spice.h"

@interface VsmClipboard : NSObject

/* The session to talk to, or NULL between sessions.  Setting it (including
 * to NULL) resets every piece of clipboard state, so a reconnect starts from
 * a clean slate rather than inheriting the previous guest's grab. */
@property (nonatomic, assign) VsmSpice *spice;

/* AppKit has no "the pasteboard changed" notification, so host -> guest is
 * driven by polling NSPasteboard.general.changeCount.  The poll runs only
 * when all three of these hold: a guest agent is connected, the application
 * is active, and there is a session.  It is off at every other moment, which
 * is what keeps an idle background viewer from waking the CPU once a second.
 * -agentConnected: is driven by the clipboard_agent callback; the other two
 * by the NSApplication activation notifications. */
- (void)setAgentConnected:(BOOL)connected;
- (void)setApplicationActive:(BOOL)active;

/* Guest -> host, one method per VsmSpiceCallbacks clipboard entry. */
- (void)guestGrabbed;
- (void)guestReleased;
/* Takes ownership of @utf8 (a g_malloc block) and releases it. */
- (void)guestSentText:(char *)utf8;
/* The guest wants what this host offered; answers from the pasteboard. */
- (void)guestRequestedText;

/* Stop polling and forget the session.  Safe to call twice. */
- (void)stop;

@end

#endif /* VSM_CLIPBOARD_H */
