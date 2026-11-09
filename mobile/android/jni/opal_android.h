#ifndef OPAL_ANDROID_H
#define OPAL_ANDROID_H
#include <stddef.h>

void opal_android_prepare_environment(void);
const char *opal_android_resource_dir(void);
void opal_android_safe_area(float *top, float *bottom, float *left, float *right, float *keyboard);
void opal_android_pick_file(void);
void opal_android_log(const unsigned char *bytes, size_t len);
void opal_android_ready(void);

#endif
