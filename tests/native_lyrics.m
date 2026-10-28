#import <AppKit/AppKit.h>
#include <assert.h>
extern void *opal_lyrics_raster(const char *,size_t,float,float,float,uint32_t,uint32_t *,uint32_t *);
extern void opal_lyrics_raster_free(void *);
int main(void) { @autoreleasepool {
    NSArray *lines = @[@"संगीत की पंक्ति", @"தமிழ் பாடல் வரிகள்", @"తెలుగు పాట", @"বাংলা গান", @"മലയാളം പാട്ട്", @"ಕನ್ನಡ ಹಾಡು", @"ਪੰਜਾਬੀ ਗੀਤ", @"ગુજરાતી ગીત"];
    for (NSString *line in lines) {
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t w=0,h=0; unsigned char *p=opal_lyrics_raster(data.bytes,data.length,240,18,2,0xffffff,&w,&h);
        assert(p && w==480 && h>0); size_t ink=0;
        for(size_t i=3;i<(size_t)w*h*4;i+=4) if(p[i]) ink++;
        assert(ink>0);
        const char *capture = getenv("OPAL_NATIVE_CAPTURE_DIR");
        if (capture) {
            NSBitmapImageRep *image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&p pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w*4 bitsPerPixel:32];
            NSString *path = [[NSString stringWithUTF8String:capture] stringByAppendingPathComponent:[NSString stringWithFormat:@"lyrics-%lu.png", (unsigned long)[lines indexOfObject:line]]];
            assert([[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES]);
        }
        opal_lyrics_raster_free(p);
        NSString *longLine = [[NSArray arrayWithObjects:line,line,line,line,line,line,nil] componentsJoinedByString:@" "];
        data=[longLine dataUsingEncoding:NSUTF8StringEncoding]; uint32_t wrappedH=0;
        p=opal_lyrics_raster(data.bytes,data.length,100,18,2,0xffffff,&w,&wrappedH);
        assert(p && wrappedH>h); opal_lyrics_raster_free(p);
    }
    puts("8 Indic scripts: rasterization and wrapping passed");
} }
