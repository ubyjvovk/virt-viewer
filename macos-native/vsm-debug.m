#import "vsm-debug.h"

#import <ImageIO/ImageIO.h>

#import "main-view.h"
#import "vsm-tap.h"

static BOOL write_png(CGImageRef image, NSString *path);

BOOL vsm_dump_surface(VsmSpice *spice, NSString *path)
{
    IOSurfaceRef surface = vsm_spice_copy_surface(spice);
    size_t width, height, stride;
    CGColorSpaceRef cs;
    CGDataProviderRef provider;
    CGImageRef image;
    BOOL ok = NO;

    if (!surface) {
        NSLog(@"dump: no surface yet");
        return NO;
    }

    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    width = IOSurfaceGetWidth(surface);
    height = IOSurfaceGetHeight(surface);
    stride = IOSurfaceGetBytesPerRow(surface);

    cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    provider = CGDataProviderCreateWithData(NULL, IOSurfaceGetBaseAddress(surface),
                                            stride * height, NULL);
    image = CGImageCreate(width, height, 8, 32, stride, cs,
                          kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                          provider, NULL, false, kCGRenderingIntentDefault);

    ok = write_png(image, path);
    if (image) CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(surface);

    NSLog(@"dump: %@ %zux%zu -> %@", ok ? @"wrote" : @"FAILED", width, height, path);
    return ok;
}

static BOOL write_png(CGImageRef image, NSString *path)
{
    CGImageDestinationRef dest;
    BOOL ok = NO;

    dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                           CFSTR("public.png"), 1, NULL);
    if (dest && image) {
        CGImageDestinationAddImage(dest, image, NULL);
        ok = CGImageDestinationFinalize(dest);
    }
    if (dest)
        CFRelease(dest);
    return ok;
}

/* --------------------------------------------------------- input replay */

static NSEvent *key_event(NSWindow *window, NSEventType type, unsigned short keyCode,
                          NSEventModifierFlags flags)
{
    return [NSEvent keyEventWithType:type
                            location:NSZeroPoint
                       modifierFlags:flags
                           timestamp:NSProcessInfo.processInfo.systemUptime
                        windowNumber:window.windowNumber
                             context:nil
                          characters:@""
         charactersIgnoringModifiers:@""
                           isARepeat:NO
                             keyCode:keyCode];
}

static NSEvent *mouse_event(NSWindow *window, NSEventType type, NSPoint location)
{
    return [NSEvent mouseEventWithType:type
                              location:location
                         modifierFlags:0
                             timestamp:NSProcessInfo.processInfo.systemUptime
                          windowNumber:window.windowNumber
                               context:nil
                           eventNumber:0
                            clickCount:1
                              pressure:1.0];
}

static void tap(VsmView *view, NSWindow *window, unsigned short keyCode)
{
    [view keyDown:key_event(window, NSEventTypeKeyDown, keyCode, 0)];
    [view keyUp:key_event(window, NSEventTypeKeyUp, keyCode, 0)];
}

