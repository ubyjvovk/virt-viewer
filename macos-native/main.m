/*
 * main.m: native macOS front end for the SPICE viewer PoC.
 *
 * No GTK.  An NSWindow whose content view is a plain layer-backed NSView;
 * the layer's contents is the IOSurface that vsm-spice.c blits guest damage
 * into.  Handing CA an IOSurface directly means the damaged pixels are the
 * only ones we copy, and the compositor samples them 1:1 against physical
 * display pixels (contentsScale = backingScaleFactor), so a Retina screen
 * shows the guest framebuffer with no interpolation at all.
 *
 * Usage: viewer spice://host:port
 */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include "main-view.h"
#include "vsm-debug.h"
#include "vsm-keymap.h"
#include "vsm-spice.h"

/* Device-dependent modifier bits (IOKit's IOLLEvent.h), used to tell left
 * from right on flagsChanged: the public NSEventModifierFlag* masks collapse
 * both physical keys into one bit. */
enum {
    VSM_DEV_LCTRL  = 0x00000001,
    VSM_DEV_LSHIFT = 0x00000002,
    VSM_DEV_RSHIFT = 0x00000004,
    VSM_DEV_LCMD   = 0x00000008,
    VSM_DEV_RCMD   = 0x00000010,
    VSM_DEV_LALT   = 0x00000020,
    VSM_DEV_RALT   = 0x00000040,
    VSM_DEV_RCTRL  = 0x00002000,
};

/* macOS virtual keycodes for the modifier keys. */
enum {
    VSM_KC_LSHIFT = 0x38, VSM_KC_RSHIFT = 0x3C,
    VSM_KC_LCTRL  = 0x3B, VSM_KC_RCTRL  = 0x3E,
    VSM_KC_LALT   = 0x3A, VSM_KC_RALT   = 0x3D,
    VSM_KC_LCMD   = 0x37, VSM_KC_RCMD   = 0x36,
    VSM_KC_CAPS   = 0x39,
};

static BOOL vsm_trace;   /* VSM_TRACE=1: log every scancode/mouse event */

@implementation VsmView {
    NSMutableSet<NSNumber *> *_heldModifierKeyCodes;
    int _buttonState;
    NSCursor *_guestCursor;   /* the guest's shape, nil = system arrow */
    BOOL _cursorHidden;       /* guest asked for no pointer at all */
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _heldModifierKeyCodes = [NSMutableSet set];
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.layer.contentsGravity = kCAGravityResizeAspect;
        /* The guest framebuffer is not a resampled image; keep every
         * transition between guest pixels hard. */
        self.layer.magnificationFilter = kCAFilterNearest;
        self.layer.minificationFilter = kCAFilterTrilinear;
    }
    return self;
}

- (BOOL)acceptsFirstResponder    { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)isFlipped                { return YES; }

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    self.layer.contentsScale = self.window.backingScaleFactor;
}

/* Rebind the layer to the current IOSurface so CA re-reads its bytes.
 * Assigning the same object twice is a no-op to CA, so unbind first; both
 * assignments sit inside one transaction with actions disabled, which means
 * the intermediate nil never reaches the screen (no flash) and no implicit
 * animation is created. */
- (void)refreshSurface
{
    IOSurfaceRef surface = vsm_spice_copy_surface(self.spice);
    if (!surface)
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contents = nil;
    self.layer.contents = (__bridge id)surface;
    [CATransaction commit];
    CFRelease(surface);
}

/* ------------------------------------------------------------- keyboard */

- (void)sendKeyCode:(unsigned short)keyCode down:(BOOL)down
{
    unsigned scancode = (keyCode < 256) ? osx_to_xtkbd[keyCode] : 0;

    if (vsm_trace)
        NSLog(@"key %@ osx=0x%02x -> xt=0x%04x",
              down ? @"down" : @"up  ", keyCode, scancode);
    if (!scancode) {
        NSLog(@"no XT scancode for macOS keycode 0x%02x", keyCode);
        return;
    }
    vsm_spice_send_key(self.spice, scancode, down ? 1 : 0);
}

- (void)keyDown:(NSEvent *)event
{
    if (event.isARepeat) {
        /* Let the guest run its own repeat rate: re-press only. */
        [self sendKeyCode:event.keyCode down:YES];
        return;
    }
    [self sendKeyCode:event.keyCode down:YES];
}

