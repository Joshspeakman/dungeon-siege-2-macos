// The launch window: the game or its Test Lab, its settings in groups (Display, Graphics, Audio, Online, Updates),
// remembered in <data>/launcher.plist, then Play. Dressed as the game is: frames of its own cutscenes and the store's key
// art drifting and crossfading behind it, embers and motes of magic rising, mist rolling, the game's own logo over a fire
// glow, a portrait in a riveted iron frame, the main menu's red stone and its wooden bars for Quit and Play, Copperplate.
// Art, each optional (<data>/art, else Contents/Resources/art; recomp/tools/ds2_art.py makes it at install, from the
// player's own copy and, with --store, Steam's; what is missing of Steam's is fetched here into <data>/art):
//   scene-<n>.jpg      frames of the game's cutscenes (its Bink movies, decoded with ffmpeg): the backdrop's slides
//   portrait.jpg       a frame for the portrait; card-game.jpg, card-lab.jpg the Game cards' pictures
//   store-portrait.jpg Steam's library capsule (the portrait), store-hero.jpg its key art (a slide that pans; banner.jpg
//                      from install.sh is the same), store-shot-<n>.jpg its screenshots (slides)
// The logo, the red backdrop and the wooden bars are read at launch from the player's own Resources/Objects.ds2res.
// Nothing from the game is stored in this project; without any of it the window falls back to plain colours.
// Development: DS_LAUNCHER_SHOT=<png> renders the window (twice its size) and returns (DS_LAUNCHER_PAGE=<n> a group
// opened, DS_LAUNCHER_FOCUS=<n> the keyboard focus on place n, DS_LAUNCHER_TIME=<s> the animation's clock,
// DS_LAUNCHER_ART=<folder> the art from there only, DS_LAUNCHER_OFFLINE=1 nothing fetched, DS_LAUNCHER_TIMING=1 what a
// frame costs drawn offscreen); DS_LAUNCHER_HOME=<folder> the launcher's settings and art from there instead of the data
// folder; DS_LAUNCHER_PLAY=1 presses Play once the window is up.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <CommonCrypto/CommonDigest.h>
#include <zlib.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>

// ---------------------------------------------------------------- reading textures from a tank (.dsres) archive
static NSData *tank_read(NSString *tankPath, NSString *want)
{
    NSData *file = [NSData dataWithContentsOfFile:tankPath options:NSDataReadingMappedIfSafe error:nil];
    if (file.length < 64) return nil;
    const uint8_t *d = file.bytes; size_t n = file.length;
    #define U32(o) (*(const uint32_t *)(d + (o)))
    #define U16(o) (*(const uint16_t *)(d + (o)))
    if (memcmp(d, "DSigTank", 8) && memcmp(d, "DSg2Tank", 8)) return nil;   /* Dungeon Siege, Dungeon Siege II */
    uint32_t dirset = U32(12), fileset = U32(16), dataoff = U32(24);
    if (dirset >= n || fileset >= n) return nil;
    NSMutableDictionary<NSNumber *, NSString *> *dirs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *parents = [NSMutableDictionary dictionary];
    for (uint32_t k = 0, nd = U32(dirset); k < nd; k++) {
        uint32_t off = U32(dirset + 4 + 4 * k), o = dirset + off; uint16_t len = U16(o + 16);
        dirs[@(off)] = [[NSString alloc] initWithBytes:d + o + 18 length:len encoding:NSISOLatin1StringEncoding];
        parents[@(off)] = @(U32(o));
    }
    NSString *(^path)(uint32_t) = ^NSString *(uint32_t off) {
        NSMutableArray *parts = [NSMutableArray array];
        for (int guard = 0; guard < 64 && dirs[@(off)].length; guard++) { [parts insertObject:dirs[@(off)] atIndex:0]; uint32_t p = parents[@(off)].unsignedIntValue; if (p == off) break; off = p; }
        return [parts componentsJoinedByString:@"/"];
    };
    for (uint32_t k = 0, nf = U32(fileset); k < nf; k++) {
        uint32_t o = fileset + U32(fileset + 4 + 4 * k), parent = U32(o), size = U32(o + 4), foff = U32(o + 8); uint16_t fmt = U16(o + 24), len = U16(o + 28);
        NSString *name = [[NSString alloc] initWithBytes:d + o + 30 length:len encoding:NSISOLatin1StringEncoding];
        if ([[NSString stringWithFormat:@"%@/%@", path(parent), name] caseInsensitiveCompare:want] != NSOrderedSame) continue;
        uint32_t o2 = (o + 30 + len + 1 + 3) & ~3u;
        if (fmt == 0) return dataoff + foff + size <= n ? [NSData dataWithBytes:d + dataoff + foff length:size] : nil;
        uint32_t chunk = U32(o2 + 4); o2 += 8;
        NSMutableData *out = [NSMutableData dataWithCapacity:size];
        for (uint32_t c = 0; c < (size + chunk - 1) / chunk; c++) {
            uint32_t usz = U32(o2 + 16 * c), csz = U32(o2 + 16 * c + 4), extra = U32(o2 + 16 * c + 8), coff = U32(o2 + 16 * c + 12);
            const uint8_t *src = d + dataoff + foff + coff;
            if (dataoff + foff + coff + csz + extra > n) return nil;
            if (csz < usz) { NSMutableData *u = [NSMutableData dataWithLength:usz]; uLongf ul = usz;
                if (uncompress(u.mutableBytes, &ul, src, csz) != Z_OK) return nil; u.length = ul; [out appendData:u]; }
            else [out appendBytes:src length:usz];
            if (extra) [out appendBytes:src + csz length:extra];
        }
        out.length = size; return out;
    }
    return nil;
    #undef U32
    #undef U16
}
/* a DDS texture (DXT-compressed or not) -> CGImage, through ImageIO */
static CGImageRef dds_image(NSData *d)
{
    if (d.length < 128 || memcmp(d.bytes, "DDS ", 4)) return NULL;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)d, NULL); if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL); CFRelease(src); return img;
}
static NSImage *nsimg(CGImageRef img, CGRect crop)
{
    if (!img) return nil;
    CGImageRef c = CGRectIsEmpty(crop) ? CGImageRetain(img) : CGImageCreateWithImageInRect(img, crop);
    NSImage *r = [[NSImage alloc] initWithCGImage:c size:NSZeroSize]; CGImageRelease(c); return r;
}
/* the part of an image with any opacity */
static CGRect opaque_bounds(CGImageRef img)
{
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img); uint8_t *px = calloc(w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB(); CGContextRef c = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);
    size_t x0 = w, y0 = h, x1 = 0, y1 = 0;
    for (size_t y = 0; y < h; y++) for (size_t x = 0; x < w; x++) if (px[(y * w + x) * 4 + 3] > 8) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    CGContextRelease(c); CGColorSpaceRelease(cs); free(px);
    return x1 >= x0 ? CGRectMake(x0, y0, x1 - x0 + 1, y1 - y0 + 1) : CGRectZero;   /* bitmap rows run top-down here */
}

// ---------------------------------------------------------------- settings
typedef struct { NSString *value, *label, *note; } Choice;
@interface DSRow : NSObject
@property NSString *title; @property NSArray<NSDictionary *> *choices; @property NSInteger index;
@property (copy) void (^activate)(void);     /* a row that opens something instead of cycling (Mods) */
@end
@implementation DSRow @end

static NSColor *rgb(double r, double g, double b, double a) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
static NSColor *gold(void) { return rgb(0.86, 0.77, 0.55, 1); }      /* the menus' brass */
static NSColor *parchment(void) { return rgb(0.94, 0.91, 0.84, 1); }
static NSColor *dim(void) { return rgb(0.66, 0.61, 0.52, 1); }
static NSColor *ember(double a) { return rgb(0.92, 0.36, 0.10, a); } /* the logo's fire */
static NSColor *blood(double a) { return rgb(0.42, 0.05, 0.03, a); } /* the main menu's red */
static NSFont *cp(CGFloat size, BOOL bold)
{
    NSFont *f = [NSFont fontWithName:bold ? @"Copperplate-Bold" : @"Copperplate-Light" size:size] ?: [NSFont fontWithName:@"Copperplate" size:size];
    return f ?: [NSFont systemFontOfSize:size weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
}
static NSFont *book(CGFloat size, BOOL italic)   /* the blurb and the notes: a book face, as the game's journal */
{
    return [NSFont fontWithName:italic ? @"Palatino-Italic" : @"Palatino-Roman" size:size] ?: [NSFont systemFontOfSize:size];
}
static double hash01(double x) { double s = sin(x * 12.9898) * 43758.5453; return s - floor(s); }   /* a fixed random number in 0..1 */

// ---------------------------------------------------------------- pictures
/* an image drawn to fill r (cropped to its shape), zoomed by z about a point (fx, fy in 0..1 of the picture, from the top) */
static NSImageInterpolation fill_interp = NSImageInterpolationHigh;   /* (the moving backdrop: Medium, cheaper per frame) */
static void draw_fill_z(NSImage *img, NSRect r, CGFloat alpha, CGFloat z, CGFloat fx, CGFloat fy)
{
    if (!img) return; NSSize s = img.size; if (s.width <= 0 || s.height <= 0) return;
    CGFloat k = MAX(r.size.width / s.width, r.size.height / s.height) * z, w = r.size.width / k, h = r.size.height / k;
    CGFloat x = (s.width - w) * fx, y = (s.height - h) * (1 - fy);                      /* (image space is bottom-up) */
    [img drawInRect:r fromRect:NSMakeRect(x, y, w, h) operation:NSCompositingOperationSourceOver fraction:alpha respectFlipped:YES hints:@{NSImageHintInterpolation: @(fill_interp)}];
}
/* a picture of size points at scale pixels per point, drawn by draw() the way the window draws (top-down) */
static NSImage *offscreen(NSSize size, CGFloat scale, void (^draw)(void))
{
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)ceil(size.width * scale) pixelsHigh:(NSInteger)ceil(size.height * scale)
                                                                 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep = [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace] ?: rep;   /* (as the window's: no conversion per frame) */
    rep.size = size;
    CGContextRef cg = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep].CGContext;
    [NSGraphicsContext saveGraphicsState];
    CGContextTranslateCTM(cg, 0, size.height); CGContextScaleCTM(cg, 1, -1);
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES]];
    draw();
    [NSGraphicsContext restoreGraphicsState];
    NSImage *img = [[NSImage alloc] initWithSize:size]; [img addRepresentation:rep];
    return img;
}
/* a picture made ready to draw every frame: decoded once, at most maxw pixels wide */
static NSImage *ready(NSImage *img, CGFloat maxw)
{
    if (!img || img.size.width < 16) return nil;
    NSSize s = img.size; NSInteger pw = 0, ph = 0;                     /* (its pixels: a JPEG at 300 dpi is small in points) */
    for (NSImageRep *r in img.representations) if (r.pixelsWide > pw) { pw = r.pixelsWide; ph = r.pixelsHigh; }
    if (pw > 0 && ph > 0) s = NSMakeSize(pw, ph);
    CGFloat k = MIN(1.0, maxw / s.width);
    return offscreen(NSMakeSize(round(s.width * k), round(s.height * k)), 1, ^{
        [img drawInRect:NSMakeRect(0, 0, round(s.width * k), round(s.height * k)) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES
                  hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}]; });
}

// ---------------------------------------------------------------- the view
/* The window, dressed as the game is: its cutscenes and key art drifting and crossfading behind it, embers and motes
 * of magic rising, mist rolling, its own logo over a fire glow, a portrait in an iron frame, the main menu's wooden bars
 * for Quit and Play. The Game row is two cards (the game, the Test Lab); each group of settings is a tile (Display,
 * Graphics, Audio, Online, Updates) that opens as a panel over the window, with Back where Quit was. */
@interface DSSection : NSObject
@property NSString *title; @property NSArray<DSRow *> *rows;
@property (copy) void (^activate)(void); @property (copy) NSString *(^summary)(void);
@end
@implementation DSSection @end

@interface DSLaunchView : NSView
@property NSArray<DSRow *> *top; @property NSArray<DSSection *> *sections; @property NSInteger open;   /* the open group, -1 none */
@property NSInteger focus; @property NSInteger hover; @property NSInteger pressed; @property BOOL keyed;   /* keyed: the focus ring shows */
@property NSImage *banner, *stone, *logo, *wood, *woodHover, *woodDown; @property NSString *note;
@property NSArray<NSImage *> *scenes, *cards; @property NSImage *portrait; @property CGFloat portraitFx, portraitFy, portraitZ;
@property double t; @property NSMutableDictionary *cache; @property NSInteger artGen;   /* pictures drawn once (cleared when the art changes) */
@property (copy) void (^onPlay)(void); @property (copy) void (^onQuit)(void); @property (copy) void (^onChange)(void);
@property (copy) void (^onSaves)(void); @property (copy) void (^onFiles)(void);
@end

/* hit codes: rows in an open group 10*row + 0 (left arrow) / 1 (value) / 2 (right arrow); the cards, the tiles */
enum { HIT_NONE = -1, HIT_PLAY = 100, HIT_QUIT = 101, HIT_BACK = 102, HIT_SAVES = 103, HIT_FILES = 104, HIT_SECTION = 200, HIT_CARD = 300 };
/* the keyboard's places at the top level: the cards (0), the tiles (1..), then Saves, Game Files, Quit, Play */
enum { NBOTTOM = 4 };

