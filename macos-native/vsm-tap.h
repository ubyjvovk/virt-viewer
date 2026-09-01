/*
 * vsm-tap.h: system-wide keyboard capture through a CGEventTap.
 *
 * The responder methods in main.m only ever see the keys macOS decides to
 * hand to an application, which leaves out exactly the chords a full-screen
 * guest needs most -- Cmd-Space, Cmd-Tab, Cmd-`, the screenshot keys.  A
 * session event tap sits ahead of that dispatch, so it sees them first and
 * can swallow them.  This is the same mechanism Parallels, VMware Fusion and
 * Screen Sharing use, and like them it needs a one-time Accessibility grant:
 * with no grant the tap is simply never installed and the app degrades to
 * responder-method capture.
 */
#ifndef VSM_TAP_H
#define VSM_TAP_H

#import <Cocoa/Cocoa.h>

@class VsmEventTap;

@protocol VsmEventTapDelegate <NSObject>
/* Offer one keyboard event (key down, key up or flags-changed) to the app
 * before the rest of the system sees it.  Return YES to consume it: the
 * delegate has dealt with it, and neither another process nor AppKit's own
 * dispatch will ever see it.  Return NO to let it travel on untouched.
 *
 * Called on the main thread, from the run loop, with the event pump blocked
 * behind it -- do only bookkeeping and non-blocking sends here.  A callback
 * that takes too long gets the tap disabled by the system (which is handled;
 * see kCGEventTapDisabledByTimeout in vsm-tap.m) and stalls every keystroke
 * on the machine until it returns. */
- (BOOL)eventTapShouldConsume:(NSEvent *)event;
@end

@interface VsmEventTap : NSObject
@property (nonatomic, weak) id<VsmEventTapDelegate> delegate;
/* YES once the tap is installed on the main run loop and enabled; NO both
 * before -install and after -uninstall.  The single "can we capture system
 * shortcuts at all?" question. */
@property (nonatomic, readonly) BOOL active;

/* Is this process trusted for Accessibility?  With @prompt YES macOS shows
 * its one-time "would like to control this computer" dialog; the call never
 * blocks and never polls, so ask for the prompt at most once per process and
 * re-check without it afterwards. */
+ (BOOL)isProcessTrusted:(BOOL)prompt;

/* Install the tap on the main run loop.  Returns NO, leaving @active NO,
 * when the process is not trusted or the tap cannot be created; the caller
 * then degrades to plain responder-method capture. */
- (BOOL)install;
/* Disable, unschedule and release the tap.  Safe to call twice. */
- (void)uninstall;
@end

#endif /* VSM_TAP_H */