- (void)keyUp:(NSEvent *)event
{
    [self sendKeyCode:event.keyCode down:NO];
}

/* macOS never delivers keyDown/keyUp for modifiers; it delivers one
 * flagsChanged per physical transition.  Derive press vs release from the
 * device-dependent bit for that specific key, falling back to the generic
 * mask when the driver does not set one. */
- (void)flagsChanged:(NSEvent *)event
{
    NSUInteger flags = event.modifierFlags;
    unsigned short kc = event.keyCode;
    NSUInteger devBit = 0, genericBit = 0;
    BOOL down;

    switch (kc) {
    case VSM_KC_LSHIFT: devBit = VSM_DEV_LSHIFT; genericBit = NSEventModifierFlagShift;   break;
    case VSM_KC_RSHIFT: devBit = VSM_DEV_RSHIFT; genericBit = NSEventModifierFlagShift;   break;
    case VSM_KC_LCTRL:  devBit = VSM_DEV_LCTRL;  genericBit = NSEventModifierFlagControl; break;
    case VSM_KC_RCTRL:  devBit = VSM_DEV_RCTRL;  genericBit = NSEventModifierFlagControl; break;
    case VSM_KC_LALT:   devBit = VSM_DEV_LALT;   genericBit = NSEventModifierFlagOption;  break;
    case VSM_KC_RALT:   devBit = VSM_DEV_RALT;   genericBit = NSEventModifierFlagOption;  break;
    case VSM_KC_LCMD:   devBit = VSM_DEV_LCMD;   genericBit = NSEventModifierFlagCommand; break;
    case VSM_KC_RCMD:   devBit = VSM_DEV_RCMD;   genericBit = NSEventModifierFlagCommand; break;
    case VSM_KC_CAPS:
        /* Caps Lock latches on macOS: one event per physical press, with the
         * flag toggling.  The guest wants a full press/release either way. */
        [self sendKeyCode:kc down:YES];
        [self sendKeyCode:kc down:NO];
        return;
    default:
        return;
    }

    down = (flags & devBit) ? YES : (((flags & genericBit) && !(flags & 0x0000ffff)) ? YES : NO);

    NSNumber *key = @(kc);
    if (down == [_heldModifierKeyCodes containsObject:key])
        return;                       /* no transition for this key */
    if (down)
        [_heldModifierKeyCodes addObject:key];
    else
        [_heldModifierKeyCodes removeObject:key];
    [self sendKeyCode:kc down:down];
}

- (void)releaseAllKeys
{
    [_heldModifierKeyCodes removeAllObjects];
    _buttonState = 0;
    vsm_spice_release_all_keys(self.spice);
}

/* --------------------------------------------------------------- cursor */

/* A fully transparent 1x1 cursor.  This is how "the guest hid the pointer"
 * is expressed: -[NSCursor hide] is application-global and survives focus
 * loss, so it would leave the user with no pointer anywhere on the desktop
 * if the guest hid its cursor and the app then lost focus.  A transparent
 * image scoped to the view's cursor rect has neither problem. */
+ (NSCursor *)blankCursor
{
    static NSCursor *blank;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
        [image lockFocus];
        [NSColor.clearColor set];
        NSRectFill(NSMakeRect(0, 0, 1, 1));
        [image unlockFocus];
        blank = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
    });
    return blank;
}

/* The cursor actually shown while the pointer is inside the view. */
- (NSCursor *)effectiveCursor
{
    if (_cursorHidden)
        return [VsmView blankCursor];
    return _guestCursor ?: NSCursor.arrowCursor;
}

/* Cursor rects are per-view, so the pointer reverts to whatever the system
 * would otherwise show as soon as it leaves the guest area -- over the title
 * bar, over another window, anywhere outside. */
- (void)resetCursorRects
{
    [self addCursorRect:self.bounds cursor:[self effectiveCursor]];
}

/* Re-ask AppKit for the rects so a shape that changed while the pointer is
 * already inside the view takes effect immediately. */
- (void)refreshCursorRects
{
    [self.window invalidateCursorRectsForView:self];
    if (NSPointInRect([self convertPoint:self.window.mouseLocationOutsideOfEventStream
                                fromView:nil],
                      self.bounds))
        [[self effectiveCursor] set];
}

- (void)setGuestCursor:(NSCursor *)cursor
{
    /* ARC drops the previous NSCursor (and with it its NSImage and bitmap
     * backing) here, so a session's worth of cursor-defines costs one live
     * cursor, not thousands. */
    _guestCursor = cursor;
    _cursorHidden = NO;
    [self refreshCursorRects];
}

