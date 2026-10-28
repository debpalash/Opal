#import <AppKit/AppKit.h>
#include <stdint.h>
#include <stdlib.h>

// AppKit supplies script-specific fallback fonts and shapes conjuncts and marks.
// Returned pixels are premultiplied RGBA, owned by the caller.
void *opal_lyrics_raster(const char *utf8, size_t length, float width,
                        float size, float scale, uint32_t rgb,
                        uint32_t *out_w, uint32_t *out_h) {
    @autoreleasepool {
        NSString *text = [[NSString alloc] initWithBytes:utf8 length:length encoding:NSUTF8StringEncoding];
        if (!text || width < 1 || size < 1 || scale < 1) return NULL;
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.lineBreakMode = NSLineBreakByWordWrapping;
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:size],
            NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:((rgb >> 16) & 255)/255.0 green:((rgb >> 8) & 255)/255.0 blue:(rgb & 255)/255.0 alpha:1],
            NSParagraphStyleAttributeName: style
        };
        NSAttributedString *line = [[NSAttributedString alloc] initWithString:text attributes:attrs];
        NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading;
        NSRect bounds = [line boundingRectWithSize:NSMakeSize(width, 16384) options:options];
        uint32_t w = (uint32_t)ceil(width * scale);
        uint32_t h = (uint32_t)ceil(MAX(size * 1.5, ceil(bounds.size.height) + 4) * scale);
        if (w > 16384 || h > 32768) return NULL;
        void *pixels = calloc((size_t)w * h, 4);
        if (!pixels) return NULL;
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, (size_t)w * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(space);
        if (!ctx) { free(pixels); return NULL; }
        CGContextTranslateCTM(ctx, 0, h);
        CGContextScaleCTM(ctx, scale, -scale);
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES]];
        [line drawWithRect:NSMakeRect(0, 2, width, h/scale - 2) options:options];
        [NSGraphicsContext restoreGraphicsState];
        CGContextRelease(ctx);
        *out_w = w; *out_h = h;
        return pixels;
    }
}
void opal_lyrics_raster_free(void *pixels) { free(pixels); }
