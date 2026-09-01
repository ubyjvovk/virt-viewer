/*
 * vsm-clipboard.m: host pasteboard <-> guest clipboard, text only.
 *
 * See vsm-clipboard.h for the contract.  Two independent halves meet here:
 *
 *   host -> guest   a 1 s poll of NSPasteboard.general.changeCount notices a
 *                   copy on the host and OFFERS text to the guest; the bytes
 *                   are only read and sent when the guest asks for them.
 *   guest -> host   the guest's grab is answered with a request, and the
 *                   text that comes back is written to the pasteboard.
 *
 * The two halves would chase each other's tails if they were left alone --
 * writing the pasteboard bumps changeCount, which the poller would read as a
 * fresh host copy and offer straight back to the guest.  Two guards break
 * that: an identical text is never written at all, and a write we do perform
 * records the changeCount it produced as "already seen".
 */
#import "vsm-clipboard.h"

#include <glib.h>

/* Slow enough to be invisible on a power graph, fast enough that Cmd-C then
 * a paste inside the guest feels immediate.  There is no cheaper option:
 * AppKit posts no notification for a pasteboard it does not own. */
static const NSTimeInterval VSM_CLIPBOARD_POLL_SECONDS = 1.0;

static BOOL vsm_clipboard_trace(void)
{
    const char *env = getenv("VSM_TRACE");
    return env && *env == '1';
}

@implementation VsmClipboard {
    NSTimer   *_pollTimer;
    NSInteger  _seenChangeCount;   /* the last changeCount accounted for */
    BOOL       _agentConnected;
    BOOL       _appActive;
    BOOL       _offeredToGuest;    /* this client currently holds the grab */
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _seenChangeCount = -1;
        _appActive = NSApp.isActive;
    }
    return self;
}

- (void)dealloc
{
    [_pollTimer invalidate];
}

/* ------------------------------------------------------------ poll state */

/* The poll is a pure function of the three conditions in the header, so both
 * setters and -setSpice: just re-evaluate it rather than each trying to
 * remember whether the timer is running. */
- (void)updatePolling
{
    BOOL wanted = (self.spice != NULL) && _agentConnected && _appActive;

    if (wanted == (_pollTimer != nil))
        return;

    if (wanted) {
        /* Catch up first: a copy made while the app was in the background is
         * exactly what the user is switching back to paste. */
        [self pollPasteboard];
        _pollTimer = [NSTimer scheduledTimerWithTimeInterval:VSM_CLIPBOARD_POLL_SECONDS
                                                      target:self
                                                    selector:@selector(pollTimerFired:)
                                                    userInfo:nil
                                                     repeats:YES];
        if (vsm_clipboard_trace())
            NSLog(@"clipboard: pasteboard poll started");
    } else {
        [_pollTimer invalidate];
        _pollTimer = nil;
        if (vsm_clipboard_trace())
            NSLog(@"clipboard: pasteboard poll stopped");
    }
}

- (void)setSpice:(VsmSpice *)spice
{
    _spice = spice;
    /* A new session has its own agent, and there is nothing to withdraw from
     * the old one: reset rather than carry state across. */
    _agentConnected = NO;
    _offeredToGuest = NO;
    /* -1 is never a real changeCount, so the first poll of the new session
     * treats whatever is already on the pasteboard as fresh and offers it.
     * Without that, text copied BEFORE the viewer connected would stay
     * invisible to the guest until the user copied something a second time. */
    _seenChangeCount = -1;
    [self updatePolling];
}

- (void)setAgentConnected:(BOOL)connected
{
    if (_agentConnected == connected)
        return;
    _agentConnected = connected;
    if (!connected)
        _offeredToGuest = NO;
    NSLog(@"clipboard: %@", connected
              ? @"guest agent present, text clipboard active"
              : @"no guest agent (spice-vdagent) -- clipboard disabled");
    [self updatePolling];
}

- (void)setApplicationActive:(BOOL)active
{
    if (_appActive == active)
        return;
    _appActive = active;
    [self updatePolling];
}

- (void)stop
{
    self.spice = NULL;
}

/* --------------------------------------------------------- host -> guest */