- (void)hideGuestCursor
{
    _cursorHidden = YES;
    [self refreshCursorRects];
}

- (void)resetGuestCursor
{
    _guestCursor = nil;
    _cursorHidden = NO;
    [self refreshCursorRects];
}

/* ---------------------------------------------------------------- mouse */

/* View point -> guest pixel, honouring the aspect-fit letterboxing that
 * kCAGravityResizeAspect applies. */
- (BOOL)guestPointFor:(NSEvent *)event x:(int *)outX y:(int *)outY
{
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSSize size = self.bounds.size;
    double gw = self.guestWidth, gh = self.guestHeight;
    double scale, drawW, drawH, originX, originY, gx, gy;

    if (gw <= 0 || gh <= 0 || size.width <= 0 || size.height <= 0)
        return NO;

    scale = MIN(size.width / gw, size.height / gh);
    drawW = gw * scale;
    drawH = gh * scale;
    originX = (size.width - drawW) / 2.0;
    originY = (size.height - drawH) / 2.0;

    gx = (p.x - originX) / scale;
    gy = (p.y - originY) / scale;
    if (gx < 0 || gy < 0 || gx >= gw || gy >= gh)
        return NO;

    *outX = (int)gx;
    *outY = (int)gy;
    return YES;
}

- (void)sendMotion:(NSEvent *)event
{
    int x = 0, y = 0;
    if (![self guestPointFor:event x:&x y:&y])
        return;
    if (vsm_trace)
        NSLog(@"motion %d,%d buttons=0x%x", x, y, _buttonState);
    vsm_spice_send_position(self.spice, x, y, _buttonState);
}

- (void)mouseMoved:(NSEvent *)event      { [self sendMotion:event]; }
- (void)mouseDragged:(NSEvent *)event    { [self sendMotion:event]; }
- (void)rightMouseDragged:(NSEvent *)e   { [self sendMotion:e]; }
- (void)otherMouseDragged:(NSEvent *)e   { [self sendMotion:e]; }

- (void)sendButton:(int)button mask:(int)mask down:(BOOL)down event:(NSEvent *)event
{
    [self sendMotion:event];
    if (down)
        _buttonState |= mask;
    else
        _buttonState &= ~mask;
    if (vsm_trace)
        NSLog(@"button %d %@ state=0x%x", button, down ? @"press" : @"release",
              _buttonState);
    vsm_spice_send_button(self.spice, button, down ? 1 : 0, _buttonState);
}

- (void)mouseDown:(NSEvent *)e       { [self sendButton:VSM_BUTTON_LEFT   mask:VSM_MASK_LEFT   down:YES event:e]; }
- (void)mouseUp:(NSEvent *)e         { [self sendButton:VSM_BUTTON_LEFT   mask:VSM_MASK_LEFT   down:NO  event:e]; }
- (void)rightMouseDown:(NSEvent *)e  { [self sendButton:VSM_BUTTON_RIGHT  mask:VSM_MASK_RIGHT  down:YES event:e]; }
- (void)rightMouseUp:(NSEvent *)e    { [self sendButton:VSM_BUTTON_RIGHT  mask:VSM_MASK_RIGHT  down:NO  event:e]; }
- (void)otherMouseDown:(NSEvent *)e  { [self sendButton:VSM_BUTTON_MIDDLE mask:VSM_MASK_MIDDLE down:YES event:e]; }
- (void)otherMouseUp:(NSEvent *)e    { [self sendButton:VSM_BUTTON_MIDDLE mask:VSM_MASK_MIDDLE down:NO  event:e]; }

- (void)scrollWheel:(NSEvent *)event
{
    /* Trackpads deliver fractional deltas; accumulate into whole notches. */
    static double accum;
    int steps;

    accum += event.hasPreciseScrollingDeltas
        ? event.scrollingDeltaY / 10.0
        : event.scrollingDeltaY;
    steps = (int)accum;
    if (!steps)
        return;
    accum -= steps;
    if (vsm_trace)
        NSLog(@"scroll %d steps", steps);
    vsm_spice_send_scroll(self.spice, steps, _buttonState);
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    for (NSTrackingArea *area in [self.trackingAreas copy])
        [self removeTrackingArea:area];
    [self addTrackingArea:
        [[NSTrackingArea alloc] initWithRect:self.bounds
                                     options:(NSTrackingMouseMoved |
                                              NSTrackingActiveInKeyWindow |
                                              NSTrackingInVisibleRect)
                                       owner:self
                                    userInfo:nil]];
}

