// Thin C wrapper around ONNX Runtime for PP-OCR inference
// Exposes only what ZigZag needs — no need to import the full 8000-line ORT header
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initialize ORT and load models. Returns 0 on success.
// det_path: path to PP-OCR detection model (.onnx)
// rec_path: path to PP-OCR recognition model (.onnx)  
// dict_path: path to character dictionary (en_dict.txt)
int ocr_init(const char* det_path, const char* rec_path, const char* dict_path);

// Run OCR on an image loaded from file (JPEG/PNG).
// Returns a newly allocated string with all detected text (caller must free with ocr_free_text).
// Returns NULL on failure.
char* ocr_recognize_file(const char* image_path);

// Run OCR on raw image bytes (JPEG/PNG format, not decoded pixels).
// Returns a newly allocated string with all detected text.
char* ocr_recognize_bytes(const uint8_t* data, size_t data_len);

// Run OCR on pre-decoded RGBA pixels.
// w, h: image dimensions. rgba: pixel data (w*h*4 bytes, RGBA order).
char* ocr_recognize_rgba(const uint8_t* rgba, int w, int h);

// Free text returned by ocr_recognize_*
void ocr_free_text(char* text);

// Cleanup — release all ORT resources
void ocr_cleanup(void);

#ifdef __cplusplus
}
#endif
