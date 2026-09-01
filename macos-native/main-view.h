/*
 * main-view.h: the framebuffer view, shared with the debug helpers.
 */
#ifndef MAIN_VIEW_H
#define MAIN_VIEW_H

#import <Cocoa/Cocoa.h>

#include "vsm-spice.h"

/* Layer-backed view whose layer contents is the guest framebuffer IOSurface,
 * and whose responder methods forward keyboard and absolute mouse input to
 * the SPICE inputs channel. */
@interface VsmView : NSView
@property (nonatomic, assign) VsmSpice *spice;
@property (nonatomic, assign) int guestWidth;
@property (nonatomic, assign) int guestHeight;

/* Rebind the layer to the current IOSurface so CA re-reads its bytes. */
- (void)refreshSurface;
/* Release every key the guest still thinks is held (focus loss, quit). */
- (void)releaseAllKeys;

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
