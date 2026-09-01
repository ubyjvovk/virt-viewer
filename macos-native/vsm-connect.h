/*
 * vsm-connect.h: the pre- and post-session user interface -- the connect
 * window shown when no URI was given on argv, and the two modal dialogs the
 * session can raise (password prompt, disconnect alert).
 *
 * Everything here is AppKit and main-thread only; nothing in this file knows
 * about SPICE.  main.m owns the session state machine and calls in.
 */
#ifndef VSM_CONNECT_H
#define VSM_CONNECT_H

#import <Cocoa/Cocoa.h>

/* NSUserDefaults key remembering the last URI the user connected to from the
 * connect window, so a relaunch offers it again.  Only the URI is stored --
 * never a password. */
extern NSString *const VsmLastURIKey;

/* The "where do I connect?" window: a URI field plus a default Connect
 * button, shown when the viewer is launched with no URI and again whenever a
 * session ends and the user chooses not to reconnect.  Closing the window
 * quits the application -- it is the app's last exit door when there is no
 * session on screen. */
@interface VsmConnectWindowController : NSObject <NSWindowDelegate>
/* @handler is invoked on the main thread with the trimmed, non-empty URI when
 * the user activates Connect.  It is not called for an empty field. */
- (instancetype)initWithHandler:(void (^)(NSString *uri))handler;
/* Order the window in with @uri pre-filled; pass nil to offer the remembered
 * VsmLastURIKey value instead. */
- (void)showWithURI:(NSString *)uri;
/* Order the window out without closing it (so no quit is triggered). */
- (void)hide;
@end

/* Modal "the server wants a password" prompt for @uri, run after the session
 * failed with an authentication error.  Returns the typed password, or nil if
 * the user cancelled.  The result is only ever handed to
 * vsm_spice_set_password(); it is never logged or written to defaults. */
NSString *vsm_prompt_password(NSString *uri);

/* What the user chose in the disconnect alert. */
typedef enum {
    VSM_DISCONNECT_RECONNECT,
    VSM_DISCONNECT_CLOSE,
} VsmDisconnectChoice;

/* Modal alert reporting that the session to @uri ended because of @reason,
 * offering Reconnect (default) and Close. */
VsmDisconnectChoice vsm_prompt_disconnect(NSString *uri, const char *reason);

#endif /* VSM_CONNECT_H */
