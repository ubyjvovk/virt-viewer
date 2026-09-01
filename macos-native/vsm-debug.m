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