@implementation DSLaunchView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (NSArray<DSRow *> *)rows { return self.open >= 0 ? self.sections[self.open].rows : self.top; }
- (NSInteger)firstTile { return (NSInteger)self.top.count; }
- (NSInteger)firstBottom { return (NSInteger)self.top.count + (NSInteger)self.sections.count; }
- (NSInteger)items { return self.open >= 0 ? (NSInteger)self.rows.count : self.firstBottom + NBOTTOM; }   /* what the keyboard moves between */
/* ---- layout (points; the view is 980 x 660) ---- */
- (CGFloat)scale { return self.window ? self.window.backingScaleFactor : 2; }
- (NSRect)titleBox { return NSMakeRect(48, 26, 504, 150); }
- (NSRect)portraitRect { return NSMakeRect(self.bounds.size.width - 48 - 300, 50, 300, 372); }
- (NSRect)cardRect:(NSInteger)k { NSInteger n = MAX(1, (NSInteger)self.top.firstObject.choices.count); CGFloat gap = 14, w = (504 - (n - 1) * gap) / n; return NSMakeRect(48 + k * (w + gap), 300, w, 122); }
- (NSRect)sectionRect:(NSInteger)i { NSInteger n = MAX(1, (NSInteger)self.sections.count); CGFloat gap = 12, w = (self.bounds.size.width - 96 - (n - 1) * gap) / n; return NSMakeRect(48 + i * (w + gap), 462, w, 84); }
- (NSRect)savesRect { return NSMakeRect(48, 576, 112, 40); }
- (NSRect)filesRect { return NSMakeRect(48 + 122, 576, 136, 40); }
- (NSRect)playRect { CGFloat W = self.bounds.size.width; return NSMakeRect(W - 48 - 236, 566, 236, 58); }
- (NSRect)quitRect { CGFloat W = self.bounds.size.width; return NSMakeRect(W - 48 - 236 - 14 - 176, 568, 176, 54); }
- (NSRect)flyRect { NSRect b = self.bounds; return NSMakeRect(48, 34, b.size.width - 96, 516); }   /* an open group's panel, above Back and Play */
- (NSRect)rowRect:(NSInteger)k { NSRect f = self.flyRect; return NSMakeRect(f.origin.x + 44, f.origin.y + 80 + 68 * k, f.size.width - 88, 60); }
- (NSRect)arrow:(NSInteger)k right:(BOOL)right { NSRect r = [self rowRect:k]; return NSMakeRect(right ? NSMaxX(r) - 34 : NSMaxX(r) - 340, r.origin.y + 4, 30, 30); }
- (NSRect)valueRect:(NSInteger)k { NSRect r = [self rowRect:k]; return NSMakeRect(NSMaxX(r) - 304, r.origin.y + 7, 266, 30); }
/* the rect of a keyboard place at the top level */
- (NSRect)placeRect:(NSInteger)f
{
    if (f < self.firstTile) return NSUnionRect([self cardRect:0], [self cardRect:(NSInteger)self.top.firstObject.choices.count - 1]);
    if (f < self.firstBottom) return [self sectionRect:f - self.firstTile];
    switch (f - self.firstBottom) { case 0: return self.savesRect; case 1: return self.filesRect; case 2: return self.quitRect; default: return self.playRect; }
}
- (NSInteger)hit:(NSPoint)p
{
    if (NSPointInRect(p, self.playRect)) return HIT_PLAY;
    if (NSPointInRect(p, self.quitRect)) return self.open >= 0 ? HIT_BACK : HIT_QUIT;
    if (self.open < 0) {
        if (NSPointInRect(p, self.savesRect)) return HIT_SAVES;
        if (NSPointInRect(p, self.filesRect)) return HIT_FILES;
        for (NSInteger i = 0; i < (NSInteger)self.sections.count; i++) if (NSPointInRect(p, [self sectionRect:i])) return HIT_SECTION + i;
        for (NSInteger k = 0; k < (NSInteger)self.top.firstObject.choices.count; k++) if (NSPointInRect(p, [self cardRect:k])) return HIT_CARD + k;
        return HIT_NONE;
    }
    for (NSInteger k = 0; k < (NSInteger)self.rows.count; k++) {
        if (NSPointInRect(p, [self arrow:k right:NO])) return 10 * k;
        if (NSPointInRect(p, [self arrow:k right:YES])) return 10 * k + 2;
        if (NSPointInRect(p, [self valueRect:k])) return 10 * k + 1;
    }
    if (!NSPointInRect(p, self.flyRect)) return HIT_BACK;            /* a click outside the panel closes it */
    return HIT_NONE;
}
- (void)openSection:(NSInteger)i
{
    DSSection *s = self.sections[i]; self.focus = self.firstTile + i;
    if (s.activate) { s.activate(); self.needsDisplay = YES; return; }
    self.open = i; self.focus = 0; self.hover = HIT_NONE; self.needsDisplay = YES;
}
- (void)closeSection { if (self.open < 0) return; self.focus = self.firstTile + self.open; self.open = -1; self.hover = HIT_NONE; self.needsDisplay = YES; }
- (void)chooseCard:(NSInteger)k
{
    DSRow *r = self.top.firstObject; if (!r || k == r.index) return;
    r.index = k; self.needsDisplay = YES; if (self.onChange) self.onChange();
}
- (void)updateTrackingAreas
{
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e { NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]]; if (h != self.hover) { self.hover = h; self.needsDisplay = YES; } }
- (void)mouseDown:(NSEvent *)e { self.pressed = [self hit:[self convertPoint:e.locationInWindow fromView:nil]]; self.keyed = NO; self.needsDisplay = YES; }
- (void)mouseUp:(NSEvent *)e
{
    NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]], p = self.pressed; self.pressed = HIT_NONE; self.needsDisplay = YES;
    if (h != p || h == HIT_NONE) return;
    [self press:h];
}
- (void)press:(NSInteger)h
{
    if (h == HIT_PLAY) { if (self.onPlay) self.onPlay(); return; }
    if (h == HIT_QUIT) { if (self.onQuit) self.onQuit(); return; }
    if (h == HIT_BACK) { [self closeSection]; return; }
    if (h == HIT_SAVES) { if (self.onSaves) self.onSaves(); return; }
    if (h == HIT_FILES) { if (self.onFiles) self.onFiles(); return; }
    if (h >= HIT_CARD) { self.focus = 0; [self chooseCard:h - HIT_CARD]; return; }
    if (h >= HIT_SECTION) { [self openSection:h - HIT_SECTION]; return; }
    NSInteger k = h / 10; self.focus = k;
    if (self.rows[k].activate) { self.rows[k].activate(); self.needsDisplay = YES; return; }
    [self step:k by:(h % 10 == 0) ? -1 : 1];
}
- (void)step:(NSInteger)k by:(NSInteger)dir
{
    DSRow *r = self.rows[k]; NSInteger n = (NSInteger)r.choices.count;
    if (r.activate) { r.activate(); self.needsDisplay = YES; return; }
    r.index = (r.index + dir + n) % n; self.needsDisplay = YES;
    if (self.onChange) self.onChange();
}
/* one step from the keyboard or a controller. An open group: up and down move between its rows, left and right change
 * the row. The top level: the cards (left and right choose), the tiles and the buttons along their rows (round), up and
 * down to the nearest of the next row. Return: the cards play, a tile opens, a button presses. */