void vsm_run_input_selftest(VsmView *view, NSWindow *window)
{
    NSSize size = view.bounds.size;

    NSLog(@"selftest: begin");

    /* Keys chosen to be harmless on any guest: arrows and Escape only.  No
     * modifier+key combination is ever formed. */
    NSLog(@"selftest: arrow keys");
    tap(view, window, 0x7B);   /* Left  */
    tap(view, window, 0x7C);   /* Right */
    tap(view, window, 0x7E);   /* Up    */
    tap(view, window, 0x7D);   /* Down  */
    tap(view, window, 0x35);   /* Escape */

    /* Modifiers arrive only as flagsChanged; press then release each one on
     * its own, which is exactly the bitmask-delta path. */
    NSLog(@"selftest: modifiers via flagsChanged");
    [view flagsChanged:key_event(window, NSEventTypeFlagsChanged, 0x38,
                                 NSEventModifierFlagShift | 0x02)];
    [view flagsChanged:key_event(window, NSEventTypeFlagsChanged, 0x38, 0)];
    [view flagsChanged:key_event(window, NSEventTypeFlagsChanged, 0x3C,
                                 NSEventModifierFlagShift | 0x04)];
    [view flagsChanged:key_event(window, NSEventTypeFlagsChanged, 0x3C, 0)];
    [view flagsChanged:key_event(window, NSEventTypeFlagsChanged, 0x3B,
                                 NSEventModifierFlagControl | 0x01)];
    [view flagsChanged:key_event(window, NSEventTypeFlagsChanged, 0x3B, 0)];
    [view flagsChanged:key_event(window, NSEventTypeFlagsChanged, 0x3A,
                                 NSEventModifierFlagOption | 0x20)];
    [view flagsChanged:key_event(window, NSEventTypeFlagsChanged, 0x3A, 0)];

    NSLog(@"selftest: absolute motion");
    for (int i = 1; i <= 4; i++) {
        NSPoint p = NSMakePoint(size.width * i / 5.0, size.height * i / 5.0);
        [view mouseMoved:mouse_event(window, NSEventTypeMouseMoved, p)];
    }

    NSLog(@"selftest: buttons");
    NSPoint centre = NSMakePoint(size.width / 2.0, size.height / 2.0);
    [view mouseDown:mouse_event(window, NSEventTypeLeftMouseDown, centre)];
    [view mouseUp:mouse_event(window, NSEventTypeLeftMouseUp, centre)];
    [view rightMouseDown:mouse_event(window, NSEventTypeRightMouseDown, centre)];
    [view rightMouseUp:mouse_event(window, NSEventTypeRightMouseUp, centre)];

    NSLog(@"selftest: scroll");
    CGEventRef scrollUp = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, 3);
    [view scrollWheel:[NSEvent eventWithCGEvent:scrollUp]];
    CFRelease(scrollUp);
    CGEventRef scrollDown = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, -3);
    [view scrollWheel:[NSEvent eventWithCGEvent:scrollDown]];
    CFRelease(scrollDown);

    NSLog(@"selftest: end");
}

/* --------------------------------------------------------- grab selftest */

/* A mouse-moved event carrying hardware deltas.  -[NSEvent deltaX/deltaY]
 * read the CGEvent's kCGMouseEventDelta* fields, and only a CGEvent-backed
 * NSEvent has them: +mouseEventWithType: cannot express a delta at all. */
static NSEvent *motion_event(double dx, double dy)
{
    CGEventRef cg = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
                                            CGPointZero, kCGMouseButtonLeft);
    NSEvent *event;

    CGEventSetDoubleValueField(cg, kCGMouseEventDeltaX, dx);
    CGEventSetDoubleValueField(cg, kCGMouseEventDeltaY, dy);
    event = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    return event;
}

/* Feed @count motion events of (@dx,@dy) to @view one every 25 ms, then run
 * @done.  The pacing is the point: spice-gtk's inputs channel only allows a
 * bounded number of un-acknowledged motion messages in flight and silently
 * drops the rest, so a burst posted in a single turn of the run loop mostly
 * evaporates.  Real hardware paces itself; a script has to. */
static void drive_motion(VsmView *view, int count, double dx, double dy,
                         dispatch_block_t done)
{
    if (count <= 0) {
        done();
        return;
    }
    [view mouseMoved:motion_event(dx, dy)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        drive_motion(view, count - 1, dx, dy, done);
    });
}

/* Give the guest time to act on a batch of input and paint its answer: every
 * send here is asynchronous twice over (main thread -> GLib thread -> wire),
 * so dumping the framebuffer in the same turn that posted the motion
 * photographs the frame before anything has happened. */
static void settle(dispatch_block_t next)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), next);
}

/* One modifier transition, as flagsChanged delivers it: the device-dependent
 * bit for the specific key plus the generic mask, exactly like the hardware
 * (see -[VsmView handleFlagsChanged:]).
 *
 * There are two entry points for a real modifier keystroke and the single
 * source rule means only one of them is live at a time, so a synthetic one
 * has to pick the same one: with the event tap installed the view's own
 * -flagsChanged: deliberately stands aside and the tap's decision function
 * is where the escape chord is recognised. */
static void flags(VsmView *view, NSWindow *window, unsigned short keyCode,
                  NSEventModifierFlags mask)
{
    NSEvent *event = key_event(window, NSEventTypeFlagsChanged, keyCode, mask);
    id delegate = window.delegate;

    if (view.tapOwnsKeyboard &&
        [delegate respondsToSelector:@selector(eventTapShouldConsume:)])
        [(id<VsmEventTapDelegate>)delegate eventTapShouldConsume:event];
    else
        [view flagsChanged:event];
}

/* ctrl down, opt down, ctrl up, opt up: only the last event completes the
 * chord, and the two presses have already reached the guest by then. */
