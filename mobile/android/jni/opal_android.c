// Android host bridge: JNI glue between OpalActivity (Java) and the shared Zig app.
// Counterpart of mobile/ios/bridge.m.
#include <jni.h>
#include <android/log.h>
#include <libavcodec/jni.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_system.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>
#include "opal_android.h"

// Exported by src/android.zig.
extern bool opal_android_open_media(const char *path_or_url);
extern bool opal_android_valid_media_url(const char *raw);
extern bool opal_android_player_probe(double *time, bool *video);
extern bool opal_android_active_transfers(void);

#define LOG_TAG "Opal"

static JavaVM *g_vm;
static char g_resource_dir[1024];
static SDL_Mutex *g_lock;
// Physical px, written by the Java insets listener, read by the Zig frame.
static float g_top, g_bottom, g_left, g_right, g_ime;

static void wake_ui(void) {
    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_EVENT_USER;
    SDL_PushEvent(&event);
}

static void mkdir_p(const char *path) {
    char tmp[1024];
    size_t n = strlen(path);
    if (n == 0 || n >= sizeof(tmp)) return;
    memcpy(tmp, path, n + 1);
    for (size_t i = 1; i < n; i++) {
        if (tmp[i] == '/') {
            tmp[i] = 0;
            mkdir(tmp, 0770);
            tmp[i] = '/';
        }
    }
    mkdir(tmp, 0770);
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    g_vm = vm;
    av_jni_set_java_vm(vm, NULL);
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNICALL Java_com_debpalash_opal_OpalActivity_nativeSetInsets(
    JNIEnv *env, jclass cls, jfloat top, jfloat bottom, jfloat left, jfloat right, jfloat ime) {
    (void)env; (void)cls;
    if (!g_lock) g_lock = SDL_CreateMutex();
    if (g_lock) SDL_LockMutex(g_lock);
    g_top = top; g_bottom = bottom; g_left = left; g_right = right; g_ime = ime;
    if (g_lock) SDL_UnlockMutex(g_lock);
    wake_ui();
}

JNIEXPORT jboolean JNICALL Java_com_debpalash_opal_OpalActivity_nativeHasActiveTransfers(
    JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return opal_android_active_transfers() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL Java_com_debpalash_opal_OpalActivity_nativeOpenMedia(
    JNIEnv *env, jclass cls, jstring location) {
    (void)cls;
    if (!location) return JNI_FALSE;
    const char *utf = (*env)->GetStringUTFChars(env, location, NULL);
    if (!utf) return JNI_FALSE;
    bool ok = false;
    // Local copies (absolute paths) pass straight through; everything else must be a media link.
    if (utf[0] == '/' || opal_android_valid_media_url(utf)) ok = opal_android_open_media(utf);
    (*env)->ReleaseStringUTFChars(env, location, utf);
    return ok ? JNI_TRUE : JNI_FALSE;
}

static void extract_asset(const char *name, const char *dir) {
    char dst[1100];
    snprintf(dst, sizeof(dst), "%s/%s", dir, name);
    size_t size = 0;
    void *data = SDL_LoadFile(name, &size);  // Android: reads from APK assets
    if (!data) return;
    if (!SDL_SaveFile(dst, data, size)) opal_android_log((const unsigned char *)"asset extract failed", 20);
    SDL_free(data);
}

void opal_android_prepare_environment(void) {
    if (!g_lock) g_lock = SDL_CreateMutex();
    const char *internal = SDL_GetAndroidInternalStoragePath();
    const char *external = SDL_GetAndroidExternalStoragePath();
    const char *cache = SDL_GetAndroidCachePath();
    if (!internal) internal = "/data/local/tmp";
    setenv("HOME", external ? external : internal, 1);
    setenv("XDG_CONFIG_HOME", internal, 1);
    setenv("XDG_CACHE_HOME", cache ? cache : internal, 1);
    if (external) {
        char downloads[1100];
        snprintf(downloads, sizeof(downloads), "%s/Downloads", external);
        mkdir_p(downloads);
    }
    SDL_SetHint(SDL_HINT_ORIENTATIONS, "Portrait LandscapeLeft LandscapeRight PortraitUpsideDown");
    SDL_SetHint(SDL_HINT_ANDROID_TRAP_BACK_BUTTON, "1");

    snprintf(g_resource_dir, sizeof(g_resource_dir), "%s/resources", internal);
    mkdir_p(g_resource_dir);
    extract_asset("cacert.pem", g_resource_dir);
    extract_asset("plugins-manifest.json", g_resource_dir);
    // Subtitle/OSD fonts for libass (no fontconfig fonts on Android).
    char fonts[1100];
    snprintf(fonts, sizeof(fonts), "%s/fonts", g_resource_dir);
    mkdir_p(fonts);
    extract_asset("fonts/NotoSans-Regular.ttf", g_resource_dir);
    extract_asset("fonts/NotoSans-Bold.ttf", g_resource_dir);
}

const char *opal_android_resource_dir(void) {
    if (!g_resource_dir[0]) {
        // Read from worker threads (TLS setup) possibly before prepare_environment: derive it once.
        const char *internal = SDL_GetAndroidInternalStoragePath();
        snprintf(g_resource_dir, sizeof(g_resource_dir), "%s/resources", internal ? internal : "/data/local/tmp");
    }
    return g_resource_dir;
}

void opal_android_safe_area(float *top, float *bottom, float *left, float *right, float *keyboard) {
    if (g_lock) SDL_LockMutex(g_lock);
    *top = g_top;
    *bottom = g_bottom > g_ime ? g_bottom : g_ime;
    *left = g_left;
    *right = g_right;
    *keyboard = g_ime;
    if (g_lock) SDL_UnlockMutex(g_lock);
}

void opal_android_pick_file(void) {
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
    jobject activity = (jobject)SDL_GetAndroidActivity();
    if (!env || !activity) return;
    jclass cls = (*env)->GetObjectClass(env, activity);
    jmethodID method = cls ? (*env)->GetMethodID(env, cls, "pickFile", "()V") : NULL;
    if (method) (*env)->CallVoidMethod(env, activity, method);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    if (cls) (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, activity);
}

void opal_android_set_landscape(bool on) {
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
    jobject activity = (jobject)SDL_GetAndroidActivity();
    if (!env || !activity) return;
    jclass cls = (*env)->GetObjectClass(env, activity);
    jmethodID method = cls ? (*env)->GetMethodID(env, cls, "setPlayerLandscape", "(Z)V") : NULL;
    if (method) (*env)->CallVoidMethod(env, activity, method, on ? JNI_TRUE : JNI_FALSE);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    if (cls) (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, activity);
}

void opal_android_move_task_to_back(void) {
    JNIEnv *env = (JNIEnv *)SDL_GetAndroidJNIEnv();
    jobject activity = (jobject)SDL_GetAndroidActivity();
    if (!env || !activity) return;
    jclass cls = (*env)->GetObjectClass(env, activity);
    jmethodID method = cls ? (*env)->GetMethodID(env, cls, "moveTaskToBack", "(Z)Z") : NULL;
    if (method) (*env)->CallBooleanMethod(env, activity, method, JNI_TRUE);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
    if (cls) (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, activity);
}

void opal_android_log(const unsigned char *bytes, size_t len) {
    char buf[1024];
    while (len > 0) {
        size_t n = len < sizeof(buf) - 1 ? len : sizeof(buf) - 1;
        memcpy(buf, bytes, n);
        buf[n] = 0;
        __android_log_write(ANDROID_LOG_INFO, LOG_TAG, buf);
        bytes += n;
        len -= n;
    }
}

void opal_android_ready(void) {
    fprintf(stderr, "OPAL_ANDROID_UI_READY\n");
    fflush(stderr);
    __android_log_write(ANDROID_LOG_INFO, LOG_TAG, "OPAL_ANDROID_UI_READY");
}