@end

/* ------------------------------------------------------------- delegate */

@interface VsmAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) VsmView *view;
@property (nonatomic, assign) VsmSpice *spice;
@property (nonatomic, copy)   NSString *uri;
@property (nonatomic, strong) dispatch_source_t dumpSource;
@property (nonatomic, assign) BOOL selftestDone;
@property (nonatomic, assign) BOOL cursorSelftestDone;
@end

@implementation VsmAppDelegate

- (void)buildMenu
{
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];

    [appMenu addItemWithTitle:@"Quit"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];
    NSApp.mainMenu = bar;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    NSRect frame = NSMakeRect(0, 0, 800, 600);

    [self buildMenu];

    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = self.uri;
    self.window.delegate = self;
    self.window.acceptsMouseMovedEvents = YES;
    self.window.releasedWhenClosed = NO;

    self.view = [[VsmView alloc] initWithFrame:frame];
    self.view.spice = self.spice;
    self.window.contentView = self.view;
    self.view.layer.contentsScale = self.window.backingScaleFactor;

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.view];
    [NSApp activateIgnoringOtherApps:YES];

    [self installDumpSignalHandler];
    vsm_spice_start(self.spice);
}

/* SIGUSR1 writes the guest framebuffer to $VSM_DUMP_DIR/frame-N.png.  This
 * is the only way to see what the client is displaying on a machine whose
 * login session is locked, where screencapture(1) returns the lock screen. */
- (void)installDumpSignalHandler
{
    NSString *dir = NSProcessInfo.processInfo.environment[@"VSM_DUMP_DIR"];
    if (!dir)
        return;

    signal(SIGUSR1, SIG_IGN);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                   SIGUSR1, 0,
                                                   dispatch_get_main_queue());
    __block int seq = 0;
    dispatch_source_set_event_handler(src, ^{
        NSString *path = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"frame-%d.png", ++seq]];
        NSRect content = [self.window contentRectForFrameRect:self.window.frame];
        NSLog(@"window: title=\"%@\" content=%.0fx%.0f pt, backing scale %.1f, "
              @"layer contentsScale %.1f",
              self.window.title, content.size.width, content.size.height,
              self.window.backingScaleFactor, self.view.layer.contentsScale);
        vsm_dump_surface(self.spice, path);
    });
    dispatch_resume(src);
    self.dumpSource = src;
    NSLog(@"SIGUSR1 will dump frames to %@", dir);
}

- (void)primaryCreatedWidth:(int)width height:(int)height
{
    CGFloat scale = self.window.backingScaleFactor ?: 1.0;

    self.view.guestWidth = width;
    self.view.guestHeight = height;
    /* One guest pixel per physical display pixel: on a 2x Retina panel the
     * window is half as many points wide as the guest is pixels, and the
     * compositor does no resampling. */
    [self.window setContentSize:NSMakeSize(width / scale, height / scale)];
    self.window.contentAspectRatio = NSMakeSize(width, height);
    [self.view refreshSurface];
    NSLog(@"primary surface %dx%d (backing scale %.1f)", width, height, scale);

    if (!self.cursorSelftestDone &&
        NSProcessInfo.processInfo.environment[@"VSM_CURSOR_SELFTEST"]) {
        self.cursorSelftestDone = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            vsm_run_cursor_selftest(self.view);
        });
    }

    if (!self.selftestDone &&
        NSProcessInfo.processInfo.environment[@"VSM_SELFTEST"]) {
        self.selftestDone = YES;
        /* Give the guest a moment to settle, then replay the script. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            vsm_run_input_selftest(self.view, self.window);
            if (NSProcessInfo.processInfo.environment[@"VSM_SELFTEST_QUIT"]) {
                /* Same selector the Cmd-Q menu item sends, so this exercises
                 * the real quit path: release-all-keys, disconnect, join. */
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                               dispatch_get_main_queue(), ^{
                    NSLog(@"selftest: terminating via the Cmd-Q action");
                    [NSApp terminate:nil];
                });
            }
        });
    }
}

