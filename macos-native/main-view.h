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
@end

#endif /* MAIN_VIEW_H */