enum { NAV_LEFT = 1, NAV_RIGHT, NAV_UP, NAV_DOWN, NAV_OK, NAV_BACK, NAV_PLAY };
- (void)nav:(int)n
{
    self.keyed = YES; self.needsDisplay = YES;
    if (n == NAV_PLAY) { if (self.onPlay) self.onPlay(); return; }
    if (self.open >= 0) {
        NSInteger rc = (NSInteger)self.rows.count;
        switch (n) {
        case NAV_BACK: [self closeSection]; return;
        case NAV_UP: self.focus = (self.focus + rc - 1) % rc; return;
        case NAV_DOWN: self.focus = (self.focus + 1) % rc; return;
        case NAV_LEFT: case NAV_RIGHT: [self step:self.focus by:n == NAV_LEFT ? -1 : 1]; return;
        case NAV_OK: if (self.rows[self.focus].activate) { self.rows[self.focus].activate(); return; } [self closeSection]; return;
        }
        return;
    }
    NSInteger f = self.focus, t0 = self.firstTile, b0 = self.firstBottom, end = b0 + NBOTTOM;
    int row = f < t0 ? 0 : f < b0 ? 1 : 2;
    switch (n) {
    case NAV_BACK: if (self.onQuit) self.onQuit(); return;
    case NAV_OK:
        if (row == 0) { if (self.onPlay) self.onPlay(); return; }
        if (row == 1) { [self openSection:f - t0]; return; }
        { static const NSInteger codes[NBOTTOM] = {HIT_SAVES, HIT_FILES, HIT_QUIT, HIT_PLAY}; [self press:codes[f - b0]]; } return;
    case NAV_LEFT: case NAV_RIGHT: {
        NSInteger d = n == NAV_LEFT ? -1 : 1;
        if (row == 0) { DSRow *r = self.top.firstObject; NSInteger c = (NSInteger)r.choices.count; [self chooseCard:(r.index + d + c) % c]; return; }
        NSInteger lo = row == 1 ? t0 : b0, hi = row == 1 ? b0 : end;
        self.focus = lo + (f - lo + d + (hi - lo)) % (hi - lo); return; }
    case NAV_UP: case NAV_DOWN: {
        int to = row + (n == NAV_DOWN ? 1 : -1); if (to < 0 || to > 2) return;
        NSInteger lo = to == 0 ? 0 : to == 1 ? t0 : b0, hi = to == 0 ? t0 : to == 1 ? b0 : end, best = lo; CGFloat x = NSMidX([self placeRect:f]), bd = 1e9;
        for (NSInteger i = lo; i < hi; i++) { CGFloat dd = fabs(NSMidX([self placeRect:i]) - x); if (dd < bd) { bd = dd; best = i; } }
        self.focus = best; return; }
    }
}
- (void)keyDown:(NSEvent *)e
{
    switch (e.keyCode) {
    case 0x24: case 0x4c: case 0x31: [self nav:NAV_OK]; return;       /* Return, Enter, Space */
    case 0x35: [self nav:NAV_BACK]; return;                            /* Escape */
    case 0x7e: [self nav:NAV_UP]; return;
    case 0x7d: [self nav:NAV_DOWN]; return;
    case 0x7b: [self nav:NAV_LEFT]; return;
    case 0x7c: [self nav:NAV_RIGHT]; return;
    case 0x23: [self nav:NAV_PLAY]; return;                            /* P */
    }
    [super keyDown:e];
}
static void draw_text(NSString *s, NSFont *f, NSColor *c, NSRect r, NSTextAlignment al, NSShadow *sh)
{
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = al; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary *a = [@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps} mutableCopy];
    if (sh) a[NSShadowAttributeName] = sh;
    [s drawInRect:r withAttributes:a];
}
static CGFloat ktext(NSString *s, NSFont *f, NSColor *c, CGFloat kern, NSPoint at, NSTextAlignment al)   /* kerned, one line; its width */
{
    NSAttributedString *a = [[NSAttributedString alloc] initWithString:s attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSKernAttributeName: @(kern)}];
    CGFloat w = a.size.width - kern;
    [a drawAtPoint:NSMakePoint(al == NSTextAlignmentCenter ? at.x - w / 2 : al == NSTextAlignmentRight ? at.x - w : at.x, at.y)];
    return w;
}
static NSShadow *drop(CGFloat blur, CGFloat a) { NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:a]; sh.shadowOffset = NSMakeSize(0, -1.5); sh.shadowBlurRadius = blur; return sh; }
- (void)drawTitle:(NSRect)r
{
    /* "DUNGEON SIEGE" in the logo's manner: brushed silver letters, a copper rim, a dark drop shadow */
    NSString *t = @"DUNGEON SIEGE II"; NSFont *f = cp(42, YES);
    NSDictionary *at = @{NSFontAttributeName: f, NSKernAttributeName: @3};
    NSSize sz = [t sizeWithAttributes:at]; NSPoint o = NSMakePoint(NSMidX(r) - sz.width / 2, NSMidY(r) - sz.height / 2 - 2);
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.85]; sh.shadowOffset = NSMakeSize(0, -3); sh.shadowBlurRadius = 5;
    NSMutableDictionary *rim = [at mutableCopy]; rim[NSStrokeColorAttributeName] = rgb(0.62, 0.33, 0.16, 1); rim[NSStrokeWidthAttributeName] = @(9); rim[NSShadowAttributeName] = sh;
    rim[NSForegroundColorAttributeName] = rgb(0.62, 0.33, 0.16, 1);
    [t drawAtPoint:o withAttributes:rim];
    /* silver fill: the glyphs as a clip, a vertical gradient through it */
    NSImage *mask = [NSImage imageWithSize:sz flipped:NO drawingHandler:^BOOL(NSRect dst) {
        NSMutableDictionary *m = [at mutableCopy]; m[NSForegroundColorAttributeName] = NSColor.whiteColor; [t drawAtPoint:NSZeroPoint withAttributes:m];
        NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:[NSColor colorWithWhite:0.98 alpha:1], 0.0, [NSColor colorWithWhite:0.72 alpha:1], 0.45,
                         [NSColor colorWithWhite:0.42 alpha:1], 0.5, [NSColor colorWithWhite:0.86 alpha:1], 0.8, [NSColor colorWithWhite:0.6 alpha:1], 1.0, nil];
        [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationSourceIn];
        [g drawInRect:dst angle:90];
        return YES;
    }];
    [mask drawInRect:NSMakeRect(o.x, o.y, sz.width, sz.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}
/* the main menu's wooden bar as a button (its pressed and lit states); without the game's art, a plain one */
- (void)drawButton:(NSRect)r title:(NSString *)title code:(NSInteger)code primary:(BOOL)primary
{
    BOOL foc = self.keyed && self.open < 0 && [self placeRect:self.focus].origin.x == r.origin.x && [self placeRect:self.focus].origin.y == r.origin.y;
    NSImage *img = self.pressed == code ? (self.woodDown ?: self.wood) : self.hover == code || foc ? (self.woodHover ?: self.wood) : self.wood;
    if (img) [img drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    else { [rgb(0.36, 0.22, 0.12, 1) setFill]; [[NSBezierPath bezierPathWithRoundedRect:r xRadius:6 yRadius:6] fill]; }
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; sh.shadowOffset = NSMakeSize(0, -1.5); sh.shadowBlurRadius = 2;
    NSColor *c = self.hover == code || foc ? rgb(1, 0.93, 0.72, 1) : primary ? gold() : parchment();
    /* the capitals centred on the button (the line's own box sits them high: it leaves room below for descenders) */
    NSFont *f = cp(primary ? 25 : 20, YES); NSDictionary *at = @{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSShadowAttributeName: sh, NSKernAttributeName: @(primary ? 3 : 2)};
    NSSize sz = [title sizeWithAttributes:at];
    [title drawAtPoint:NSMakePoint(NSMidX(r) - sz.width / 2, round(NSMidY(r) + f.capHeight / 2 - f.ascender)) withAttributes:at];
}
- (void)drawArrow:(NSRect)r right:(BOOL)right lit:(BOOL)lit
{
    NSBezierPath *p = [NSBezierPath bezierPath]; CGFloat x0 = r.origin.x + 7, x1 = NSMaxX(r) - 7, y0 = r.origin.y + 6, y1 = NSMaxY(r) - 6, ym = NSMidY(r);
    if (right) { [p moveToPoint:NSMakePoint(x0, y0)]; [p lineToPoint:NSMakePoint(x1, ym)]; [p lineToPoint:NSMakePoint(x0, y1)]; }
    else { [p moveToPoint:NSMakePoint(x1, y0)]; [p lineToPoint:NSMakePoint(x0, ym)]; [p lineToPoint:NSMakePoint(x1, y1)]; }
    [p closePath];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:lit ? 1.0 : 0.88 alpha:1] endingColor:[NSColor colorWithWhite:lit ? 0.7 : 0.45 alpha:1]];
    [g drawInBezierPath:p angle:90];
    [rgb(0.55, 0.3, 0.14, 1) setStroke]; p.lineWidth = 1.5; [p stroke];
}
static void rivet(CGFloat x, CGFloat y, CGFloat s)
{
    NSRect d = NSMakeRect(x - s, y - s, 2 * s, 2 * s);
    NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:rgb(0.98, 0.86, 0.55, 1), 0.0, rgb(0.62, 0.42, 0.16, 1), 0.6, rgb(0.25, 0.15, 0.05, 1), 1.0, nil];
    [g drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:d] relativeCenterPosition:NSMakePoint(-0.35, 0.35)];
}
/* a riveted iron band around a plaque, like the frames of the game's menus */
- (void)drawIronFrame:(NSRect)r
{
    NSBezierPath *outer = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 3, 3)];
    outer.lineWidth = 7; [[NSColor colorWithWhite:0.08 alpha:1] setStroke]; [outer stroke];
    outer.lineWidth = 5; [rgb(0.45, 0.46, 0.47, 1) setStroke]; [outer stroke];
    NSBezierPath *hi = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 1.5, 1.5)]; hi.lineWidth = 1; [[NSColor colorWithWhite:0.78 alpha:0.8] setStroke]; [hi stroke];
    NSBezierPath *lo = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 6, 6)]; lo.lineWidth = 1.2; [[NSColor colorWithWhite:0.05 alpha:0.9] setStroke]; [lo stroke];
    for (CGFloat x = r.origin.x + 14; x <= NSMaxX(r) - 13; x += (r.size.width - 28) / 8) { rivet(x, r.origin.y + 3.5, 4); rivet(x, NSMaxY(r) - 3.5, 4); }
    for (CGFloat y = r.origin.y + 14 + (r.size.height - 28) / 6; y < NSMaxY(r) - 20; y += (r.size.height - 28) / 6) { rivet(r.origin.x + 3.5, y, 4); rivet(NSMaxX(r) - 3.5, y, 4); }
}
/* a gilded corner: an L of brass with a stud, as the game's inventory and dialogue frames have */
static void corner(NSPoint c, CGFloat sx, CGFloat sy, CGFloat len, NSColor *col)
{
    NSBezierPath *p = [NSBezierPath bezierPath]; p.lineWidth = 2; p.lineCapStyle = NSLineCapStyleSquare;
    [p moveToPoint:NSMakePoint(c.x, c.y + sy * len)]; [p lineToPoint:c]; [p lineToPoint:NSMakePoint(c.x + sx * len, c.y)];
    [col setStroke]; [p stroke];
    NSBezierPath *d = [NSBezierPath bezierPath]; CGFloat s = 3.6, x = c.x + sx * 6, y = c.y + sy * 6;
    [d moveToPoint:NSMakePoint(x, y - s)]; [d lineToPoint:NSMakePoint(x + s, y)]; [d lineToPoint:NSMakePoint(x, y + s)]; [d lineToPoint:NSMakePoint(x - s, y)]; [d closePath];
    [col setFill]; [d fill];
}
/* a panel of the main menu's dark red stone: translucent over the backdrop, a brass hairline, gilded corners */
- (void)plate:(NSRect)r lit:(CGFloat)lit edge:(NSColor *)edge
{
    NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:rgb(0.13, 0.05, 0.035, 0.82), 0.0, rgb(0.06, 0.025, 0.02, 0.88), 1.0, nil];
    [g drawInRect:r angle:-90];
    if (lit > 0) {
        NSGradient *w = [[NSGradient alloc] initWithColorsAndLocations:ember(0.30 * lit), 0.0, blood(0.08 * lit), 1.0, nil];
        [w drawInRect:r angle:-90];
    }
    [(edge ?: [gold() colorWithAlphaComponent:0.38]) setStroke];
    NSBezierPath *p = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)]; p.lineWidth = edge ? 1.5 : 1; [p stroke];
    [[gold() colorWithAlphaComponent:0.12] setStroke];
    NSBezierPath *q = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 4.5, 4.5)]; q.lineWidth = 1; [q stroke];
    NSColor *cc = edge ?: [gold() colorWithAlphaComponent:0.75];
    for (int k = 0; k < 4; k++) corner(NSMakePoint(k % 2 ? NSMaxX(r) - 2 : r.origin.x + 2, k / 2 ? NSMaxY(r) - 2 : r.origin.y + 2), k % 2 ? -1 : 1, k / 2 ? -1 : 1, 12, cc);
}
/* a thin brass rule with a diamond in the middle */
static void rule(CGFloat x0, CGFloat x1, CGFloat y, CGFloat alpha)
{
    CGFloat m = (x0 + x1) / 2;
    [[[NSGradient alloc] initWithColors:@[rgb(0.86, 0.77, 0.55, 0), rgb(0.86, 0.77, 0.55, alpha)]] drawInRect:NSMakeRect(x0, y - 0.5, m - 9 - x0, 1) angle:0];
    [[[NSGradient alloc] initWithColors:@[rgb(0.86, 0.77, 0.55, alpha), rgb(0.86, 0.77, 0.55, 0)]] drawInRect:NSMakeRect(m + 9, y - 0.5, x1 - m - 9, 1) angle:0];
    NSBezierPath *d = [NSBezierPath bezierPath];
    [d moveToPoint:NSMakePoint(m, y - 4.5)]; [d lineToPoint:NSMakePoint(m + 4.5, y)]; [d lineToPoint:NSMakePoint(m, y + 4.5)]; [d lineToPoint:NSMakePoint(m - 4.5, y)]; [d closePath];
    [rgb(0.86, 0.77, 0.55, alpha) setFill]; [d fill];
}
/* ---- the moving part ---- */
/* the backdrop: the slides, each drifting from when it starts fading in until it has faded out (no jump at a handover);
 * a wide one (the key art) pans across */