static void escape_chord(VsmView *view, NSWindow *window)
{
    flags(view, window, 0x3B, NSEventModifierFlagControl | 0x01);
    flags(view, window, 0x3A, NSEventModifierFlagControl | 0x01 |
                              NSEventModifierFlagOption | 0x20);
    flags(view, window, 0x3B, NSEventModifierFlagOption | 0x20);
    flags(view, window, 0x3A, 0);
}

static void dump(VsmSpice *spice, NSString *dumpDir, NSString *name)
{
    if (dumpDir)
        vsm_dump_surface(spice, [dumpDir stringByAppendingPathComponent:name]);
}

/* The tail of the script, once the guest has been driven and photographed. */
static void grab_selftest_finish(VsmView *view, NSWindow *window, NSPoint centre)
{
    /* Buttons and scroll still work while grabbed. */
    NSLog(@"grab-selftest: buttons and scroll while grabbed");
    [view mouseDown:mouse_event(window, NSEventTypeLeftMouseDown, centre)];
    [view mouseUp:mouse_event(window, NSEventTypeLeftMouseUp, centre)];
    CGEventRef scroll = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, 3);
    [view scrollWheel:[NSEvent eventWithCGEvent:scroll]];
    CFRelease(scroll);

    /* The ctrl-opt release chord, through whichever entry point is live.  The
     * log must show the guest's held ctrl and alt being released: the chord
     * swallows their key-ups, so nothing else ever would. */
    NSLog(@"grab-selftest: ctrl-opt release chord (%s path)",
          view.tapOwnsKeyboard ? "event tap" : "responder");
    escape_chord(view, window);
    NSLog(@"grab-selftest: after chord grabbed=%d title=%@",
          view.pointerGrabbed, window.title);

    /* Ungrabbed relative mode sends nothing: a position message has no
     * meaning to a server with no absolute pointing device. */
    [view mouseMoved:motion_event(50, 50)];

    /* The chord again, on whichever entry point is live now -- firing it
     * turns keyboard capture off, which hands the keyboard back from the tap
     * to the responder chain, so this second pass covers the other one. */
    NSLog(@"grab-selftest: re-grab, then the chord again (%s path)",
          view.tapOwnsKeyboard ? "event tap" : "responder");
    [view mouseDown:mouse_event(window, NSEventTypeLeftMouseDown, centre)];
    [view mouseUp:mouse_event(window, NSEventTypeLeftMouseUp, centre)];
    escape_chord(view, window);
    NSLog(@"grab-selftest: after second chord grabbed=%d title=%@",
          view.pointerGrabbed, window.title);

    /* Back to absolute in the same session.  VSM_FORCE_RELATIVE asks for
     * server mode once and only once, so this request is the last word: the
     * mode callback must un-grab and the ordinary absolute-position path must
     * come back to life. */
    NSLog(@"grab-selftest: requesting client (absolute) mouse mode back");
    vsm_spice_request_mouse_mode(view.spice, 0);
    settle(^{
        NSSize size = view.bounds.size;
        NSLog(@"grab-selftest: absolute again, grabbed=%d title=%@",
              view.pointerGrabbed, window.title);
        /* An ordinary absolute move: the trace line must be "motion X,Y"
         * again, not "motion dx,dy". */
        [view mouseMoved:mouse_event(window, NSEventTypeMouseMoved,
                                     NSMakePoint(size.width / 3.0, size.height / 3.0))];
        NSLog(@"grab-selftest: end");
    });
}

void vsm_run_grab_selftest(VsmView *view, NSWindow *window, NSString *dumpDir)
{
    NSSize size = view.bounds.size;
    NSPoint centre = NSMakePoint(size.width / 2.0, size.height / 2.0);
    VsmSpice *spice = view.spice;

    NSLog(@"grab-selftest: begin (grabbed=%d)", view.pointerGrabbed);

    /* The click that takes the grab.  It is consumed by the grab, so the
     * guest never sees it. */
    [view mouseDown:mouse_event(window, NSEventTypeLeftMouseDown, centre)];
    [view mouseUp:mouse_event(window, NSEventTypeLeftMouseUp, centre)];
    NSLog(@"grab-selftest: after click grabbed=%d title=%@",
          view.pointerGrabbed, window.title);
    if (!view.pointerGrabbed) {
        NSLog(@"grab-selftest: NOT grabbed -- is the session in relative mode "
              @"(VSM_FORCE_RELATIVE=1) and this window key?");
        return;
    }

    /* Park the guest pointer in the top-left corner so the "after" frame can
     * be compared against a known start; the guest clamps at its own edge. */
    NSLog(@"grab-selftest: parking the guest pointer at the top-left corner");
    drive_motion(view, 40, -80, -80, ^{
        settle(^{
            dump(spice, dumpDir, @"grab-before.png");
            NSLog(@"grab-selftest: relative motion");
            /* 40 x (24,16) = (960,640) guest pixels, right and down. */
            drive_motion(view, 40, 24, 16, ^{
                /* Sub-pixel deltas: 10 x 0.3 must accumulate into 3 whole
                 * pixels rather than rounding away to nothing. */
                drive_motion(view, 10, 0.3, 0.3, ^{
                    settle(^{
                        dump(spice, dumpDir, @"grab-after.png");
                        grab_selftest_finish(view, window, centre);
                    });
                });
            });
        });
    });
}

