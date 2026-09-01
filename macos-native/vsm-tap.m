/*
 * vsm-tap.m: the CGEventTap that gives the guest the chords macOS keeps.
 */
#import "vsm-tap.h"

#import <ApplicationServices/ApplicationServices.h>

static CGEventRef vsm_tap_callback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon);

@implementation VsmEventTap {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
}

+ (BOOL)isProcessTrusted:(BOOL)prompt
{
    NSDictionary *options =
        @{ (__bridge NSString *)kAXTrustedCheckOptionPrompt: @(prompt) };

    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)
               ? YES : NO;
}

- (BOOL)active
{
    return _tap != NULL && CGEventTapIsEnabled(_tap);
}

- (BOOL)install
{
    /* Modifiers matter as much as the keys here: Cmd-Tab is a flags-changed
     * plus a key-down, and holding Cmd is what arms it. */
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) |
                       CGEventMaskBit(kCGEventKeyUp) |
                       CGEventMaskBit(kCGEventFlagsChanged);

    if (_tap)
        return self.active;
    /* Without the grant CGEventTapCreate() succeeds for a listen-only tap
     * and silently fails to deliver anything for a filtering one, so the
     * trust check is what decides, not the create call. */
    if (![VsmEventTap isProcessTrusted:NO])
        return NO;

    /* kCGSessionEventTap: everything entering this login session, which is
     * where Cmd-Space and Cmd-Tab are still ordinary events.
     * kCGHeadInsertEventTap: ahead of the system's own handlers, so we see
     * them before they are turned into Spotlight and the app switcher.
     * kCGEventTapOptionDefault: an active tap, allowed to return NULL. */
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                            kCGEventTapOptionDefault, mask,
                            vsm_tap_callback, (__bridge void *)self);
    if (!_tap) {
        NSLog(@"CGEventTapCreate failed; system shortcuts stay with macOS");
        return NO;
    }
    _source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    /* Common modes, not the default one: menu tracking, window dragging and
     * modal sessions each run their own mode, and the keyboard has to keep
     * behaving the same way in all of them. */
    CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    NSLog(@"event tap installed: system shortcuts can be captured");
    return YES;
}

- (void)uninstall
{
    if (!_tap)
        return;
    CGEventTapEnable(_tap, false);
    if (_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRelease(_source);
        _source = NULL;
    }
    CFMachPortInvalidate(_tap);
    CFRelease(_tap);
    _tap = NULL;
    NSLog(@"event tap removed");
}

/* The system switches a tap off when its callback overran the timeout or
 * when the user's input got ahead of it.  Both are recoverable and the
 * documented response is the same: turn it back on.  There is no retry loop
 * here -- if it is switched off again, the next event brings us back. */
- (void)reenable
{
    if (!_tap)
        return;
    NSLog(@"event tap was disabled by the system; re-enabling");
    CGEventTapEnable(_tap, true);
}

- (void)dealloc
{
    [self uninstall];
}

@end

static CGEventRef vsm_tap_callback(CGEventTapProxy proxy, CGEventType type,
                                   CGEventRef event, void *refcon)
{
    VsmEventTap *tap = (__bridge VsmEventTap *)refcon;
    NSEvent *nsevent;

    (void)proxy;

    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        [tap reenable];
        return event;
    }
    /* CGEvent keycodes are NSEvent.keyCode's space and CGEventFlags carries
     * the device-dependent left/right modifier bits, so wrapping the event
     * lets the tap path reuse the responder path's keymap and its
     * flags-changed synthesis verbatim rather than growing a second copy. */
    nsevent = [NSEvent eventWithCGEvent:event];
    if (!nsevent)
        return event;
    if ([tap.delegate eventTapShouldConsume:nsevent])
        return NULL;
    return event;
}