- (void)windowDidResignKey:(NSNotification *)note   { [self.view releaseAllKeys]; }
- (void)applicationDidResignActive:(NSNotification *)n { [self.view releaseAllKeys]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

- (void)applicationWillTerminate:(NSNotification *)note
{
    [self.view releaseAllKeys];
    vsm_spice_stop(self.spice);
    NSLog(@"disconnected cleanly");
}

@end

/* -------------------------------------------------------------- C glue */

static VsmAppDelegate *g_delegate;

static void cb_primary_create(void *user, int width, int height)
{
    [(__bridge VsmAppDelegate *)user primaryCreatedWidth:width height:height];
}

static void cb_damaged(void *user, int x, int y, int w, int h)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;
    if (vsm_trace)
        NSLog(@"damage %d,%d %dx%d", x, y, w, h);
    [self.view refreshSurface];
}

/* Build an NSCursor from the guest's RGBA bytes.  The shape is treated as
 * 1x points: a guest cursor is authored in guest pixels and the view shows
 * guest pixels, so one cursor pixel is one point.  On a 2x panel that means
 * the shape is drawn at 2x2 physical pixels per cursor pixel -- softer than
 * a native cursor, but the correct size next to the guest content, which is
 * what a pointer has to be.  A Retina-aware (2x) cursor would need the guest
 * to author one, and SPICE has no way to ask for it. */
NSCursor *vsm_cursor_from_rgba(int width, int height,
                               int hot_x, int hot_y,
                               const uint8_t *rgba)
{
    NSBitmapImageRep *rep;
    NSImage *image;

    /* bitmapFormat 0 = premultiplied alpha, RGBA byte order -- exactly what
     * channel-cursor.c produces (it byte-swaps its BGRA words for us). */
    rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:width
                      pixelsHigh:height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                    bitmapFormat:0
                     bytesPerRow:width * 4
                    bitsPerPixel:32];
    if (!rep)
        return nil;
    memcpy(rep.bitmapData, rgba, (size_t)width * (size_t)height * 4);

    image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [image addRepresentation:rep];

    /* The hotspot is in the image's own (top-left origin) coordinates, which
     * is how SPICE expresses it too. */
    return [[NSCursor alloc] initWithImage:image
                                   hotSpot:NSMakePoint(hot_x, hot_y)];
}

static void cb_cursor_define(void *user, int width, int height,
                             int hot_x, int hot_y, const uint8_t *rgba)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;
    NSCursor *cursor;

    if (vsm_trace)
        NSLog(@"cursor-define %dx%d hotspot %d,%d", width, height, hot_x, hot_y);
    cursor = vsm_cursor_from_rgba(width, height, hot_x, hot_y, rgba);
    /* vsm-spice.c handed the copy over; NSBitmapImageRep took its own. */
    free((void *)rgba);
    if (cursor)
        [self.view setGuestCursor:cursor];
}

static void cb_cursor_hide(void *user)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;
    if (vsm_trace)
        NSLog(@"cursor-hide");
    [self.view hideGuestCursor];
}

static void cb_cursor_reset(void *user)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;
    if (vsm_trace)
        NSLog(@"cursor-reset");
    [self.view resetGuestCursor];
}

static void cb_title(void *user, const char *title)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;
    self.window.title = @(title);
}

static void cb_status(void *user, const char *status)
{
    (void)user;
    NSLog(@"%s", status);
}

static void cb_disconnected(void *user, const char *reason)
{
    (void)user;
    NSLog(@"disconnected: %s", reason);
    [NSApp terminate:nil];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        VsmSpiceCallbacks cb = {
            .primary_create = cb_primary_create,
            .damaged        = cb_damaged,
            .title          = cb_title,
            .status         = cb_status,
            .disconnected   = cb_disconnected,
            .cursor_define  = cb_cursor_define,
            .cursor_hide    = cb_cursor_hide,
            .cursor_reset   = cb_cursor_reset,
        };

        if (argc != 2) {
            fprintf(stderr, "usage: %s spice://HOST:PORT\n", argv[0]);
            return 2;
        }
        vsm_trace = getenv("VSM_TRACE") && *getenv("VSM_TRACE") == '1';

        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyRegular;

        g_delegate = [[VsmAppDelegate alloc] init];
        g_delegate.uri = @(argv[1]);
        g_delegate.spice = vsm_spice_new(argv[1], &cb, (__bridge void *)g_delegate);
        NSApp.delegate = g_delegate;

        [NSApp run];
    }
    return 0;
}