- (void)backdrop
{
    NSArray<NSImage *> *sc = self.scenes; NSUInteger n = sc.count; NSRect b = self.bounds; double tt = MAX(0.0, self.t);
    if (!n) return;
    double per = 8.5, fadeT = 1.8;
    void (^slide)(NSUInteger, double, CGFloat) = ^(NSUInteger j, double local, CGFloat a) {
        NSImage *im = sc[j % n]; double p = local / (per + fadeT), aspect = im.size.width / MAX(1.0, im.size.height);
        CGFloat dir = (j % 2) ? 1 : -1, amp = aspect > 2.2 ? 0.40 : 0.10;
        draw_fill_z(im, b, a, (CGFloat)(1.04 + 0.07 * p), (CGFloat)(0.5 + dir * amp * (p - 0.5)), (CGFloat)(0.45 + 0.05 * (p - 0.5)));
    };
    if (n == 1) { draw_fill_z(sc[0], b, 1, (CGFloat)(1.08 + 0.035 * sin(tt * 0.11)), (CGFloat)(0.5 + 0.06 * sin(tt * 0.07)), 0.45); return; }
    NSUInteger k = (NSUInteger)(tt / per); double local = tt - (double)k * per;
    if (local < fadeT && k > 0) { slide(k - 1, local + per, 1); slide(k, local, (CGFloat)(local / fadeT)); }
    else slide(k, local, 1);
}
/* a soft round glow (mist, the fire, a spark's halo), drawn once small: it is drawn scaled up, and blurry is right */
- (NSImage *)sprite:(NSString *)key colors:(NSArray<NSColor *> *)cols
{
    NSImage *c = self.cache[key]; if (c) return c;
    c = offscreen(NSMakeSize(128, 128), 1, ^{
        [[[NSGradient alloc] initWithColors:cols] drawFromCenter:NSMakePoint(64, 64) radius:0 toCenter:NSMakePoint(64, 64) radius:64 options:0]; });
    self.cache[key] = c; return c;
}
static void draw_sprite(NSImage *img, NSPoint c, CGFloat rx, CGFloat ry, CGFloat alpha)
{
    if (alpha <= 0.002) return;
    [img drawInRect:NSMakeRect(c.x - rx, c.y - ry, 2 * rx, 2 * ry) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:MIN(1, alpha) respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationLow)}];
}
/* the window's grade, drawn once: a red wash, dark on the left for the title, dark under the tiles, round the edges */
- (NSImage *)grade
{
    NSImage *c = self.cache[@"grade"]; if (c) return c;
    NSRect b = self.bounds;
    c = offscreen(b.size, 1, ^{
        [blood(0.10) setFill]; NSRectFillUsingOperation(b, NSCompositingOperationSourceOver);
        NSGradient *side = [[NSGradient alloc] initWithColorsAndLocations:rgb(0.03, 0.01, 0.01, 0.74), 0.0, rgb(0.03, 0.01, 0.01, 0.40), 0.45, rgb(0.03, 0.01, 0.01, 0.06), 0.78, rgb(0.03, 0.01, 0.01, 0.02), 1.0, nil];
        [side drawInRect:b angle:0];
        NSGradient *low = [[NSGradient alloc] initWithColorsAndLocations:rgb(0, 0, 0, 0.18), 0.0, rgb(0, 0, 0, 0.0), 0.36, rgb(0.04, 0.01, 0.01, 0.42), 0.64, rgb(0.04, 0.01, 0.01, 0.90), 0.84, rgb(0.03, 0.01, 0.01, 0.96), 1.0, nil];
        [low drawInRect:b angle:-90];
        NSGradient *vig = [[NSGradient alloc] initWithStartingColor:rgb(0, 0, 0, 0) endingColor:rgb(0, 0, 0, 0.5)];
        [vig drawInRect:b relativeCenterPosition:NSMakePoint(0.15, 0.1)];
    });
    self.cache[@"grade"] = c; return c;
}
/* the title, its fire behind it, drawn once: the game's own logo, else its name in silver and copper */
- (NSImage *)title
{
    NSImage *c = self.cache[@"title"]; if (c) return c;
    NSRect box = self.titleBox, out = NSInsetRect(box, -40, -40);
    c = offscreen(out.size, self.scale, ^{
        NSRect bx = NSOffsetRect(box, -out.origin.x, -out.origin.y);
        if (self.logo) {
            NSSize s = self.logo.size; CGFloat w = bx.size.width, h = w * s.height / s.width; if (h > bx.size.height) { h = bx.size.height; w = h * s.width / s.height; }
            NSShadow *sh = [NSShadow new]; sh.shadowColor = rgb(0, 0, 0, 0.9); sh.shadowBlurRadius = 8; sh.shadowOffset = NSMakeSize(0, -3); [sh set];
            [self.logo drawInRect:NSMakeRect(NSMidX(bx) - w / 2, NSMidY(bx) - h / 2, w, h) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        } else [self drawTitle:bx];
    });
    self.cache[@"title"] = c; return c;
}
/* the portrait in its frame (the frame drawn once, in the still part) */
- (void)drawPortrait:(NSRect)in
{
    [NSGraphicsContext saveGraphicsState]; NSRectClip(in);
    [rgb(0.03, 0.01, 0.01, 1) setFill]; NSRectFill(in);
    if (self.portrait) draw_fill_z(self.portrait, in, 1, (CGFloat)(self.portraitZ + 0.02 * sin(self.t * 0.21)), (CGFloat)(self.portraitFx + 0.01 * sin(self.t * 0.13)), self.portraitFy);
    else if (self.logo) {                                              /* no picture: the logo, in the fire */
        draw_sprite([self sprite:@"fire" colors:@[ember(1), blood(0.5), rgb(0, 0, 0, 0)]], NSMakePoint(NSMidX(in), NSMidY(in)), 200, 200, 0.5);
        NSSize s = self.logo.size; CGFloat w = in.size.width - 30, h = w * s.height / s.width;
        [self.logo drawInRect:NSMakeRect(NSMidX(in) - w / 2, NSMidY(in) - h / 2 - 20, w, h) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    NSGradient *foot = [[NSGradient alloc] initWithColorsAndLocations:rgb(0, 0, 0, 0), 0.62, rgb(0.05, 0.01, 0.01, 0.94), 1.0, nil];
    [foot drawInRect:in angle:90];
    [NSGraphicsContext restoreGraphicsState];
}
- (void)setNeedsArt { [self.cache removeAllObjects]; self.artGen++; self.needsDisplay = YES; }
/* what the still part of the window depends on: when it changes, the still part is drawn again */
- (NSString *)signature
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"%ld|%ld|%ld|%ld|%d|%@|%ld|%.0f", (long)self.open, (long)self.focus, (long)self.hover, (long)self.pressed,
                          self.keyed, self.note ?: @"", (long)self.artGen, self.scale];
    for (DSRow *r in self.top) [s appendFormat:@"|%ld", (long)r.index];
    for (DSSection *sec in self.sections) { [s appendFormat:@"|%@", sec.summary ? sec.summary() : @""]; for (DSRow *r in sec.rows) [s appendFormat:@",%ld%@", (long)r.index, r.choices[r.index][@"label"]]; }
    return s;
}
static int frames_drawn;   /* (DS_LAUNCHER_TIMING: frames a second, in the window) */
- (void)drawRect:(NSRect)dirty
{
    NSRect b = self.bounds; CGFloat W = b.size.width, H = b.size.height; double T = self.t; frames_drawn++;
    if (!self.cache) self.cache = [NSMutableDictionary dictionary];
    if (![self.cache[@"scale"] isEqual:@(self.scale)]) { [self.cache removeAllObjects]; self.cache[@"scale"] = @(self.scale); }   /* (another display) */
    [rgb(0.07, 0.015, 0.01, 1) setFill]; NSRectFill(b);
    /* the backdrop under the grade */
    fill_interp = NSImageInterpolationMedium; [self backdrop]; fill_interp = NSImageInterpolationHigh;
    [self.grade drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationLow)}];
    /* mist rolling across, low and slow; the fire glowing behind the portrait and the title */
    NSImage *mist = [self sprite:@"mist" colors:@[rgb(0.30, 0.10, 0.07, 1), rgb(0.24, 0.07, 0.05, 0.45), rgb(0.2, 0.05, 0.04, 0)]];
    for (int i = 0; i < 7; i++) {
        double sp = 0.5 + hash01(i * 3.1), y = H * (0.35 + 0.55 * hash01(i * 7.7)), r = 150 + 170 * hash01(i * 1.3);
        double x = fmod(hash01(i * 5.9) * (W + 2 * r) + T * 8 * sp, W + 2 * r) - r;
        draw_sprite(mist, NSMakePoint(x, y + 12 * sin(T * 0.2 + i)), r, r * 0.6, 0.13 + 0.05 * sin(T * 0.3 + i));
    }
    NSImage *fire = [self sprite:@"fire" colors:@[ember(1), blood(0.5), rgb(0, 0, 0, 0)]];
    NSRect pr = self.portraitRect; double flick = 0.5 + 0.3 * sin(T * 2.1) + 0.2 * sin(T * 5.3 + 1.3);
    draw_sprite(fire, NSMakePoint(NSMidX(pr), NSMaxY(pr) - 20), 380, 380, 0.22 + 0.10 * flick);
    draw_sprite(fire, NSMakePoint(NSMidX(self.titleBox), NSMidY(self.titleBox) + 6), 330, 110, 0.20 + 0.08 * sin(T * 1.3));
    /* embers rising from the fires, and motes of magic drifting up and twinkling, a halo on each */
    NSImage *halo = [self sprite:@"halo" colors:@[rgb(1.0, 0.55, 0.18, 1), rgb(1.0, 0.35, 0.08, 0.3), rgb(0, 0, 0, 0)]];
    NSImage *glint = [self sprite:@"glint" colors:@[rgb(1.0, 0.92, 0.65, 1), rgb(0.95, 0.75, 0.35, 0.28), rgb(0, 0, 0, 0)]];
    for (int i = 0; i < 70; i++) {
        double sx = hash01(i * 3.33 + 1), sy = hash01(i * 4.21 + 9), sp = 0.4 + hash01(i * 0.91 + 5);
        double y = H + 10 - fmod(sy * (H + 40) + T * 30 * sp, H + 40), life = 1 - MAX(0.0, (H - y) / H);
        double x = sx * W + 20 * sin(T * 0.9 * sp + i) + (H - y) * 0.12 * (hash01(i) - 0.5);
        double a = life * (0.45 + 0.55 * fabs(sin(T * (2.0 + 2.0 * sp) + i))); CGFloat r = (CGFloat)(0.7 + 1.1 * sp);
        draw_sprite(halo, NSMakePoint(x, y), r * 4, r * 4, a * 0.5);
        [rgb(1.0, 0.78, 0.42, MIN(1.0, a * 1.2)) setFill]; NSRectFillUsingOperation(NSMakeRect(x - r / 2, y - r / 2, r, r), NSCompositingOperationSourceOver);
    }
    for (int i = 0; i < 46; i++) {
        double sx = hash01(i * 1.618 + 2), sy = hash01(i * 2.414 + 7), sp = 0.3 + hash01(i * 0.577 + 3);
        double y = fmod(sy * (H + 40) - T * 9 * sp, H + 40); if (y < 0) y += H + 40; y -= 20;
        double x = fmod(sx * (W + 40) + 14 * sin(T * 0.5 * sp + i * 1.7), W + 40) - 20;
        double tw = pow(fabs(sin(T * (0.8 + sp) + i * 2.3)), 6), a = 0.15 + 0.85 * tw;
        draw_sprite(glint, NSMakePoint(x, y), 5 + 5 * tw, 5 + 5 * tw, a * 0.7);
    }
    /* the portrait (its frame is in the still part); the title, its glow breathing */
    [self drawPortrait:NSInsetRect(pr, 13, 13)];
    NSRect tout = NSInsetRect(self.titleBox, -40, -40);
    [self.title drawInRect:tout fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    /* the still part: plates, cards, tiles, buttons, words, an open group's panel (drawn again only when what it shows changes) */
    NSString *sig = self.signature;
    if (!self.cache[@"ui"] || ![self.cache[@"uiSig"] isEqual:sig]) { self.cache[@"ui"] = offscreen(b.size, self.scale, ^{ [self drawStill]; }); self.cache[@"uiSig"] = sig; }
    [(NSImage *)self.cache[@"ui"] drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    /* Play: its fire breathing behind the wooden bar */
    {
        NSRect p = self.playRect; BOOL lit = self.hover == HIT_PLAY || (self.keyed && self.open < 0 && self.focus == self.firstBottom + 3);
        draw_sprite(fire, NSMakePoint(NSMidX(p), NSMidY(p)), p.size.width * 0.75, p.size.height * 1.1, lit ? 0.55 : 0.28 + 0.10 * sin(T * 2.0));
        [self drawButton:p title:@"PLAY" code:HIT_PLAY primary:YES];
    }
}
/* the still part of the window (into a picture: see drawRect) */
- (void)drawStill
{
    NSRect b = self.bounds; CGFloat W = b.size.width, H = b.size.height;
    NSShadow *sh = drop(2, 0.9);
    BOOL top = self.open < 0; NSInteger foc = self.keyed && top ? self.focus : HIT_NONE, hov = top ? self.hover : HIT_NONE;
    /* the portrait's frame: iron, riveted, a brass rule and the place on a plaque at its foot; its window left clear */
    {
        NSRect pr = self.portraitRect, in = NSInsetRect(pr, 13, 13);
        [NSGraphicsContext saveGraphicsState];
        NSShadow *s2 = [NSShadow new]; s2.shadowColor = rgb(0, 0, 0, 0.85); s2.shadowBlurRadius = 18; s2.shadowOffset = NSMakeSize(0, -6); [s2 set];
        [rgb(0.07, 0.04, 0.03, 1) setFill]; NSRectFill(pr);
        [NSGraphicsContext restoreGraphicsState];
        NSGradient *bez = [[NSGradient alloc] initWithColorsAndLocations:rgb(0.30, 0.22, 0.17, 1), 0.0, rgb(0.17, 0.11, 0.08, 1), 0.5, rgb(0.10, 0.06, 0.05, 1), 1.0, nil];
        [bez drawInRect:pr angle:-70];
        [self drawIronFrame:pr];
        NSRectFillUsingOperation(in, NSCompositingOperationClear);
        [rgb(0, 0, 0, 0.9) setStroke]; NSBezierPath *f1 = [NSBezierPath bezierPathWithRect:NSInsetRect(in, -1, -1)]; f1.lineWidth = 2; [f1 stroke];
        [[gold() colorWithAlphaComponent:0.85] setStroke];
        for (int k = 0; k < 4; k++) corner(NSMakePoint(k % 2 ? NSMaxX(in) - 6 : in.origin.x + 6, k / 2 ? NSMaxY(in) - 6 : in.origin.y + 6), k % 2 ? -1 : 1, k / 2 ? -1 : 1, 22, [gold() colorWithAlphaComponent:0.9]);
        rule(in.origin.x + 24, NSMaxX(in) - 24, NSMaxY(in) - 42, 0.85);
        ktext(@"THE WORLD OF ARANNA", cp(14, YES), parchment(), 3, NSMakePoint(NSMidX(in), NSMaxY(in) - 34), NSTextAlignmentCenter);
    }
    /* under the title: the makers, the year, the tale */
    rule(60, 540, 190, 0.75);
    [NSGraphicsContext saveGraphicsState]; [sh set];
    ktext(@"GAS POWERED GAMES  ·  2005", cp(13, YES), gold(), 3, NSMakePoint(300, 200), NSTextAlignmentCenter);
    { NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter; ps.lineSpacing = 3;
      [@"A mercenary of Valdis's army, left for dead, turns against him: to stop the Sword of Zaramoth before its darkness swallows Aranna."
          drawWithRect:NSMakeRect(66, 224, 468, 48) options:NSStringDrawingUsesLineFragmentOrigin
          attributes:@{NSFontAttributeName: book(15.5, YES), NSForegroundColorAttributeName: rgb(0.90, 0.85, 0.77, 0.96), NSParagraphStyleAttributeName: ps}]; }
    [NSGraphicsContext restoreGraphicsState];
    /* the Game row: a card per choice (the game, the Test Lab) */
    DSRow *mode = self.top.firstObject;
    ktext(mode.title.uppercaseString, cp(12, YES), [gold() colorWithAlphaComponent:0.85], 4, NSMakePoint(48, 280), NSTextAlignmentLeft);
    for (NSInteger k = 0; k < (NSInteger)mode.choices.count; k++) {
        NSRect r = [self cardRect:k]; BOOL sel = k == mode.index, hv = hov == HIT_CARD + k, fc = foc == 0 && sel; NSDictionary *ch = mode.choices[k];
        if (sel) {
            [NSGraphicsContext saveGraphicsState]; NSShadow *gl = [NSShadow new]; gl.shadowColor = ember(0.6); gl.shadowBlurRadius = 16; [gl set];
            [rgb(0.06, 0.02, 0.02, 1) setFill]; NSRectFill(r); [NSGraphicsContext restoreGraphicsState];
        }
        [self plate:r lit:sel ? 0.5 : hv ? 0.4 : 0 edge:fc ? parchment() : sel ? gold() : hv ? [gold() colorWithAlphaComponent:0.75] : nil];
        NSRect ir = NSMakeRect(r.origin.x + 7, r.origin.y + 7, r.size.width - 14, 70);
        [NSGraphicsContext saveGraphicsState]; NSRectClip(ir);
        [rgb(0.02, 0.01, 0.01, 1) setFill]; NSRectFill(ir);
        NSImage *art = k < (NSInteger)self.cards.count ? self.cards[k] : nil;
        if ([art isKindOfClass:NSImage.class]) draw_fill_z(art, ir, 1, 1.0, 0.5, 0.45);
        [[[NSGradient alloc] initWithColors:@[rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.45)]] drawInRect:ir angle:90];
        if (!sel) { [rgb(0, 0, 0, hv ? 0.18 : 0.40) setFill]; NSRectFillUsingOperation(ir, NSCompositingOperationSourceOver); }
        [NSGraphicsContext restoreGraphicsState];
        [[gold() colorWithAlphaComponent:sel ? 0.7 : 0.3] setStroke]; NSBezierPath *fr = [NSBezierPath bezierPathWithRect:NSInsetRect(ir, -0.5, -0.5)]; fr.lineWidth = 1; [fr stroke];
        draw_text([ch[@"label"] uppercaseString], cp(14, YES), sel ? parchment() : rgb(0.82, 0.76, 0.66, 1), NSMakeRect(r.origin.x + 6, r.origin.y + 82, r.size.width - 12, 18), NSTextAlignmentCenter, sh);
        draw_text(ch[@"note"] ?: @"", book(10.5, YES), sel ? rgb(0.86, 0.80, 0.70, 1) : dim(), NSMakeRect(r.origin.x + 14, r.origin.y + 101, r.size.width - 28, 16), NSTextAlignmentCenter, nil);
    }
    /* the settings: a tile per group, its first choice large, the rest under it */
    ktext(@"SETTINGS", cp(12, YES), [gold() colorWithAlphaComponent:0.85], 4, NSMakePoint(48, 442), NSTextAlignmentLeft);
    for (NSInteger i = 0; i < (NSInteger)self.sections.count; i++) {
        DSSection *s = self.sections[i]; NSRect r = [self sectionRect:i]; BOOL hv = hov == HIT_SECTION + i, fc = foc == self.firstTile + i;
        NSString *big, *small;
        if (s.summary) { NSString *sum = s.summary(); NSRange d = [sum rangeOfString:@" · "];
                         big = d.location == NSNotFound ? sum : [sum substringToIndex:d.location]; small = d.location == NSNotFound ? @"" : [sum substringFromIndex:NSMaxRange(d)]; }
        else { NSMutableArray *l = [NSMutableArray array]; for (DSRow *row in s.rows) [l addObject:row.choices[row.index][@"label"]];
               big = l.firstObject ?: @""; small = l.count > 1 ? [[l subarrayWithRange:NSMakeRange(1, l.count - 1)] componentsJoinedByString:@" · "] : (s.rows.firstObject.choices[s.rows.firstObject.index][@"note"] ?: @""); }
        [self plate:r lit:hv || fc ? 1 : 0 edge:fc ? parchment() : hv ? gold() : nil];
        ktext(s.title.uppercaseString, cp(12, YES), gold(), 2.5, NSMakePoint(r.origin.x + 15, r.origin.y + 12), NSTextAlignmentLeft);
        draw_text(big, cp(17, YES), parchment(), NSMakeRect(r.origin.x + 15, r.origin.y + 31, r.size.width - 26, 22), NSTextAlignmentLeft, sh);
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
        [small drawWithRect:NSMakeRect(r.origin.x + 15, r.origin.y + 55, r.size.width - 24, 26) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                 attributes:@{NSFontAttributeName: book(10.5, NO), NSForegroundColorAttributeName: dim(), NSParagraphStyleAttributeName: ps}];
    }
    /* Saves and Game Files; Quit (Play is drawn live) */
    rule(48, W - 48, 558, 0.35);
    NSArray *small = @[@"SAVES", @"GAME FILES"]; NSArray *codes = @[@(HIT_SAVES), @(HIT_FILES)];
    for (NSInteger k = 0; k < 2; k++) {
        NSRect r = k ? self.filesRect : self.savesRect; NSInteger code = [codes[k] integerValue]; BOOL hv = hov == code, fc = foc == self.firstBottom + k;
        [self plate:r lit:hv || fc ? 0.6 : 0 edge:fc ? parchment() : hv ? gold() : nil];
        ktext(small[k], cp(13, YES), hv || fc ? parchment() : rgb(0.84, 0.78, 0.66, 1), 2, NSMakePoint(NSMidX(r), r.origin.y + 12), NSTextAlignmentCenter);
    }
    /* an open group: a panel over the window, framed in iron */
    if (!top) {
        [rgb(0.02, 0.0, 0.0, 0.62) setFill]; NSRectFillUsingOperation(NSMakeRect(0, 0, W, 556), NSCompositingOperationSourceOver);
        NSRect f = self.flyRect;
        [NSGraphicsContext saveGraphicsState]; NSShadow *s2 = [NSShadow new]; s2.shadowColor = rgb(0, 0, 0, 0.9); s2.shadowBlurRadius = 24; [s2 set];
        [rgb(0.10, 0.025, 0.015, 0.97) setFill]; NSRectFill(NSInsetRect(f, 6, 6)); [NSGraphicsContext restoreGraphicsState];
        if (self.stone) { [NSGraphicsContext saveGraphicsState]; NSRectClip(NSInsetRect(f, 6, 6)); draw_fill_z(self.stone, NSInsetRect(f, 6, 6), 0.35, 1, 0.5, 0.5); [NSGraphicsContext restoreGraphicsState]; }
        [[NSColor colorWithWhite:0 alpha:0.35] setFill]; NSRectFillUsingOperation(NSInsetRect(f, 6, 6), NSCompositingOperationSourceOver);
        [self drawIronFrame:f];
        for (int k = 0; k < 4; k++) corner(NSMakePoint(k % 2 ? NSMaxX(f) - 14 : f.origin.x + 14, k / 2 ? NSMaxY(f) - 14 : f.origin.y + 14), k % 2 ? -1 : 1, k / 2 ? -1 : 1, 26, [gold() colorWithAlphaComponent:0.85]);
        ktext(self.sections[self.open].title.uppercaseString, cp(26, YES), gold(), 5, NSMakePoint(NSMidX(f), f.origin.y + 26), NSTextAlignmentCenter);
        rule(f.origin.x + 60, NSMaxX(f) - 60, f.origin.y + 66, 0.7);
        for (NSInteger k = 0; k < (NSInteger)self.rows.count; k++) {
            DSRow *row = self.rows[k]; NSRect r = [self rowRect:k]; NSDictionary *ch = row.choices[row.index];
            if (k == self.focus) { [ember(0.14) setFill]; NSRectFillUsingOperation(NSInsetRect(r, -12, -3), NSCompositingOperationSourceOver);
                                   [[gold() colorWithAlphaComponent:self.keyed ? 0.7 : 0.25] setStroke]; NSBezierPath *fb = [NSBezierPath bezierPathWithRect:NSInsetRect(r, -11.5, -2.5)]; fb.lineWidth = 1; [fb stroke]; }
            draw_text(row.title.uppercaseString, cp(18, YES), gold(), NSMakeRect(r.origin.x, r.origin.y + 8, 300, 26), NSTextAlignmentLeft, sh);
            [self drawArrow:[self arrow:k right:NO] right:NO lit:self.hover == 10 * k];
            [self drawArrow:[self arrow:k right:YES] right:YES lit:self.hover == 10 * k + 2];
            draw_text(ch[@"label"], cp(18, NO), self.hover == 10 * k + 1 ? NSColor.whiteColor : parchment(), [self valueRect:k], NSTextAlignmentCenter, sh);
            draw_text(ch[@"note"] ?: @"", book(12, YES), dim(), NSMakeRect(NSMaxX(r) - 360, r.origin.y + 38, 360, 18), NSTextAlignmentCenter, nil);
            if (k + 1 < (NSInteger)self.rows.count) { [rgb(0.55, 0.38, 0.2, 0.35) setFill]; NSRectFillUsingOperation(NSMakeRect(r.origin.x, NSMaxY(r) + 3, r.size.width, 1), NSCompositingOperationSourceOver); }
        }
    }
    [self drawButton:self.quitRect title:top ? @"QUIT" : @"BACK" code:top ? HIT_QUIT : HIT_BACK primary:NO];
    NSString *hint = self.note.length ? self.note : !top ? @"Left and right change a row  ·  up and down move  ·  Esc goes back"
                   : @"Click a card or a tile  ·  arrows move  ·  Return chooses  ·  P plays  ·  Esc quits";
    draw_text(hint, book(12.5, NO), dim(), NSMakeRect(48, H - 30, W - 96 - 250, 18), NSTextAlignmentLeft, nil);
    ktext(@"NATIVE FOR APPLE SILICON  ·  METAL", cp(10, NO), [dim() colorWithAlphaComponent:0.85], 3, NSMakePoint(W - 48, H - 27), NSTextAlignmentRight);
}
@end
// ---------------------------------------------------------------- choices, settings file, the window
/* A display with a notch: the game in macOS full screen (with Game Mode either way) below it, with a black band beside
 * the camera, or over the whole display around it, the notch covering a little of the picture's top centre (DS_NOTCH) */