/* ------------------------------------------------------- cursor selftest */

/* Fill @rgba (premultiplied RGBA, as the cursor channel delivers it) with a
 * deliberately unmistakable shape: an opaque magenta right triangle with its
 * right angle at the hotspot, and a one-pixel white outline along the
 * hypotenuse.  Nothing on a macOS desktop looks like this, so a screenshot
 * showing it is unambiguous. */
static void fill_triangle(uint8_t *rgba, int size)
{
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            uint8_t *px = rgba + ((size_t)y * size + x) * 4;
            int edge = size - 1 - y;
            if (x > edge) {                       /* outside the triangle */
                px[0] = px[1] = px[2] = px[3] = 0;
            } else if (x >= edge - 1) {           /* hypotenuse outline */
                px[0] = px[1] = px[2] = px[3] = 0xff;
            } else {
                px[0] = 0xff; px[1] = 0x00; px[2] = 0xff; px[3] = 0xff;
            }
        }
    }
}

/* A hollow square ring, distinct in both size and hotspot from the triangle,
 * so "the shape changed" is visible without measuring anything. */
static void fill_ring(uint8_t *rgba, int size)
{
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            uint8_t *px = rgba + ((size_t)y * size + x) * 4;
            BOOL onRing = (x < 2 || y < 2 || x >= size - 2 || y >= size - 2);
            px[0] = onRing ? 0x00 : 0;
            px[1] = onRing ? 0xff : 0;
            px[2] = onRing ? 0xff : 0;
            px[3] = onRing ? 0xff : 0;
        }
    }
}

static void define_shape(VsmView *view, int size, int hot_x, int hot_y,
                         void (*fill)(uint8_t *, int))
{
    uint8_t *rgba = calloc((size_t)size * size, 4);
    NSCursor *cursor;

    if (!rgba)
        return;
    fill(rgba, size);
    NSLog(@"cursor-selftest: define %dx%d hotspot %d,%d", size, size, hot_x, hot_y);
    cursor = vsm_cursor_from_rgba(size, size, hot_x, hot_y, rgba);
    free(rgba);
    if (cursor)
        [view setGuestCursor:cursor];
}

void vsm_run_cursor_selftest(VsmView *view)
{
    /* Churn first: a real session defines a cursor thousands of times, and
     * the interesting failure is a per-define leak rather than a wrong
     * shape.  VSM_CURSOR_CHURN=N replaces the previous cursor N times as
     * fast as it can so leaks(1) has something to find. */
    NSString *churn = NSProcessInfo.processInfo.environment[@"VSM_CURSOR_CHURN"];

    NSLog(@"cursor-selftest: begin");
    if (churn) {
        int n = churn.intValue;
        NSLog(@"cursor-selftest: churn %d defines", n);
        for (int i = 0; i < n; i++)
            define_shape(view, 32, 0, 0, (i & 1) ? fill_ring : fill_triangle);
        NSLog(@"cursor-selftest: churn done");
    }
    define_shape(view, 32, 0, 0, fill_triangle);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        define_shape(view, 24, 12, 12, fill_ring);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            NSLog(@"cursor-selftest: hide");
            [view hideGuestCursor];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                NSLog(@"cursor-selftest: reset");
                [view resetGuestCursor];
                NSLog(@"cursor-selftest: end");
            });
        });
    });
}

/* ------------------------------------------------------ send-key selftest */

void vsm_run_sendkey_selftest(VsmView *view)
{
    /* XT scancodes: 0x2a = LeftShift, 0x57 = F11.  Two keys is the smallest
     * chord that shows the press order and the reversed release order. */
    NSLog(@"sendkey-selftest: Shift+F11");
    [view sendChord:@[@0x2a, @0x57]];
    NSLog(@"sendkey-selftest: end");
}
