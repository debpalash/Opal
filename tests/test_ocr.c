// ZigZag OCR Test — benchmarks on real comic-style pages
// Build: gcc -O2 -o tests/test_ocr tests/test_ocr.c ort/ocr_ort.c -I ort/ -L ort/ -lonnxruntime -lm -Wno-unused-result
// Run:   LD_LIBRARY_PATH=ort ./tests/test_ocr

#include "ocr_ort.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdint.h>

// Inline stb_image for loading test PNGs
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include "stb_image.h"

static double time_ms(struct timespec* t0, struct timespec* t1) {
    return (t1->tv_sec - t0->tv_sec) * 1000.0 + (t1->tv_nsec - t0->tv_nsec) / 1e6;
}

static void test_file(const char* path) {
    int w, h, ch;
    struct timespec t0, t1;
    
    // Load image
    unsigned char* rgba = stbi_load(path, &w, &h, &ch, 4);
    if (!rgba) {
        printf("  SKIP: could not load %s\n", path);
        return;
    }
    printf("  Image: %s (%dx%d)\n", path, w, h);
    
    // Run OCR
    clock_gettime(CLOCK_MONOTONIC, &t0);
    char* text = ocr_recognize_rgba(rgba, w, h);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    
    double ms = time_ms(&t0, &t1);
    printf("  Time: %.1f ms\n", ms);
    
    if (text && strlen(text) > 0) {
        // Show first 200 chars
        int len = strlen(text);
        if (len > 200) text[200] = '\0';
        printf("  Text:\n");
        // Indent each line
        char* line = strtok(text, "\n");
        while (line) {
            printf("    > %s\n", line);
            line = strtok(NULL, "\n");
        }
    } else {
        printf("  Text: (none detected)\n");
    }
    
    if (text) ocr_free_text(text);
    stbi_image_free(rgba);
    printf("\n");
}

int main(void) {
    printf("╔══════════════════════════════════════════╗\n");
    printf("║  ZigZag OCR Benchmark (ONNX + PP-OCR)   ║\n");
    printf("╚══════════════════════════════════════════╝\n\n");
    
    // Init
    struct timespec t0, t1;
    printf("[INIT] Loading ONNX models...\n");
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int ret = ocr_init("models/ppocr_det.onnx", "models/ppocr_rec.onnx", "models/en_dict.txt");
    clock_gettime(CLOCK_MONOTONIC, &t1);
    
    if (ret != 0) {
        printf("  FAIL: models not found\n");
        return 1;
    }
    printf("  Init: %.0f ms\n\n", time_ms(&t0, &t1));
    
    // Test comic pages
    printf("[PAGE 1] Speech bubbles (800x1200)\n");
    test_file("/tmp/comic_test/page1.png");
    
    printf("[PAGE 2] Action scene (800x1200)\n");
    test_file("/tmp/comic_test/page2.png");
    
    printf("[PAGE 3] Dense dialogue (800x1200)\n");
    test_file("/tmp/comic_test/page3.png");
    
    // Cleanup
    ocr_cleanup();
    printf("Done.\n");
    return 0;
}
