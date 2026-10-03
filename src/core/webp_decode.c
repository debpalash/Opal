/* Opal shared raster boundary. Original project code, GPL-3.0.
 * libwebp decoder API is BSD-licensed; no upstream implementation copied.
 */
#include <webp/decode.h>
#include <stdint.h>
#include <limits.h>
#include <stdlib.h>

int opal_webp_info(const unsigned char *data, size_t size, int *width, int *height) {
    if (!data || !width || !height) return 0;
    return WebPGetInfo(data, size, width, height);
}

unsigned char *opal_webp_decode_rgba(const unsigned char *data, size_t size,
                                    int width, int height, size_t rgba_bytes) {
    if (!data || width <= 0 || height <= 0 || width > INT_MAX / 4) return NULL;
    const size_t stride = (size_t)width * 4;
    if ((size_t)height > SIZE_MAX / stride || stride * (size_t)height != rgba_bytes) return NULL;
    int actual_width = 0, actual_height = 0;
    if (!WebPGetInfo(data, size, &actual_width, &actual_height) ||
        actual_width != width || actual_height != height) return NULL;
    unsigned char *pixels = (unsigned char *)malloc(rgba_bytes);
    if (!pixels) return NULL;
    if (!WebPDecodeRGBAInto(data, size, pixels, rgba_bytes, (int)stride)) {
        free(pixels);
        return NULL;
    }
    return pixels;
}