static int notch_height(void) { if (@available(macOS 12.0, *)) return (int)NSScreen.mainScreen.safeAreaInsets.top; return 0; }
static NSArray<NSDictionary *> *notch_choices(void)
{
    return @[@{@"value": @"hide", @"label": @"Hide the Notch", @"note": @"The picture below the camera, a black band beside it"},
             @{@"value": @"around", @"label": @"Around the Notch", @"note": @"The picture on the whole display, the notch over its top"}];
}
static void apply_notch(NSString *v) { setenv("DS_NOTCH", v.UTF8String, 1); }
/* Interface Size: the game runs at the chosen resolution divided by this, so its interface is laid out that much
 * larger, and the renderer draws the screen at the chosen resolution itself (DSR_RENDER_SCALE), so the world stays sharp.
 * Only sizes that leave the game at least 800x600 (what its interface is laid out for) are offered. */
static NSArray<NSDictionary *> *ui_choices(NSString *res)
{
    int W = 0, H = 0; sscanf(res.UTF8String, "%dx%d", &W, &H);
    NSMutableArray *a = [NSMutableArray array];
    static const int sizes[] = {100, 125, 150, 175, 200, 250, 300};
    for (size_t k = 0; k < sizeof sizes / sizeof *sizes; k++) { int pc = sizes[k];
        if (pc > 100 && (W * 100 / pc < 800 || H * 100 / pc < 600)) continue;
        [a addObject:@{@"value": [NSString stringWithFormat:@"%d", pc], @"label": [NSString stringWithFormat:@"%d%%", pc],
                       @"note": pc == 100 ? @"As the game draws it" : [NSString stringWithFormat:@"The game at %d x %d, drawn at %d x %d", (int)lround(W * 100.0 / pc), (int)lround(H * 100.0 / pc), W, H]}];
    }
    return a;
}
static void apply_ui(NSString *res, NSString *size)
{
    int W = 0, H = 0, pc = size.intValue; sscanf(res.UTF8String, "%dx%d", &W, &H);
    if (pc <= 100 || !W || !H) { unsetenv("DSR_RENDER_SCALE"); return; }
    setenv("DS_RESOLUTION", [NSString stringWithFormat:@"%dx%d", (int)lround(W * 100.0 / pc), (int)lround(H * 100.0 / pc)].UTF8String, 1);
    setenv("DSR_RENDER_SCALE", [NSString stringWithFormat:@"%g", pc / 100.0].UTF8String, 1);
}
static NSArray<NSDictionary *> *resolution_choices(BOOL below_notch)
{
    NSScreen *s = NSScreen.mainScreen; int W = (int)s.frame.size.width, H = (int)s.frame.size.height; double sc = s.backingScaleFactor;
    if (below_notch) H -= notch_height();
    NSMutableArray *a = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    void (^add)(int, int, NSString *) = ^(int w, int h, NSString *note) {
        NSString *v = [NSString stringWithFormat:@"%dx%d", w, h]; if ([seen containsObject:v]) return; [seen addObject:v];
        [a addObject:@{@"value": v, @"label": [NSString stringWithFormat:@"%d × %d", w, h], @"note": note}];
    };
    add(W, H, @"This display (recommended)");
    if (sc > 1.01) add((int)(W * sc + 0.5), (int)(H * sc + 0.5), @"Full Retina detail; the interface is drawn very small");
    static const int std[][2] = {{2560,1600},{2560,1440},{1920,1200},{1920,1080},{1680,1050},{1600,900},{1440,900},{1366,768},{1280,800},{1280,720},{1024,768},{800,600}};
    for (size_t k = 0; k < sizeof std / sizeof *std; k++) if (std[k][0] <= W && std[k][1] <= H) add(std[k][0], std[k][1], @"Scaled to fill the screen");
    return a;
}
static NSArray<NSDictionary *> *distance_choices(void)
{
    return @[@{@"value": @"100", @"label": @"Original", @"note": @"As the game shipped"},
             @{@"value": @"125", @"label": @"Far", @"note": @"125% of the original"},
             @{@"value": @"150", @"label": @"Farther", @"note": @"150%, like the SeeFar mods"},
             @{@"value": @"200", @"label": @"Very Far", @"note": @"200% of the original"},
             @{@"value": @"250", @"label": @"Horizon", @"note": @"250%; heavier in large outdoor areas"},
             @{@"value": @"300", @"label": @"Maximum", @"note": @"300%; may slow down in the biggest vistas"}];
}
/* ---- the game's own graphics options (its Options > Video page), kept in the game's Save/prefs.gas: read when the window
 * opens and written when Play is pressed, so they're set here and the in-game page needn't be used ---- */
