#import "vsm-debug.h"

#import <ImageIO/ImageIO.h>

#import "main-view.h"

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
    /* Spread over seconds rather than milliseconds: each step has to be
     * observable in a screenshot, not just in the log. */
    NSLog(@"cursor-selftest: begin");
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