- (void)pollTimerFired:(NSTimer *)timer
{
    (void)timer;
    [self pollPasteboard];
}

/* One look at the general pasteboard.  Nothing is offered unless there is a
 * NON-EMPTY string behind the text flavour: `pbcopy </dev/null` leaves the
 * flavour in place with zero characters behind it, and a grab for that can
 * only ever be answered with "none".  Reading the string is the only way to
 * tell the two apart -- it is reduced to a character count on the spot, and
 * the count is all that is ever traced. */
- (void)pollPasteboard
{
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSInteger count = pb.changeCount;
    NSUInteger length;

    if (count == _seenChangeCount)
        return;
    _seenChangeCount = count;

    length = [pb stringForType:NSPasteboardTypeString].length;
    if (length) {
        if (vsm_clipboard_trace())
            NSLog(@"clipboard: host copy seen (change %ld), offering %lu character%s to guest",
                  (long)count, (unsigned long)length, length == 1 ? "" : "s");
        _offeredToGuest = YES;
        vsm_spice_clipboard_grab(self.spice);
    } else if (_offeredToGuest) {
        /* The host clipboard now holds something this client cannot express
         * -- an image, a file promise, an empty copy.  Withdrawing is better
         * than leaving the guest able to request text that no longer
         * exists. */
        if (vsm_clipboard_trace())
            NSLog(@"clipboard: host clipboard has no text, releasing offer");
        _offeredToGuest = NO;
        vsm_spice_clipboard_release(self.spice);
    } else if (vsm_clipboard_trace()) {
        NSLog(@"clipboard: host copy seen (change %ld) with no text, nothing offered",
              (long)count);
    }
}

- (void)guestRequestedText
{
    NSString *text = [NSPasteboard.generalPasteboard
                         stringForType:NSPasteboardTypeString];

    if (!text.length) {
        /* The offer and the request race the pasteboard: whatever was there
         * when the grab went out can be gone by the time the guest asks for
         * it.  The request still has to be closed -- an agent left waiting on
         * a reply stops acting on later grabs -- so answer "none" rather than
         * saying nothing. */
        if (vsm_clipboard_trace())
            NSLog(@"clipboard: guest asked for text, host has none, answering none");
        vsm_spice_clipboard_send_none(self.spice);
        return;
    }
    if (vsm_clipboard_trace())
        NSLog(@"clipboard: answering guest request, %lu character%s",
              (unsigned long)text.length, text.length == 1 ? "" : "s");
    vsm_spice_clipboard_send(self.spice, text.UTF8String);
}

/* --------------------------------------------------------- guest -> host */

- (void)guestGrabbed
{
    if (vsm_clipboard_trace())
        NSLog(@"clipboard: guest offers text, requesting it");
    vsm_spice_clipboard_request(self.spice);
}

- (void)guestReleased
{
    /* Nothing to undo: the host pasteboard keeps whatever was already pasted
     * into it, exactly as it would after the app that filled it quit. */
    if (vsm_clipboard_trace())
        NSLog(@"clipboard: guest released its clipboard");
}

- (void)guestSentText:(char *)utf8
{
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSString *text;

    if (!utf8)
        return;
    text = @(utf8);
    g_free(utf8);
    if (!text) {
        NSLog(@"clipboard: guest text was not valid UTF-8, dropped");
        return;
    }

    /* First echo guard: re-writing what is already there would bump
     * changeCount for no reason, and a guest that re-grabs after its own
     * paste would then be offered its own text back. */
    if ([text isEqualToString:[pb stringForType:NSPasteboardTypeString]]) {
        if (vsm_clipboard_trace())
            NSLog(@"clipboard: guest text already on the pasteboard, skipped");
        return;
    }

    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
    /* Second echo guard: this write is ours, so the poller must not read it
     * back as a host copy and offer it to the guest that just sent it. */
    _seenChangeCount = pb.changeCount;
    _offeredToGuest = NO;
    if (vsm_clipboard_trace())
        NSLog(@"clipboard: guest -> host pasteboard, %lu character%s (change %ld)",
              (unsigned long)text.length, text.length == 1 ? "" : "s",
              (long)_seenChangeCount);
}

@end