static NSString *prefs_path(NSString *data)
{
    return [data stringByAppendingPathComponent:@"drive_c/Users/player/Documents/My Games/Dungeon Siege 2/Save/prefs.gas"];
}
static NSString *prefs_get(NSString *path, NSString *key)          /* "key = value;" in the [prefs] block */
{
    NSString *t = [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:nil]; if (!t) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^[ \\t]*%@[ \\t]*=[ \\t]*([^;\\r\\n]*);", key]
                                                                        options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    return m ? [[t substringWithRange:[m rangeAtIndex:1]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : nil;
}
static void prefs_set(NSString *path, NSDictionary<NSString *, NSString *> *kv)
{
    NSMutableString *t = [[NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:nil] mutableCopy];
    NSString *nl = !t || [t containsString:@"\r\n"] ? @"\r\n" : @"\n";
    if (!t) t = [NSMutableString stringWithFormat:@"[prefs]%@{%@}%@", nl, nl, nl];
    for (NSString *key in kv) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^([ \\t]*%@[ \\t]*=[ \\t]*)[^;\\r\\n]*;", key]
                                                                            options:NSRegularExpressionAnchorsMatchLines error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
        if (m) { [t replaceCharactersInRange:m.range withString:[NSString stringWithFormat:@"%@%@;", [t substringWithRange:[m rangeAtIndex:1]], kv[key]]]; continue; }
        NSRange open = [t rangeOfString:@"{"];                              /* the [prefs] block's opening brace */
        if (open.location == NSNotFound) continue;
        [t insertString:[NSString stringWithFormat:@"%@\t%@ = %@;", nl, key, kv[key]] atIndex:NSMaxRange(open)];
    }
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [t writeToFile:path atomically:YES encoding:NSISOLatin1StringEncoding error:nil];
}
/* shaders and shadows: the game picks its own default for the graphics card (config/system_detail.gas) until one is
 * chosen; that is the "Game's Choice" entry, never written to prefs.gas */
static NSDictionary *game_choice(void) { return @{@"value": @"auto", @"label": @"Game's Choice", @"note": @"Until one is chosen, the game picks for the graphics card"}; }
static NSArray<NSDictionary *> *shader_choices(void)
{
    return @[@{@"value": @"none", @"label": @"Off", @"note": @"No shader effects"},
             @{@"value": @"standard", @"label": @"Standard", @"note": @"Water, glow and heat shimmer"},
             @{@"value": @"advanced", @"label": @"Advanced", @"note": @"Every effect, with water reflections (recommended)"}];
}
static NSArray<NSDictionary *> *game_shadow_choices(void)
{
    return @[@{@"value": @"none", @"label": @"Off", @"note": @"No character shadows"},
             @{@"value": @"simple", @"label": @"Simple", @"note": @"Round shadows under everyone"},
             @{@"value": @"complex_party", @"label": @"Party Complex", @"note": @"True shadows for your party (as the game shipped)"},
             @{@"value": @"complex", @"label": @"All Complex", @"note": @"True shadows for every character"}];
}
static NSArray<NSDictionary *> *filtering_choices(void)
{
    return @[@{@"value": @"bilinear", @"label": @"Bilinear", @"note": @"As the game shipped"},
             @{@"value": @"trilinear", @"label": @"Trilinear", @"note": @"Smoother distant textures (recommended)"}];
}
static NSArray<NSDictionary *> *detail_choices(void)
{
    return @[@{@"value": @"0.000000", @"label": @"Lowest", @"note": @"The fewest small objects"},
             @{@"value": @"0.250000", @"label": @"Low", @"note": @"A quarter of the small scenery"},
             @{@"value": @"0.500000", @"label": @"Medium", @"note": @"Half of the small scenery"},
             @{@"value": @"0.750000", @"label": @"High", @"note": @"Most of the small scenery"},
             @{@"value": @"1.000000", @"label": @"Full", @"note": @"Everything (as the game shipped)"}];
}
static NSArray<NSDictionary *> *gamma_choices(void)    /* the in-game slider's range in steps: 0.5 to 1.5 */
{
    NSMutableArray *a = [NSMutableArray array];
    for (int k = 0; k <= 10; k++) {
        double g = 0.5 + k / 10.0;
        [a addObject:@{@"value": [NSString stringWithFormat:@"%f", g], @"label": [NSString stringWithFormat:@"%.1f", g],
                       @"note": k == 5 ? @"As the game shipped" : k < 5 ? @"Darker" : @"Brighter"}];
    }
    return a;
}
/* a row's index for a value from prefs.gas: numbers compared as numbers; a value not offered becomes a "Custom" choice */
static NSInteger pref_index(DSRow *r, NSString *v, NSInteger dflt)
{
    if (!v.length) return dflt;
    for (NSUInteger k = 0; k < r.choices.count; k++) {
        NSString *c = r.choices[k][@"value"];
        if ([c isEqualToString:v] || (isdigit([c characterAtIndex:0]) && fabs(c.doubleValue - v.doubleValue) < 0.005)) return (NSInteger)k;
    }
    NSString *shown = isdigit([v characterAtIndex:0]) ? [NSString stringWithFormat:@"%.2f", v.doubleValue] : v;
    r.choices = [r.choices arrayByAddingObject:@{@"value": v, @"label": [NSString stringWithFormat:@"Custom (%@)", shown], @"note": @"Set in the game's own options"}];
    return (NSInteger)r.choices.count - 1;
}
/* the Game row: the game, or the Test Lab (the game beside the lab's controls, with copies of the saves) */
static NSArray<NSDictionary *> *mode_choices(void)
{
    return @[@{@"value": @"game", @"label": @"Dungeon Siege II", @"note": @"The campaign, and multiplayer from the main menu"},
             @{@"value": @"lab", @"label": @"Test Lab", @"note": @"The game beside the lab's controls, with copies of your saves"}];
}
static NSArray<NSDictionary *> *framerate_choices(void)
{
    NSInteger hz = NSScreen.mainScreen.maximumFramesPerSecond; if (hz <= 0) hz = 60;
    NSMutableArray *a = [NSMutableArray arrayWithObject:@{@"value": @"auto", @"label": @"Automatic",
        @"note": hz >= 120 ? @"Smooth 120 fps, 60 fps in the heaviest scenes" : @"Matches the display"}];
    if (hz >= 120) [a addObject:@{@"value": @"120", @"label": @"120 FPS", @"note": @"Locked to 120"}];
    [a addObject:@{@"value": @"60", @"label": @"60 FPS", @"note": @"Locked to 60; cooler and quieter"}];
    [a addObject:@{@"value": @"30", @"label": @"30 FPS", @"note": @"Saves battery"}];
    [a addObject:@{@"value": @"unlimited", @"label": @"Unlimited", @"note": @"No cap and no vertical sync (may tear)"}];
    return a;
}
/* ---- the CD key for online play ----
 * The game presents a "DoubleHash" of the player's product key to the GameSpy (now OpenSpy) lobby. The retail
 * installer derived it from the key; digital releases never ran that installer. As its Setup.exe does: the 25
 * characters read as a base-24 number over BCDFGHJKMPQRTVWXY2346789 into 15 little-endian bytes, SHA-1 of those,
 * SHA-1 of the digest, the first 8 bytes. Only the hash is stored (<data>/cdkey-hash.txt; the runtime puts it in the
 * registry, registry.c), never the key. Same computation as install.sh --cd-key. */
static BOOL cdkey_hash(NSString *key, uint8_t out[8])
{
    static const char A[] = "BCDFGHJKMPQRTVWXY2346789";
    NSString *k = [[[key uppercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""] stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (k.length != 25) return NO;
    uint8_t buf[15] = {0}; int top = 0;
    for (NSUInteger i = 0; i < 25; i++) {
        unichar ch = [k characterAtIndex:i]; const char *p = ch < 128 ? strchr(A, (char)ch) : NULL;
        if (!p || !ch) return NO;
        unsigned c = (unsigned)(p - A);
        for (int j = 0; j <= top; j++) { unsigned v = buf[j] * 24u + c; buf[j] = (uint8_t)v; c = v >> 8; }
        if (c) { if (top + 1 >= 15) return NO; buf[++top] = (uint8_t)c; }
    }
    uint8_t d1[CC_SHA1_DIGEST_LENGTH], d2[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(buf, sizeof buf, d1); CC_SHA1(d1, sizeof d1, d2);
    memcpy(out, d2, 8); return YES;
}
static NSString *cdkey_path(NSString *data) { return [data stringByAppendingPathComponent:@"cdkey-hash.txt"]; }
static BOOL cdkey_present(NSString *data) { return [NSFileManager.defaultManager fileExistsAtPath:cdkey_path(data)]; }
static NSArray<NSDictionary *> *cdkey_choice(NSString *data)
{
    return cdkey_present(data) ? @[@{@"value": @"set", @"label": @"CD Key Entered", @"note": @"Online play ready · press to change it"}]
                               : @[@{@"value": @"none", @"label": @"No CD Key", @"note": @"Needed for online play · press to enter your own"}];
}
/* the entry box; returns YES when the stored key changed */
static BOOL cdkey_panel(NSString *data)
{
    for (NSString *problem = nil;;) {
        NSAlert *a = [NSAlert new];
        a.messageText = problem ?: @"Your Dungeon Siege II CD Key";
        a.informativeText = @"The 25-character product key of your own original retail copy (the sticker under disc 1 in the box), for online play. "
                             "The Steam and GOG releases come without one. "
                             "Each copy needs its own key: the same key can't be online twice at once. Only a hash of it is kept on this Mac.";
        NSSecureTextField *f = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
        f.placeholderString = @"XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"; a.accessoryView = f;
        [a addButtonWithTitle:@"Save"]; [a addButtonWithTitle:@"Cancel"];
        BOOL had = cdkey_present(data); if (had) [a addButtonWithTitle:@"Remove Key"];
        a.window.initialFirstResponder = f;
        NSModalResponse r = [a runModal];
        if (r == NSAlertSecondButtonReturn) return NO;
        if (r == NSAlertThirdButtonReturn) { [NSFileManager.defaultManager removeItemAtPath:cdkey_path(data) error:nil]; return YES; }
        uint8_t h[8];
        if (!cdkey_hash(f.stringValue, h)) { problem = @"That isn't a product key: it has 25 letters and digits (no vowels, 0, 1 or 5)."; continue; }
        NSMutableString *hex = [NSMutableString string]; for (int i = 0; i < 8; i++) [hex appendFormat:@"%02x", h[i]];
        [NSFileManager.defaultManager createDirectoryAtPath:data withIntermediateDirectories:YES attributes:nil error:nil];
        [[hex stringByAppendingString:@"\n"] writeToFile:cdkey_path(data) atomically:YES encoding:NSASCIIStringEncoding error:nil];
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:cdkey_path(data) error:nil];
        return YES;
    }
}
static NSInteger index_of(NSArray<NSDictionary *> *c, NSString *v, NSInteger dflt)
{
    for (NSUInteger k = 0; k < c.count; k++) if ([c[k][@"value"] isEqualToString:v ?: @""]) return (NSInteger)k;
    return dflt;
}
/* the chosen settings as environment for the runtime (read later at start-up) */
static void apply(NSString *res, NSString *dist, NSString *fps)
{
    setenv("DS_RESOLUTION", res.UTF8String, 1);
    setenv("DS_DRAW_DISTANCE", dist.UTF8String, 1);
    if ([fps isEqualToString:@"unlimited"]) { setenv("DSR_FPSCAP", "0", 1); setenv("DSR_VSYNC", "0", 1); }
    else setenv("DSR_FPSCAP", fps.UTF8String, 1);
}
@interface DSBlockTarget : NSObject      /* a button action as a block */
@property (copy) void (^fire)(NSInteger tag);
- (void)clicked:(NSButton *)b;
@end
@implementation DSBlockTarget
- (void)clicked:(NSButton *)b { if (self.fire) self.fire(b.tag); }
@end

// ---------------------------------------------------------------- updates
/* install.sh gives each app an updater (Contents/MacOS/update, passed in DS_UPDATER): it fetches the branch the app
 * follows (main, or nightly for Nightly) from GitHub into a worktree of the checkout the app was installed from and
 * rebuilds the app from it, keeping the game folder, saves and settings. The launcher asks GitHub (in the
 * background, each time it opens) whether that branch moved past the commit the app was built from. */
enum { UPD_NONE, UPD_CHECKING, UPD_CURRENT, UPD_AVAILABLE, UPD_ERROR };
static void on_main(dispatch_block_t b) { CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, b); CFRunLoopWakeUp(CFRunLoopGetMain()); }
static NSString *short_commit(NSString *c) { return c.length > 7 ? [c substringToIndex:7] : (c ?: @""); }
static NSString *update_check(NSString *updater)   /* the newest commit of the branch on GitHub; nil if it can't be reached */
{
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"]; t.arguments = @[updater, @"--check"];
    NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ if (t.running) [t terminate]; });
    NSData *d = [p.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit];
    NSString *out = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (t.terminationStatus != 0 || !out.length) return nil;
    if (out.length >= 40) return [out substringToIndex:40];   /* a commit (an app built from source) */
    return [out rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound ? out : nil;   /* a release's tag (the downloaded app) */
}
static NSArray<NSDictionary *> *update_choice(int state, NSString *branch, NSString *built, NSString *latest)
{
    NSString *label = @"Not available", *note = @"This copy wasn't installed from the GitHub repository";
    switch (state) {
    case UPD_CHECKING: label = @"Checking..."; note = [NSString stringWithFormat:@"Asking GitHub for the newest %@", branch]; break;
    case UPD_CURRENT: label = @"Up to date"; note = [NSString stringWithFormat:@"%@ %@", branch, short_commit(built)]; break;
    case UPD_AVAILABLE: label = @"Update available"; note = [NSString stringWithFormat:@"%@ -> %@: press to install", short_commit(built), short_commit(latest)]; break;
    case UPD_ERROR: label = @"Couldn't check"; note = @"GitHub unreachable or not signed in: press to retry"; break;
    }
    return @[@{@"value": @"", @"label": label, @"note": note}];
}
/* the phase of install.sh's output, in words */
static NSString *update_phase(NSString *line, NSString *branch)
{
    if ([branch isEqualToString:@"release"]) {   /* the downloaded app's updater (setup/update.sh) */
        if ([line hasPrefix:@"== downloading "]) return [NSString stringWithFormat:@"Downloading %@ from GitHub", [line substringFromIndex:15]];
        if ([line hasPrefix:@"== unpacking"]) return @"Unpacking it";
        if ([line hasPrefix:@"== installing"]) return @"Installing the new app";
        return nil;
    }
    if ([line hasPrefix:@"== fetching"]) return @"Downloading the update from GitHub";
    if ([line hasPrefix:[NSString stringWithFormat:@"== %@:", branch]]) return [@"Got " stringByAppendingString:[line substringFromIndex:branch.length + 4]];
    if ([line hasPrefix:@"== analysis"]) return @"Rebuilding from your game: analysing its code (1 of 4)";
    if ([line hasPrefix:@"== lifting"]) return @"Rebuilding from your game: translating to native code (2 of 4)";
    if ([line hasPrefix:@"== compiling"]) return @"Rebuilding from your game: compiling (3 of 4)";
    if ([line hasPrefix:@"== installing"]) return @"Installing the new app (4 of 4)";
    return nil;
}
/* runs the updater with a progress window (modal); returns YES when the app was rebuilt */
static BOOL update_run(NSWindow *parent, NSString *updater, NSString *branch, NSString *logPath)
{
    NSPanel *pn = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 170) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    pn.title = @"Updating";
    NSTextField *title = [NSTextField labelWithString:@"Updating to the newest version"]; title.font = [NSFont boldSystemFontOfSize:14]; title.frame = NSMakeRect(20, 128, 480, 22);
    NSTextField *status = [NSTextField wrappingLabelWithString:@"Starting..."]; status.frame = NSMakeRect(20, 64, 480, 56);
    NSProgressIndicator *spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 44, 480, 12)]; spin.indeterminate = YES; [spin startAnimation:nil];
    NSTextField *time = [NSTextField labelWithString:@"This takes a few minutes. Your saves and settings are kept."]; time.font = [NSFont systemFontOfSize:11]; time.textColor = NSColor.secondaryLabelColor; time.frame = NSMakeRect(20, 14, 360, 18);
    NSButton *btn = [NSButton buttonWithTitle:@"Close" target:nil action:nil]; btn.frame = NSMakeRect(400, 8, 100, 30); btn.hidden = YES;
    for (NSView *x in @[title, status, spin, time, btn]) [pn.contentView addSubview:x];
    if (parent) [pn setFrameOrigin:NSMakePoint(NSMidX(parent.frame) - 260, NSMidY(parent.frame) - 85)]; else [pn center];
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"]; t.arguments = @[updater];
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe; t.standardError = pipe;
    NSMutableString *pending = [NSMutableString new], *tail = [NSMutableString new];
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData; if (!d.length) return;
        [log writeData:d];
        NSString *chunk = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        @synchronized (pending) {
            [pending appendString:chunk];
            NSRange nl;
            while ((nl = [pending rangeOfString:@"\n"]).location != NSNotFound) {
                NSString *line = [pending substringToIndex:nl.location]; [pending deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
                [tail appendFormat:@"%@\n", line]; if (tail.length > 600) [tail deleteCharactersInRange:NSMakeRange(0, tail.length - 600)];
                NSString *ph = update_phase(line, branch);
                if (ph) on_main(^{ status.stringValue = ph; });
            }
        }
    };
    __block BOOL ok = NO;
    __attribute__((objc_precise_lifetime)) DSBlockTarget *bt = [DSBlockTarget new];   /* a button's target is weak: kept here */
    bt.fire = ^(NSInteger tag) { (void)tag; [NSApp stopModal]; };
    btn.target = bt; btn.action = @selector(clicked:);
    t.terminationHandler = ^(NSTask *task) {
        int code = task.terminationStatus;
        on_main(^{
            pipe.fileHandleForReading.readabilityHandler = nil; [log closeFile];
            [spin stopAnimation:nil]; spin.hidden = YES; btn.hidden = NO;
            if (code == 0) { ok = YES; title.stringValue = @"Updated"; status.stringValue = @"The new version is installed. The app restarts when you press Restart."; btn.title = @"Restart"; }
            else {
                NSString *last; @synchronized (pending) { last = [[tail componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "]; }
                title.stringValue = @"The update didn't finish";
                status.stringValue = [NSString stringWithFormat:@"Nothing was changed if it stopped before installing. Details: %@  (%@)", logPath,
                                      last.length > 160 ? [last substringFromIndex:last.length - 160] : last];
                time.stringValue = @"";
            }
        });
    };
    if (![t launchAndReturnError:nil]) { [log closeFile]; return NO; }
    [pn makeKeyAndOrderFront:nil];
    [NSApp runModalForWindow:pn];
    [pn orderOut:nil];
    return ok;
}

static NSArray *eax_choices(void) {
    return @[@{@"value": @"false", @"label": @"Standard", @"note": @"Original sound without environmental effects"},
             @{@"value": @"true", @"label": @"EAX", @"note": @"Positional sound with room reflections and reverb"}];
}

/* Shows the launch window (modal) unless DS_NO_LAUNCHER is set; returns 0 to quit, 1 to play, 2/3 for the Test Lab.
 * DS_LAUNCHER_SHOT=<png> renders it to an image instead (development; DS_LAUNCHER_PAGE: a group opened). */
int ds_launcher_run(const char *game_dir, const char *data_dir)
{
    NSString *data = getenv("DS_LAUNCHER_HOME") ? @(getenv("DS_LAUNCHER_HOME")) : @(data_dir), *plistPath = [data stringByAppendingPathComponent:@"launcher.plist"];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:plistPath] ?: @{};
    DSRow *res = [DSRow new], *dist = [DSRow new], *fps = [DSRow new], *mode = [DSRow new];
    DSRow *notch = [DSRow new]; notch.title = @"Notch"; notch.choices = notch_choices(); notch.index = index_of(notch.choices, saved[@"notch"], 0);
    BOOL (^below)(void) = ^BOOL { return ![notch.choices[notch.index][@"value"] isEqualToString:@"around"]; };
    res.title = @"Resolution"; res.choices = resolution_choices(below()); res.index = index_of(res.choices, saved[@"resolution"], 0);
    DSRow *ui = [DSRow new]; ui.title = @"Interface Size"; ui.choices = ui_choices(res.choices[res.index][@"value"]); ui.index = index_of(ui.choices, saved[@"interfaceSize"], 0);
    dist.title = @"View Distance"; dist.choices = distance_choices(); dist.index = index_of(dist.choices, saved[@"viewDistance"], 0);
    fps.title = @"Frame Rate"; fps.choices = framerate_choices(); fps.index = index_of(fps.choices, saved[@"frameRate"], 0);
    mode.title = @"Game"; mode.choices = mode_choices(); mode.index = 0;   /* the Test Lab is chosen each time, not remembered */
    /* the game's own graphics options, from its prefs.gas */
    DSRow *shad = [DSRow new], *gsh = [DSRow new], *flt = [DSRow new], *det = [DSRow new], *gam = [DSRow new];
    shad.title = @"Shaders"; gsh.title = @"Shadows"; flt.title = @"Texture Filtering"; det.title = @"Object Detail"; gam.title = @"Gamma";
    DSRow *eaxRow = [DSRow new]; eaxRow.title = @"Environmental Audio";
    NSArray<DSRow *> *prefRows = @[shad, gsh, flt, det, gam, eaxRow];
    NSArray<NSString *> *prefKeys = @[@"shaders", @"video_shadows", @"texture_filtering", @"object_detail_level", @"video_gamma", @"eax_enabled"];
    NSArray *(^prefChoices)(NSInteger) = ^NSArray *(NSInteger k) { return k == 0 ? shader_choices() : k == 1 ? game_shadow_choices() : k == 2 ? filtering_choices() : k == 3 ? detail_choices() : k == 4 ? gamma_choices() : eax_choices(); };
    NSArray<NSNumber *> *prefDefault = @[@-1, @-1, @0, @4, @5, @0];      /* as the game shipped (config/options.gas); -1: the game's choice */
    NSString *pp = prefs_path(data); NSMutableDictionary *prefRead = [NSMutableDictionary dictionary];
    for (NSInteger k = 0; k < (NSInteger)prefRows.count; k++) {
        DSRow *row = prefRows[k]; NSString *v = prefs_get(pp, prefKeys[k]); if (v) prefRead[prefKeys[k]] = v;
        row.choices = prefChoices(k);
        if (prefDefault[k].integerValue < 0 && !v) { row.choices = [@[game_choice()] arrayByAddingObjectsFromArray:row.choices]; row.index = 0; }
        else row.index = pref_index(row, v, MAX(prefDefault[k].integerValue, 0));
    }
    void (^prefsSave)(void) = ^{                                    /* only what was changed; a new player's file is left to the game */
        NSMutableDictionary *ch = [NSMutableDictionary dictionary];
        for (NSInteger k = 0; k < (NSInteger)prefRows.count; k++) {
            NSString *now = prefRows[k].choices[prefRows[k].index][@"value"], *was = prefRead[prefKeys[k]];
            if (!was) was = prefDefault[k].integerValue < 0 ? @"auto" : prefChoices(k)[prefDefault[k].integerValue][@"value"];
            if (![now isEqualToString:@"auto"] && ![now isEqualToString:was]) ch[prefKeys[k]] = now;
        }
        if (ch.count) prefs_set(pp, ch);
    };
    const char *shot = getenv("DS_LAUNCHER_SHOT");
    if (getenv("DS_NO_LAUNCHER") && !shot) {
        if (saved.count) { apply(res.choices[res.index][@"value"], dist.choices[dist.index][@"value"], fps.choices[fps.index][@"value"]); apply_notch(notch.choices[notch.index][@"value"]);
                         apply_ui(res.choices[res.index][@"value"], ui.choices[ui.index][@"value"]); }
        return 1;
    }

    NSString *updater = getenv("DS_UPDATER") ? @(getenv("DS_UPDATER")) : nil, *branch = getenv("DS_UPDATE_BRANCH") ? @(getenv("DS_UPDATE_BRANCH")) : @"main";
    NSString *built = getenv("DS_BUILT_COMMIT") ? @(getenv("DS_BUILT_COMMIT")) : @"";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:updater ?: @""]) updater = nil;
    DSRow *upd = [DSRow new]; upd.title = @"Updates";
    __block int ustate = updater ? UPD_CHECKING : UPD_NONE; __block NSString *latest = nil;
    upd.choices = update_choice(ustate, branch, built, nil);
    BOOL shotMode = shot != NULL;
    DSRow *online = [DSRow new]; online.title = @"Online"; online.choices = cdkey_choice(data);
    DSSection *audio = [DSSection new]; audio.title = @"Audio"; audio.rows = @[eaxRow];
    audio.summary = ^NSString * { NSDictionary *c = eaxRow.choices[eaxRow.index]; return [NSString stringWithFormat:@"%@ · %@", c[@"label"], c[@"note"]]; };
    DSSection *display = [DSSection new], *graphics = [DSSection new], *onlineSec = [DSSection new], *updSec = [DSSection new];
    display.title = @"Display"; display.rows = notch_height() > 0 ? @[res, ui, notch, fps, dist, gam] : @[res, ui, fps, dist, gam];
    graphics.title = @"Graphics"; graphics.rows = @[shad, gsh, flt, det];
    onlineSec.title = @"Online"; onlineSec.summary = ^NSString * { NSDictionary *c = online.choices[online.index]; return [NSString stringWithFormat:@"%@ · LAN games need no key", c[@"label"]]; };
    updSec.title = @"Updates"; updSec.summary = ^NSString * { NSDictionary *c = upd.choices[upd.index]; return [c[@"note"] length] ? [NSString stringWithFormat:@"%@ · %@", c[@"label"], c[@"note"]] : c[@"label"]; };
    DSLaunchView *v = [[DSLaunchView alloc] initWithFrame:NSMakeRect(0, 0, 980, 660)];
    v.top = @[mode]; v.sections = @[display, graphics, audio, onlineSec, updSec]; v.open = -1; v.hover = v.pressed = HIT_NONE;
    v.onSaves = ^{   /* the game's own saves folder (made if the game hasn't yet) */
        NSString *sv = [data stringByAppendingPathComponent:@"drive_c/Users/player/Documents/My Games/Dungeon Siege 2/Save"];
        [NSFileManager.defaultManager createDirectoryAtPath:sv withIntermediateDirectories:YES attributes:nil error:nil];
        [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:sv]];
    };
    v.onFiles = ^{ [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:@(game_dir)]]; };
    __weak DSLaunchView *wv = v; __weak DSRow *wu = upd, *wo = online;
    onlineSec.activate = ^{ if (cdkey_panel(data)) wo.choices = cdkey_choice(data); };
    updSec.activate = ^{ if (wu.activate) wu.activate(); };
    __block BOOL wasBelow = below();
    v.onChange = ^{
        if (below() != wasBelow) {                                  /* the Notch row: "This display" changes size */
            NSString *cur = res.choices[res.index][@"value"]; wasBelow = below();
            res.choices = resolution_choices(wasBelow); res.index = index_of(res.choices, cur, 0);
        }
        {   /* the Resolution row: which interface sizes fit (the largest that still does, if the chosen one no longer fits) */
            NSString *cur = ui.choices[ui.index][@"value"]; ui.choices = ui_choices(res.choices[res.index][@"value"]);
            NSInteger k = (NSInteger)ui.choices.count - 1; while (k > 0 && [ui.choices[k][@"value"] intValue] > cur.intValue) k--;
            ui.index = k;
        }
    };
    void (^check)(void) = ^{
        if (!updater) return;
        ustate = UPD_CHECKING; wu.choices = update_choice(ustate, branch, built, nil); wv.needsDisplay = YES;
        void (^done)(NSString *) = ^(NSString *l) {
            latest = l; ustate = !l ? UPD_ERROR : [l isEqualToString:built] ? UPD_CURRENT : UPD_AVAILABLE;
            wu.choices = update_choice(ustate, branch, built, l); wv.needsDisplay = YES;
        };
        if (shotMode) { done(update_check(updater)); return; }               /* development: the result in the image */
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ NSString *l = update_check(updater); on_main(^{ done(l); }); });
    };
    check();
    upd.activate = ^{
        if (ustate == UPD_CHECKING) return;
        if (ustate != UPD_AVAILABLE) { check(); return; }
        NSAlert *a = [NSAlert new];
        a.messageText = [NSString stringWithFormat:@"Update to the newest %@?", [branch isEqualToString:@"nightly"] ? @"Nightly" : @"version"];
        a.informativeText = [branch isEqualToString:@"release"] ? [NSString stringWithFormat:@"%@ is downloaded from GitHub and replaces this app. Your game, saves and settings are kept; if the game's code changed, it is rebuilt from your copy when the app starts again.", latest] : [NSString stringWithFormat:@"The %@ branch (%@) is downloaded from GitHub and the app is rebuilt from your own copy of the game, "
                             "which takes a few minutes. Your game folder, saves and settings are kept. The app restarts when it is done.", branch, short_commit(latest)];
        [a addButtonWithTitle:@"Update"]; [a addButtonWithTitle:@"Cancel"];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
        NSString *logPath = [data stringByAppendingPathComponent:@"update.log"];
        if (update_run(wv.window, updater, branch, logPath)) {   /* restart: the new app, then this one ends */
            NSString *app = [[[updater stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            NSTask *o = [NSTask new]; o.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"]; o.arguments = @[@"-n", app];
            [o launchAndReturnError:nil]; [o waitUntilExit];
            exit(0);
        }
        check();
    };
    NSString *tank = [@(game_dir) stringByAppendingPathComponent:@"Resources/Objects.ds2res"], *m = @"art/bitmaps/gui/front_end/main/b_gui_fe_mn_";
    NSImage *(^art)(NSString *, BOOL) = ^NSImage *(NSString *name, BOOL trim) {
        CGImageRef img = dds_image(tank_read(tank, [[m stringByAppendingString:name] stringByAppendingString:@".dds"]));
        NSImage *r = img ? nsimg(img, trim ? opaque_bounds(img) : CGRectZero) : nil; if (img) CGImageRelease(img); return r;
    };
    {   /* the main menu's backdrop: eight 256x256 tiles, four across and two down */
        NSImage *bg = [[NSImage alloc] initWithSize:NSMakeSize(1024, 512)]; BOOL any = NO;
        [bg lockFocusFlipped:YES];
        [[NSColor colorWithSRGBRed:0.13 green:0.02 blue:0.01 alpha:1] setFill]; NSRectFill(NSMakeRect(0, 0, 1024, 512));   /* under the tiles' see-through parts */
        for (int k = 0; k < 8; k++) { NSImage *t = art([NSString stringWithFormat:@"back%02d", k + 1], NO);
            if (t) { any = YES; [t drawInRect:NSMakeRect(256 * (k % 4), 256 * (k / 4), 256, 256) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil]; } }
        [bg unlockFocus];
        v.stone = any ? bg : nil;
    }
    v.logo = art(@"logo", YES);
    v.wood = art(@"menubar-up", YES); v.woodHover = art(@"menubar-over", YES); v.woodDown = art(@"menubar-down", YES);
    /* the art: frames of the game's cutscenes, the store's key art, capsule and screenshots (see the top of this file) */
    NSString *artHome = getenv("DS_LAUNCHER_ART") ? @(getenv("DS_LAUNCHER_ART")) : [data stringByAppendingPathComponent:@"art"];
    NSArray<NSString *> *artDirs = getenv("DS_LAUNCHER_ART") ? @[artHome] : @[artHome, [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"art"]];
    NSImage *(^pic)(NSString *) = ^NSImage *(NSString *name) {
        for (NSString *d in artDirs) { NSImage *i = [[NSImage alloc] initWithContentsOfFile:[d stringByAppendingPathComponent:name]]; if (i.size.width > 16) return i; }
        return nil;
    };
    void (^loadArt)(void) = ^{
        NSMutableArray<NSImage *> *sc = [NSMutableArray array], *shots = [NSMutableArray array];
        for (int k = 1; k <= 16; k++) { NSImage *i = ready(pic([NSString stringWithFormat:@"scene-%d.jpg", k]), 1600); if (i) [sc addObject:i]; }
        for (int k = 1; k <= 6; k++) { NSImage *i = ready(pic([NSString stringWithFormat:@"store-shot-%d.jpg", k]), 1600); if (i) [shots addObject:i]; }
        for (NSUInteger k = 0; k < shots.count; k++) [sc insertObject:shots[k] atIndex:MIN(sc.count, 1 + 4 * k)];   /* one among every few frames */
        NSImage *hero = pic(@"store-hero.jpg") ?: pic(@"banner.jpg");
        if (hero) [sc insertObject:ready(hero, 2400) atIndex:MIN(sc.count, (NSUInteger)2)];
        if (!sc.count && wv.stone) [sc addObject:wv.stone];             /* offline, nothing made: the main menu's own backdrop */
        wv.scenes = sc; wv.banner = hero;
        NSImage *cap = pic(@"store-portrait.jpg"), *fr = pic(@"portrait.jpg");
        if (cap) { wv.portrait = ready(cap, 900); wv.portraitFx = 0.5; wv.portraitFy = 0.0; wv.portraitZ = 1.45; }   /* (the capsule's logo below the frame) */
        else if (fr) { wv.portrait = ready(fr, 900); wv.portraitFx = 0.5; wv.portraitFy = 0.4; wv.portraitZ = 1.0; }
        else if (hero) { wv.portrait = ready(hero, 2400); wv.portraitFx = 0.70; wv.portraitFy = 0.3; wv.portraitZ = 1.0; }   /* the heroes, on the key art's right */
        else wv.portrait = nil;
        NSImage *cg = ready(pic(@"card-game.jpg"), 800) ?: sc.firstObject, *cl = ready(pic(@"card-lab.jpg"), 800) ?: (sc.count > 1 ? sc.lastObject : wv.stone);
        wv.cards = @[cg ?: (id)NSNull.null, cl ?: (id)NSNull.null];
        [wv setNeedsArt];
    };
    loadArt();
    /* Steam's art the folder lacks (the downloaded app, or an install made offline): fetched while the window shows */
    NSDictionary *store = @{@"store-portrait.jpg": @"library_600x900_2x.jpg", @"store-hero.jpg": @"library_hero.jpg",
                            @"store-shot-1.jpg": @"ss_d37862b6d7553247dd3f14316a08832db02eabc5.1920x1080.jpg",
                            @"store-shot-2.jpg": @"ss_789bca4294a6dd6b9ccdf7ba57bd89687ea244e4.1920x1080.jpg",
                            @"store-shot-3.jpg": @"ss_3b738ee0742be358783d35c01edc11bde9aa9212.1920x1080.jpg"};
    BOOL (^fetchStore)(void) = ^BOOL {
        if (getenv("DS_LAUNCHER_OFFLINE") || getenv("DS_NO_DOWNLOADS")) return NO;
        __block BOOL got = NO;
        [store enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *file, BOOL *stop) {
            for (NSString *d in artDirs) if ([NSFileManager.defaultManager fileExistsAtPath:[d stringByAppendingPathComponent:name]]) return;
            if ([name isEqual:@"store-hero.jpg"] && pic(@"banner.jpg")) return;
            NSURL *u = [NSURL URLWithString:[@"https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/39200/" stringByAppendingString:file]];
            dispatch_semaphore_t done = dispatch_semaphore_create(0); __block NSData *got1 = nil;
            [[NSURLSession.sharedSession dataTaskWithRequest:[NSURLRequest requestWithURL:u cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:20]
                                           completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                if (!e && [(NSHTTPURLResponse *)r statusCode] == 200 && d.length > 20000) got1 = d; dispatch_semaphore_signal(done); }] resume];
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC));
            if (!got1 || ![[NSImage alloc] initWithData:got1]) return;
            [NSFileManager.defaultManager createDirectoryAtPath:artHome withIntermediateDirectories:YES attributes:nil error:nil];
            if ([got1 writeToFile:[artHome stringByAppendingPathComponent:name] atomically:YES]) got = YES;
        }];
        return got;
    };
    if (shot) { if (fetchStore()) loadArt(); }
    else dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ if (fetchStore()) on_main(^{ loadArt(); }); });
    if (shot) {   /* development: the window as an image, at twice its size (a Retina display's pixels) */
        if (getenv("DS_LAUNCHER_PAGE")) { v.open = atoi(getenv("DS_LAUNCHER_PAGE")); v.focus = 0; }
        if (getenv("DS_LAUNCHER_FOCUS")) { v.focus = atoi(getenv("DS_LAUNCHER_FOCUS")); v.keyed = YES; }
        v.t = getenv("DS_LAUNCHER_TIME") ? atof(getenv("DS_LAUNCHER_TIME")) : 4.0;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)v.bounds.size.width * 2 pixelsHigh:(NSInteger)v.bounds.size.height * 2
                                                                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        rep.size = v.bounds.size;
        [v displayRectIgnoringOpacity:v.bounds inContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        if (getenv("DS_LAUNCHER_TIMING")) {                          /* development: what a frame costs, once warm */
            double t0 = CACurrentMediaTime();
            for (int k = 0; k < 60; k++) { v.t += 1.0 / 60; [v displayRectIgnoringOpacity:v.bounds inContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]]; }
            fprintf(stderr, "frame: %.1f ms\n", (CACurrentMediaTime() - t0) * 1000 / 60);
        }
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(shot) atomically:YES];
        return 0;
    }

    NSWindow *w = [[NSWindow alloc] initWithContentRect:v.frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed = NO;   /* ARC owns it: AppKit's default would release it again when the close button closes it (a crash on exit) */
    w.titlebarAppearsTransparent = YES; w.titleVisibility = NSWindowTitleHidden; w.movableByWindowBackground = YES; w.title = @"Dungeon Siege II";
    w.backgroundColor = NSColor.blackColor; w.contentView = v; [w center]; [w makeFirstResponder:v];
    __block int result = 0;
    v.onPlay = ^{
        if (![mode.choices[mode.index][@"value"] isEqualToString:@"lab"]) { result = 1; [NSApp stopModal]; return; }
        /* the Test Lab: 2 with its saves as they are; 3 with fresh copies of the single-player saves first */
        NSString *saves = [data stringByAppendingPathComponent:@"test-lab/drive_c/Users/player/Documents/My Games/Dungeon Siege 2/Save/SinglePlayer"];
        BOOL have = [NSFileManager.defaultManager fileExistsAtPath:saves];
        NSAlert *a = [NSAlert new]; a.messageText = @"Start the Test Lab?";
        a.informativeText = have ? @"The game opens in a window beside the Test Lab's controls, with the lab's own copies of your single-player saves (yours are never changed). "
                                    "Fresh copies replace the lab's saves with your current ones; the earlier lab saves are kept in test-lab/save-backups."
                                 : @"The game opens in a window beside the Test Lab's controls. Your single-player saves are copied for the lab first; yours are never changed.";
        [a addButtonWithTitle:@"Start"]; if (have) [a addButtonWithTitle:@"Fresh Save Copies, Then Start"]; [a addButtonWithTitle:@"Cancel"];
        NSModalResponse r = [a runModal];
        if (r == NSAlertFirstButtonReturn) result = have ? 2 : 3; else if (have && r == NSAlertSecondButtonReturn) result = 3; else return;
        [NSApp stopModal];
    };
    v.onQuit = ^{ result = 0; [NSApp stopModal]; };
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:w queue:nil usingBlock:^(NSNotification *n) { (void)n; [NSApp stopModal]; }];
    [NSApp activateIgnoringOtherApps:YES];
    [w makeKeyAndOrderFront:nil];
    /* the animation, 60 times a second (in the modal loop's mode too); a controller: the d-pad or the left stick moves
     * (held: repeats), A chooses, B goes back, Start plays */
    double t0 = CACurrentMediaTime(); __block int held = 0; __block double next = 0; __block uint32_t was = 0;
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    NSTimer *anim = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *tm) {
        DSLaunchView *sv = wv; if (!sv) return;
        double t = sv.t = CACurrentMediaTime() - t0;
        GCExtendedGamepad *g = (GCController.current ?: GCController.controllers.firstObject).extendedGamepad;
        if (g && NSApp.active && sv.window.isKeyWindow) {
            float x = g.leftThumbstick.xAxis.value, y = g.leftThumbstick.yAxis.value;
            int dir = g.dpad.left.pressed || x < -0.6f ? NAV_LEFT : g.dpad.right.pressed || x > 0.6f ? NAV_RIGHT
                    : g.dpad.up.pressed || y > 0.6f ? NAV_UP : g.dpad.down.pressed || y < -0.6f ? NAV_DOWN : 0;
            if (dir != held) { held = dir; next = t + 0.38; if (dir) [sv nav:dir]; }
            else if (dir && t >= next) { next = t + 0.14; [sv nav:dir]; }
            uint32_t now = (g.buttonA.pressed ? 1u : 0) | (g.buttonB.pressed ? 2u : 0) | (g.buttonMenu.pressed ? 4u : 0), down = now & ~was; was = now;
            if (down & 1) [sv nav:NAV_OK]; else if (down & 2) [sv nav:NAV_BACK]; else if (down & 4) [sv nav:NAV_PLAY];
        } else { held = 0; was = 0; }
        sv.needsDisplay = YES;
        static double lastT; if (getenv("DS_LAUNCHER_TIMING") && t - lastT >= 1) {   /* development: frames a second, then quits after 6 */
            fprintf(stderr, "fps: %.0f\n", frames_drawn / (t - lastT)); frames_drawn = 0; lastT = t; if (t > 6) [NSApp stopModal]; }
    }];
    [[NSRunLoop currentRunLoop] addTimer:anim forMode:NSRunLoopCommonModes];
    if (getenv("DS_LAUNCHER_PLAY"))   /* development: Play pressed once the window is up */
        [[NSRunLoop currentRunLoop] addTimer:[NSTimer timerWithTimeInterval:1.5 repeats:NO block:^(NSTimer *tm) { if (wv.onPlay) wv.onPlay(); }] forMode:NSRunLoopCommonModes];
    [NSApp runModalForWindow:w];
    [anim invalidate];
    [w orderOut:nil];
    if (!result) return 0;
    NSString *rv = res.choices[res.index][@"value"], *fv = fps.choices[fps.index][@"value"];
    NSString *dv = dist.choices[dist.index][@"value"];
    NSString *nv = notch.choices[notch.index][@"value"], *uv = ui.choices[ui.index][@"value"];
    [@{@"resolution": rv, @"viewDistance": dv, @"frameRate": fv, @"notch": nv, @"interfaceSize": uv} writeToFile:plistPath atomically:YES];
    prefsSave();
    apply(rv, dv, fv); apply_notch(nv); apply_ui(rv, uv);
    return result;
}
