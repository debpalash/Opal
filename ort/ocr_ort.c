// OCR ONNX Runtime wrapper for ZigZag
// Uses PP-OCR detection + recognition models via ORT C API
// Simplified pipeline: detect text regions → recognize each → concatenate
//
// Build: cc -shared -o libocr_ort.so ort/ocr_ort.c -I ort/ -L ort/ -lonnxruntime -lm
//        (or link into the Zig build)

#include "ocr_ort.h"
#include "onnxruntime_c_api.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// Note: No stb_image needed here — Zig side decodes images and passes RGBA pixels

static const OrtApi* g_ort = NULL;
static OrtEnv* g_env = NULL;
static OrtSession* g_det_session = NULL;
static OrtSession* g_rec_session = NULL;
static OrtSession* g_bubble_session = NULL;  // Speech bubble detector
static OrtSessionOptions* g_session_opts = NULL;

// Auto-detected model output names (differ between PP-OCR versions)
static char g_det_output_name[64] = "sigmoid_0.tmp_0";  // V4 default
static char g_rec_output_name[64] = "softmax_2.tmp_0";  // V4 default

// Character dictionary
static char** g_dict = NULL;
static int g_dict_size = 0;

// Helper: check ORT status
#define ORT_CHECK(expr) do { \
    OrtStatus* _s = (expr); \
    if (_s != NULL) { \
        const char* msg = g_ort->GetErrorMessage(_s); \
        fprintf(stderr, "[OCR-ORT] Error: %s\n", msg); \
        g_ort->ReleaseStatus(_s); \
        return -1; \
    } \
} while(0)

#define ORT_CHECK_NULL(expr) do { \
    OrtStatus* _s = (expr); \
    if (_s != NULL) { \
        const char* msg = g_ort->GetErrorMessage(_s); \
        fprintf(stderr, "[OCR-ORT] Error: %s\n", msg); \
        g_ort->ReleaseStatus(_s); \
        return NULL; \
    } \
} while(0)

static int load_dict(const char* dict_path) {
    FILE* f = fopen(dict_path, "r");
    if (!f) return -1;
    
    // Count lines
    int count = 0;
    char line[64];
    while (fgets(line, sizeof(line), f)) count++;
    rewind(f);
    
    // +2 for blank token at start and end
    g_dict_size = count + 2;
    g_dict = (char**)calloc(g_dict_size, sizeof(char*));
    g_dict[0] = strdup(" "); // blank/CTC token
    
    int i = 1;
    while (fgets(line, sizeof(line), f) && i < g_dict_size - 1) {
        // Remove newline
        int len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = 0;
        g_dict[i++] = strdup(line);
    }
    g_dict[g_dict_size - 1] = strdup(" "); // end token
    
    fclose(f);
    return 0;
}

int ocr_init(const char* det_path, const char* rec_path, const char* dict_path) {
    g_ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!g_ort) {
        fprintf(stderr, "[OCR-ORT] Failed to get ORT API\n");
        return -1;
    }
    
    ORT_CHECK(g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "zigzag_ocr", &g_env));
    ORT_CHECK(g_ort->CreateSessionOptions(&g_session_opts));
    ORT_CHECK(g_ort->SetIntraOpNumThreads(g_session_opts, 2));
    ORT_CHECK(g_ort->SetSessionGraphOptimizationLevel(g_session_opts, ORT_ENABLE_ALL));
    
    // Load detection model
    ORT_CHECK(g_ort->CreateSession(g_env, det_path, g_session_opts, &g_det_session));
    
    // Auto-detect det output name from loaded model
    {
        OrtAllocator* allocator = NULL;
        g_ort->GetAllocatorWithDefaultOptions(&allocator);
        if (allocator) {
            char* name = NULL;
            OrtStatus* ns = g_ort->SessionGetOutputName(g_det_session, 0, allocator, &name);
            if (ns == NULL && name) {
                strncpy(g_det_output_name, name, sizeof(g_det_output_name) - 1);
                allocator->Free(allocator, name);
                fprintf(stderr, "[OCR-ORT] Det output: %s\n", g_det_output_name);
            } else if (ns) g_ort->ReleaseStatus(ns);
        }
    }
    
    // Load recognition model
    ORT_CHECK(g_ort->CreateSession(g_env, rec_path, g_session_opts, &g_rec_session));
    
    // Auto-detect rec output name from loaded model
    {
        OrtAllocator* allocator = NULL;
        g_ort->GetAllocatorWithDefaultOptions(&allocator);
        if (allocator) {
            char* name = NULL;
            OrtStatus* ns = g_ort->SessionGetOutputName(g_rec_session, 0, allocator, &name);
            if (ns == NULL && name) {
                strncpy(g_rec_output_name, name, sizeof(g_rec_output_name) - 1);
                allocator->Free(allocator, name);
                fprintf(stderr, "[OCR-ORT] Rec output: %s\n", g_rec_output_name);
            } else if (ns) g_ort->ReleaseStatus(ns);
        }
    }
    
    // Load bubble detector model (optional — fall back to heuristic if missing)
    {
        // Derive bubble model path from det_path directory
        char bubble_path[512];
        const char* last_slash = strrchr(det_path, '/');
        if (last_slash) {
            int dir_len = (int)(last_slash - det_path + 1);
            memcpy(bubble_path, det_path, dir_len);
            strcpy(bubble_path + dir_len, "bubble_det.onnx");
        } else {
            strcpy(bubble_path, "models/bubble_det.onnx");
        }
        OrtStatus* bs = g_ort->CreateSession(g_env, bubble_path, g_session_opts, &g_bubble_session);
        if (bs != NULL) {
            g_ort->ReleaseStatus(bs);
            g_bubble_session = NULL;
            fprintf(stderr, "[OCR-ORT] Bubble detector not found at %s (using heuristic fallback)\n", bubble_path);
        } else {
            fprintf(stderr, "[OCR-ORT] Bubble detector loaded: %s\n", bubble_path);
        }
    }
    
    // Load dictionary
    if (load_dict(dict_path) != 0) {
        fprintf(stderr, "[OCR-ORT] Failed to load dictionary: %s\n", dict_path);
        return -1;
    }
    
    fprintf(stderr, "[OCR-ORT] Initialized (det=%s, rec=%s, dict=%d chars, bubble=%s)\n",
            det_path, rec_path, g_dict_size, g_bubble_session ? "RCNN" : "heuristic");
    return 0;
}

// Bilinear interpolation helper — much better quality than nearest neighbor
static inline void bilinear_sample(const unsigned char* rgba, int w, int h,
                                    float fx, float fy, float* out_rgb) {
    int x0 = (int)fx;
    int y0 = (int)fy;
    int x1 = x0 + 1;
    int y1 = y0 + 1;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 >= w) x1 = w - 1;
    if (y1 >= h) y1 = h - 1;
    float dx = fx - (int)fx;
    float dy = fy - (int)fy;
    if (dx < 0) dx = 0;
    if (dy < 0) dy = 0;
    
    for (int c = 0; c < 3; c++) {
        float v00 = rgba[(y0 * w + x0) * 4 + c];
        float v10 = rgba[(y0 * w + x1) * 4 + c];
        float v01 = rgba[(y1 * w + x0) * 4 + c];
        float v11 = rgba[(y1 * w + x1) * 4 + c];
        out_rgb[c] = (v00 * (1-dx) * (1-dy) + v10 * dx * (1-dy) +
                      v01 * (1-dx) * dy + v11 * dx * dy) / 255.0f;
    }
}

// Preprocess image for detection: resize to max 1280px, bilinear, normalize, NCHW
static float* preprocess_det(const unsigned char* rgba, int w, int h, 
                              int* out_w, int* out_h) {
    // Scale to max dimension 1280 (higher res = better small text detection)
    float scale = 1.0f;
    int max_dim = w > h ? w : h;
    if (max_dim > 1280) {
        scale = 1280.0f / max_dim;
    }
    int nw = (int)(w * scale);
    int nh = (int)(h * scale);
    // Round to multiple of 32 for PP-OCR
    nw = ((nw + 31) / 32) * 32;
    nh = ((nh + 31) / 32) * 32;
    
    *out_w = nw;
    *out_h = nh;
    
    // Allocate NCHW tensor (1, 3, nh, nw)
    float* tensor = (float*)calloc(3 * nh * nw, sizeof(float));
    if (!tensor) return NULL;
    
    // Mean and std for PP-OCR normalization
    float mean[3] = {0.485f, 0.456f, 0.406f};
    float std[3] = {0.229f, 0.224f, 0.225f};
    
    for (int y = 0; y < nh; y++) {
        for (int x = 0; x < nw; x++) {
            // Bilinear interpolation for quality resize
            float fx = x / scale;
            float fy = y / scale;
            float rgb[3];
            bilinear_sample(rgba, w, h, fx, fy, rgb);
            for (int c = 0; c < 3; c++) {
                tensor[c * nh * nw + y * nw + x] = (rgb[c] - mean[c]) / std[c];
            }
        }
    }
    return tensor;
}

// Preprocess image crop for recognition: resize to height=48, bilinear, normalize, NCHW
static float* preprocess_rec(const unsigned char* rgba, int w, int h,
                              int x1, int y1, int x2, int y2,
                              int* out_w, int* out_h) {
    int crop_w = x2 - x1;
    int crop_h = y2 - y1;
    if (crop_w <= 0 || crop_h <= 0) return NULL;
    
    // Target height is 48 for PP-OCRv4 rec
    int target_h = 48;
    float ratio = (float)target_h / crop_h;
    int target_w = (int)(crop_w * ratio);
    if (target_w < 1) target_w = 1;
    if (target_w > 960) target_w = 960;  // Higher max width for long text
    // Round to multiple of 8
    target_w = ((target_w + 7) / 8) * 8;
    if (target_w < 8) target_w = 8;
    
    *out_w = target_w;
    *out_h = target_h;
    
    float* tensor = (float*)calloc(3 * target_h * target_w, sizeof(float));
    if (!tensor) return NULL;
    
    float mean[3] = {0.5f, 0.5f, 0.5f};
    float std[3] = {0.5f, 0.5f, 0.5f};
    
    for (int y = 0; y < target_h; y++) {
        for (int x = 0; x < target_w; x++) {
            // Bilinear interpolation in source crop region
            float fx = x1 + x / ratio;
            float fy = y1 + y / ratio;
            float rgb[3];
            bilinear_sample(rgba, w, h, fx, fy, rgb);
            for (int c = 0; c < 3; c++) {
                tensor[c * target_h * target_w + y * target_w + x] = (rgb[c] - mean[c]) / std[c];
            }
        }
    }
    return tensor;
}

// Row-scan post-processing: find text line strips in detection heatmap
typedef struct { int x1, y1, x2, y2; } TextBox;

// ══════════════════════════════════════════════════════════
//  RCNN Bubble Detector — replaces heuristic when model is loaded
// ══════════════════════════════════════════════════════════

// Run the bubble detector on RGBA image, returns bubble boxes in image coordinates.
// Caller must free returned array.
static TextBox* run_bubble_detector(const unsigned char* rgba, int img_w, int img_h,
                                     int* out_count) {
    *out_count = 0;
    if (!g_bubble_session || !g_ort) return NULL;
    
    // Preprocess: resize to 320x320, normalize with ImageNet stats, NCHW
    int target = 320;
    float* tensor = (float*)calloc(3 * target * target, sizeof(float));
    if (!tensor) return NULL;
    
    float mean[3] = {0.485f, 0.456f, 0.406f};
    float std[3] = {0.229f, 0.224f, 0.225f};
    float sx = (float)img_w / target;
    float sy = (float)img_h / target;
    
    for (int y = 0; y < target; y++) {
        for (int x = 0; x < target; x++) {
            int ox = (int)(x * sx); if (ox >= img_w) ox = img_w - 1;
            int oy = (int)(y * sy); if (oy >= img_h) oy = img_h - 1;
            int idx = (oy * img_w + ox) * 4;
            for (int c = 0; c < 3; c++) {
                float val = rgba[idx + c] / 255.0f;
                tensor[c * target * target + y * target + x] = (val - mean[c]) / std[c];
            }
        }
    }
    
    OrtMemoryInfo* mem_info = NULL;
    g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem_info);
    
    int64_t shape[] = {1, 3, target, target};
    OrtValue* input_val = NULL;
    g_ort->CreateTensorWithDataAsOrtValue(
        mem_info, tensor, 3 * target * target * sizeof(float),
        shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input_val);
    
    const char* input_names[] = {"image"};
    const char* output_names[] = {"confidence", "boxes"};
    OrtValue* outputs[2] = {NULL, NULL};
    
    OrtStatus* status = g_ort->Run(g_bubble_session, NULL,
        input_names, (const OrtValue* const*)&input_val, 1,
        output_names, 2, outputs);
    
    free(tensor);
    g_ort->ReleaseValue(input_val);
    g_ort->ReleaseMemoryInfo(mem_info);
    
    if (status != NULL) {
        g_ort->ReleaseStatus(status);
        return NULL;
    }
    
    // Parse outputs: confidence [1, 1, H, W], boxes [1, 4, H, W]
    float* conf_data = NULL;
    float* box_data = NULL;
    g_ort->GetTensorMutableData(outputs[0], (void**)&conf_data);
    g_ort->GetTensorMutableData(outputs[1], (void**)&box_data);
    
    OrtTensorTypeAndShapeInfo* conf_info = NULL;
    g_ort->GetTensorTypeAndShape(outputs[0], &conf_info);
    size_t conf_dims_count = 0;
    g_ort->GetDimensionsCount(conf_info, &conf_dims_count);
    int64_t conf_dims[4];
    g_ort->GetDimensions(conf_info, conf_dims, conf_dims_count);
    g_ort->ReleaseTensorTypeAndShapeInfo(conf_info);
    
    int grid_h = (int)conf_dims[2];
    int grid_w = (int)conf_dims[3];
    float stride = (float)target / grid_h;
    
    TextBox* bubbles = (TextBox*)malloc(sizeof(TextBox) * 64);
    int count = 0;
    float conf_thresh = 0.3f;
    
    for (int gy = 0; gy < grid_h && count < 60; gy++) {
        for (int gx = 0; gx < grid_w && count < 60; gx++) {
            float conf = conf_data[gy * grid_w + gx];
            if (conf < conf_thresh) continue;
            
            // Decode box: sigmoid offsets + exp sizes
            float cx_off = box_data[0 * grid_h * grid_w + gy * grid_w + gx];
            float cy_off = box_data[1 * grid_h * grid_w + gy * grid_w + gx];
            float w_raw  = box_data[2 * grid_h * grid_w + gy * grid_w + gx];
            float h_raw  = box_data[3 * grid_h * grid_w + gy * grid_w + gx];
            
            // sigmoid for offsets
            float cx_s = 1.0f / (1.0f + expf(-cx_off));
            float cy_s = 1.0f / (1.0f + expf(-cy_off));
            
            float cx = (gx + cx_s) * stride;
            float cy = (gy + cy_s) * stride;
            float bw = expf(w_raw < -5 ? -5 : (w_raw > 5 ? 5 : w_raw)) * stride * 2;
            float bh = expf(h_raw < -5 ? -5 : (h_raw > 5 ? 5 : h_raw)) * stride * 2;
            
            // Scale from 320x320 back to original image
            int x1 = (int)((cx - bw/2) * sx);
            int y1 = (int)((cy - bh/2) * sy);
            int x2 = (int)((cx + bw/2) * sx);
            int y2 = (int)((cy + bh/2) * sy);
            if (x1 < 0) x1 = 0;
            if (y1 < 0) y1 = 0;
            if (x2 > img_w) x2 = img_w;
            if (y2 > img_h) y2 = img_h;
            
            if ((x2 - x1) > 20 && (y2 - y1) > 10) {
                bubbles[count].x1 = x1;
                bubbles[count].y1 = y1;
                bubbles[count].x2 = x2;
                bubbles[count].y2 = y2;
                count++;
            }
        }
    }
    
    g_ort->ReleaseValue(outputs[0]);
    g_ort->ReleaseValue(outputs[1]);
    
    *out_count = count;
    return bubbles;
}

// Check if a text box overlaps sufficiently with any detected bubble
static int text_in_any_bubble(const TextBox* text, const TextBox* bubbles, int bubble_count) {
    for (int i = 0; i < bubble_count; i++) {
        // Compute intersection
        int ix1 = text->x1 > bubbles[i].x1 ? text->x1 : bubbles[i].x1;
        int iy1 = text->y1 > bubbles[i].y1 ? text->y1 : bubbles[i].y1;
        int ix2 = text->x2 < bubbles[i].x2 ? text->x2 : bubbles[i].x2;
        int iy2 = text->y2 < bubbles[i].y2 ? text->y2 : bubbles[i].y2;
        
        if (ix2 <= ix1 || iy2 <= iy1) continue;
        
        int inter_area = (ix2 - ix1) * (iy2 - iy1);
        int text_area = (text->x2 - text->x1) * (text->y2 - text->y1);
        if (text_area <= 0) continue;
        
        // If >40% of text box is inside a bubble, it's dialogue
        float ratio = (float)inter_area / text_area;
        if (ratio > 0.4f) return 1;
    }
    return 0;
}

// Check if a text box sits inside a speech bubble (white/light background region).
// Samples pixels around and inside the box. Speech bubbles have:
//   - High brightness (white/cream background, avg > 180)
//   - Low color variance (uniform background, not busy art)
// This is a heuristic fallback — will be replaced by trained RCNN bubble detector.
static int is_in_speech_bubble(const unsigned char* rgba, int img_w, int img_h,
                                const TextBox* box) {
    // Expand sampling region slightly beyond the text box
    int margin = 8;
    int sx1 = box->x1 - margin; if (sx1 < 0) sx1 = 0;
    int sy1 = box->y1 - margin; if (sy1 < 0) sy1 = 0;
    int sx2 = box->x2 + margin; if (sx2 > img_w) sx2 = img_w;
    int sy2 = box->y2 + margin; if (sy2 > img_h) sy2 = img_h;
    
    int region_w = sx2 - sx1;
    int region_h = sy2 - sy1;
    if (region_w <= 0 || region_h <= 0) return 0;
    
    // Sample a grid of pixels in the region (skip text area, sample edges)
    long total_brightness = 0;
    long total_variance = 0;
    int sample_count = 0;
    int step = 4; // Sample every 4th pixel for speed
    
    for (int y = sy1; y < sy2; y += step) {
        for (int x = sx1; x < sx2; x += step) {
            // Prefer sampling the margin area (outside text, inside bubble)
            int in_text = (x >= box->x1 && x < box->x2 && y >= box->y1 && y < box->y2);
            if (in_text && sample_count > 8) continue; // Already have enough edge samples
            
            int idx = (y * img_w + x) * 4;
            int r = rgba[idx];
            int g = rgba[idx + 1];
            int b = rgba[idx + 2];
            
            int brightness = (r + g + b) / 3;
            total_brightness += brightness;
            
            // Color variance: how different are R,G,B from each other?
            // Low variance = grayscale/white, High = colorful art
            int dr = r - brightness;
            int dg = g - brightness;
            int db = b - brightness;
            total_variance += (dr*dr + dg*dg + db*db);
            
            sample_count++;
        }
    }
    
    if (sample_count == 0) return 0;
    
    int avg_brightness = (int)(total_brightness / sample_count);
    int avg_variance = (int)(total_variance / sample_count);
    
    // Speech bubble: bright background (> 180) and low color variance (< 800)
    // This catches white, cream, and light gray bubbles
    return (avg_brightness > 180 && avg_variance < 800);
}

// Merge nearby text boxes on same line (small gaps in text shouldn't split boxes)
static int merge_text_boxes(TextBox* boxes, int count) {
    if (count <= 1) return count;
    
    // Sort by y1 then x1 (simple bubble sort — count is small)
    for (int i = 0; i < count - 1; i++) {
        for (int j = i + 1; j < count; j++) {
            if (boxes[j].y1 < boxes[i].y1 || 
                (boxes[j].y1 == boxes[i].y1 && boxes[j].x1 < boxes[i].x1)) {
                TextBox tmp = boxes[i];
                boxes[i] = boxes[j];
                boxes[j] = tmp;
            }
        }
    }
    
    // Merge horizontally adjacent boxes on same line
    int merged = count;
    for (int i = 0; i < merged - 1; i++) {
        for (int j = i + 1; j < merged; j++) {
            // Check vertical overlap (same line)
            int overlap_top = boxes[i].y1 > boxes[j].y1 ? boxes[i].y1 : boxes[j].y1;
            int overlap_bot = boxes[i].y2 < boxes[j].y2 ? boxes[i].y2 : boxes[j].y2;
            int h_i = boxes[i].y2 - boxes[i].y1;
            int h_j = boxes[j].y2 - boxes[j].y1;
            int min_h = h_i < h_j ? h_i : h_j;
            
            if (min_h <= 0) continue;
            int v_overlap = overlap_bot - overlap_top;
            if (v_overlap < min_h * 0.5f) continue;  // Not same line
            
            // Check horizontal gap
            int gap = boxes[j].x1 - boxes[i].x2;
            int avg_h = (h_i + h_j) / 2;
            if (gap > avg_h * 2) continue;  // Too far apart
            
            // Merge j into i
            if (boxes[j].x1 < boxes[i].x1) boxes[i].x1 = boxes[j].x1;
            if (boxes[j].y1 < boxes[i].y1) boxes[i].y1 = boxes[j].y1;
            if (boxes[j].x2 > boxes[i].x2) boxes[i].x2 = boxes[j].x2;
            if (boxes[j].y2 > boxes[i].y2) boxes[i].y2 = boxes[j].y2;
            
            // Remove j by shifting
            for (int k = j; k < merged - 1; k++) boxes[k] = boxes[k+1];
            merged--;
            j--;  // Recheck this index
        }
    }
    return merged;
}

static TextBox* find_text_boxes(const float* heatmap, int map_w, int map_h,
                                 float scale_x, float scale_y,
                                 int* out_count) {
    float threshold = 0.2f;  // Lower threshold for better recall
    TextBox* boxes = (TextBox*)malloc(sizeof(TextBox) * 256);
    int count = 0;
    int pad = 10;  // More padding for better recognition context
    
    // Connected component scan with small gap tolerance
    // Row scan: find contiguous row groups that have any above-threshold pixel
    int in_region = 0;
    int y_start = 0;
    int blank_rows = 0;  // Tolerate small gaps in text
    
    for (int y = 0; y <= map_h && count < 240; y++) {
        // Check if this row has any text
        int row_has_text = 0;
        if (y < map_h) {
            for (int x = 0; x < map_w; x++) {
                if (heatmap[y * map_w + x] >= threshold) {
                    row_has_text = 1;
                    break;
                }
            }
        }
        
        if (row_has_text && !in_region) {
            y_start = y;
            in_region = 1;
            blank_rows = 0;
        } else if (row_has_text && in_region) {
            blank_rows = 0;  // Reset gap counter
        } else if (!row_has_text && in_region) {
            blank_rows++;
            // Tolerate up to 2 blank rows (small gaps in text)
            if (blank_rows <= 2 && y < map_h) continue;
            
            // End of row group — find x column spans
            int y_end = y - blank_rows;  // Exclude trailing blanks
            // Build column mask: any pixel in [y_start, y_end) above threshold?
            int x_start = -1;
            int blank_cols = 0;
            for (int x = 0; x <= map_w; x++) {
                int col_active = 0;
                if (x < map_w) {
                    for (int dy = y_start; dy < y_end; dy++) {
                        if (heatmap[dy * map_w + x] >= threshold) {
                            col_active = 1;
                            break;
                        }
                    }
                }
                
                if (col_active && x_start < 0) {
                    x_start = x;
                    blank_cols = 0;
                } else if (col_active && x_start >= 0) {
                    blank_cols = 0;
                } else if (!col_active && x_start >= 0) {
                    blank_cols++;
                    // Tolerate small column gaps (within-word spacing)
                    if (blank_cols <= 2 && x < map_w) continue;
                    
                    int x_end = x - blank_cols;
                    int bx1 = (int)(x_start * scale_x) - pad;
                    int by1 = (int)(y_start * scale_y) - pad;
                    int bx2 = (int)(x_end * scale_x) + pad;
                    int by2 = (int)(y_end * scale_y) + pad;
                    if (bx1 < 0) bx1 = 0;
                    if (by1 < 0) by1 = 0;
                    
                    if ((bx2 - bx1) > 8 && (by2 - by1) > 4 && count < 256) {
                        boxes[count].x1 = bx1;
                        boxes[count].y1 = by1;
                        boxes[count].x2 = bx2;
                        boxes[count].y2 = by2;
                        count++;
                    }
                    x_start = -1;
                    blank_cols = 0;
                }
            }
            in_region = 0;
            blank_rows = 0;
        }
    }
    
    // Merge nearby boxes on same line
    count = merge_text_boxes(boxes, count);
    
    *out_count = count;
    return boxes;
}

// Decode CTC output to text
static char* decode_ctc(const float* output, int seq_len, int class_count) {
    char* result = (char*)malloc(seq_len * 8); // UTF-8 max
    int pos = 0;
    int prev_idx = 0;
    
    for (int t = 0; t < seq_len; t++) {
        // Find argmax for this timestep
        int best_idx = 0;
        float best_val = output[t * class_count];
        for (int c = 1; c < class_count; c++) {
            float val = output[t * class_count + c];
            if (val > best_val) {
                best_val = val;
                best_idx = c;
            }
        }
        
        // CTC: skip blanks and repeats
        if (best_idx != 0 && best_idx != prev_idx) {
            if (best_idx < g_dict_size && g_dict[best_idx]) {
                int len = strlen(g_dict[best_idx]);
                memcpy(result + pos, g_dict[best_idx], len);
                pos += len;
            }
        }
        prev_idx = best_idx;
    }
    result[pos] = '\0';
    return result;
}

static char* run_ocr_on_rgba(const unsigned char* rgba, int img_w, int img_h) {
    if (!g_ort || !g_det_session || !g_rec_session) return NULL;
    
    OrtMemoryInfo* memory_info = NULL;
    ORT_CHECK_NULL(g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory_info));
    
    // === Step 1: Detection ===
    int det_w, det_h;
    float* det_tensor = preprocess_det(rgba, img_w, img_h, &det_w, &det_h);
    if (!det_tensor) { g_ort->ReleaseMemoryInfo(memory_info); return NULL; }
    
    int64_t det_shape[] = {1, 3, det_h, det_w};
    OrtValue* det_input_val = NULL;
    ORT_CHECK_NULL(g_ort->CreateTensorWithDataAsOrtValue(
        memory_info, det_tensor, 3 * det_h * det_w * sizeof(float),
        det_shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &det_input_val));
    
    const char* det_input_names[] = {"x"};
    const char* det_output_names[] = {g_det_output_name};
    OrtValue* det_output_val = NULL;
    
    OrtStatus* det_status = g_ort->Run(g_det_session, NULL,
        det_input_names, (const OrtValue* const*)&det_input_val, 1,
        det_output_names, 1, &det_output_val);
    
    free(det_tensor);
    g_ort->ReleaseValue(det_input_val);
    
    if (det_status != NULL) {
        // If named outputs don't match, try default
        g_ort->ReleaseStatus(det_status);
        fprintf(stderr, "[OCR-ORT] Det output name mismatch, falling back to full-page rec\n");
        
        // Fallback: just run recognition on the entire image
        int rec_w, rec_h;
        float* rec_tensor = preprocess_rec(rgba, img_w, img_h, 0, 0, img_w, img_h, &rec_w, &rec_h);
        if (!rec_tensor) { g_ort->ReleaseMemoryInfo(memory_info); return NULL; }
        
        int64_t rec_shape[] = {1, 3, rec_h, rec_w};
        OrtValue* rec_input_val = NULL;
        g_ort->CreateTensorWithDataAsOrtValue(
            memory_info, rec_tensor, 3 * rec_h * rec_w * sizeof(float),
            rec_shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &rec_input_val);
        
        const char* rec_input_names[] = {"x"};
        const char* rec_output_names[] = {g_rec_output_name};
        OrtValue* rec_output_val = NULL;
        g_ort->Run(g_rec_session, NULL,
            rec_input_names, (const OrtValue* const*)&rec_input_val, 1,
            rec_output_names, 1, &rec_output_val);
        
        char* result = NULL;
        if (rec_output_val) {
            float* rec_data = NULL;
            g_ort->GetTensorMutableData(rec_output_val, (void**)&rec_data);
            
            OrtTensorTypeAndShapeInfo* shape_info = NULL;
            g_ort->GetTensorTypeAndShape(rec_output_val, &shape_info);
            size_t dim_count = 0;
            g_ort->GetDimensionsCount(shape_info, &dim_count);
            int64_t dims[4];
            g_ort->GetDimensions(shape_info, dims, dim_count);
            g_ort->ReleaseTensorTypeAndShapeInfo(shape_info);
            
            if (dim_count >= 2 && rec_data) {
                int seq_len = (int)dims[1];
                int classes = dim_count >= 3 ? (int)dims[2] : g_dict_size;
                result = decode_ctc(rec_data, seq_len, classes);
            }
            g_ort->ReleaseValue(rec_output_val);
        }
        
        free(rec_tensor);
        g_ort->ReleaseValue(rec_input_val);
        g_ort->ReleaseMemoryInfo(memory_info);
        return result;
    }
    
    // Get detection heatmap
    float* heatmap = NULL;
    g_ort->GetTensorMutableData(det_output_val, (void**)&heatmap);
    
    OrtTensorTypeAndShapeInfo* det_shape_info = NULL;
    g_ort->GetTensorTypeAndShape(det_output_val, &det_shape_info);
    size_t det_dim_count = 0;
    g_ort->GetDimensionsCount(det_shape_info, &det_dim_count);
    int64_t det_dims[4];
    g_ort->GetDimensions(det_shape_info, det_dims, det_dim_count);
    g_ort->ReleaseTensorTypeAndShapeInfo(det_shape_info);
    
    int map_h = (int)det_dims[2];
    int map_w = (int)det_dims[3];
    float scale_x = (float)img_w / map_w;
    float scale_y = (float)img_h / map_h;
    
    // Find text boxes
    int box_count = 0;
    TextBox* boxes = find_text_boxes(heatmap, map_w, map_h, scale_x, scale_y, &box_count);
    g_ort->ReleaseValue(det_output_val);
    
    if (box_count == 0) {
        free(boxes);
        g_ort->ReleaseMemoryInfo(memory_info);
        return strdup("");
    }
    
    // === Step 2: Detect speech bubbles ===
    int bubble_count = 0;
    TextBox* bubbles = NULL;
    if (g_bubble_session) {
        bubbles = run_bubble_detector(rgba, img_w, img_h, &bubble_count);
        fprintf(stderr, "[OCR-ORT] Detected %d speech bubbles via RCNN\n", bubble_count);
    }
    
    // === Step 3: Recognition for each text box inside bubbles ===
    char* full_text = (char*)malloc(4096 * 4);
    int text_pos = 0;
    
    for (int b = 0; b < box_count && text_pos < 16000; b++) {
        // Filter: only OCR text inside speech bubbles
        if (bubbles && bubble_count > 0) {
            // RCNN-based: check overlap with detected bubbles
            if (!text_in_any_bubble(&boxes[b], bubbles, bubble_count)) {
                continue;
            }
        } else {
            // Heuristic fallback: brightness/variance check
            if (!is_in_speech_bubble(rgba, img_w, img_h, &boxes[b])) {
                continue;
            }
        }
        
        int rec_w, rec_h;
        float* rec_tensor = preprocess_rec(rgba, img_w, img_h,
                                            boxes[b].x1, boxes[b].y1,
                                            boxes[b].x2, boxes[b].y2,
                                            &rec_w, &rec_h);
        if (!rec_tensor) continue;
        
        int64_t rec_shape[] = {1, 3, rec_h, rec_w};
        OrtValue* rec_input_val = NULL;
        g_ort->CreateTensorWithDataAsOrtValue(
            memory_info, rec_tensor, 3 * rec_h * rec_w * sizeof(float),
            rec_shape, 4, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &rec_input_val);
        
        const char* rec_input_names[] = {"x"};
        const char* rec_output_names[] = {g_rec_output_name};
        OrtValue* rec_output_val = NULL;
        g_ort->Run(g_rec_session, NULL,
            rec_input_names, (const OrtValue* const*)&rec_input_val, 1,
            rec_output_names, 1, &rec_output_val);
        
        if (rec_output_val) {
            float* rec_data = NULL;
            g_ort->GetTensorMutableData(rec_output_val, (void**)&rec_data);
            
            OrtTensorTypeAndShapeInfo* shape_info = NULL;
            g_ort->GetTensorTypeAndShape(rec_output_val, &shape_info);
            size_t dim_count = 0;
            g_ort->GetDimensionsCount(shape_info, &dim_count);
            int64_t dims[4];
            g_ort->GetDimensions(shape_info, dims, dim_count);
            g_ort->ReleaseTensorTypeAndShapeInfo(shape_info);
            
            if (dim_count >= 2 && rec_data) {
                int seq_len = (int)dims[1];
                int classes = dim_count >= 3 ? (int)dims[2] : g_dict_size;
                char* line = decode_ctc(rec_data, seq_len, classes);
                if (line && strlen(line) > 0) {
                    int line_len = strlen(line);
                    memcpy(full_text + text_pos, line, line_len);
                    text_pos += line_len;
                    full_text[text_pos++] = '\n';
                }
                free(line);
            }
            g_ort->ReleaseValue(rec_output_val);
        }
        
        free(rec_tensor);
        g_ort->ReleaseValue(rec_input_val);
    }
    
    full_text[text_pos] = '\0';
    free(boxes);
    if (bubbles) free(bubbles);
    g_ort->ReleaseMemoryInfo(memory_info);
    return full_text;
}

// Accept pre-decoded RGBA pixels directly
char* ocr_recognize_rgba(const uint8_t* rgba, int w, int h) {
    if (!rgba || w <= 0 || h <= 0) return NULL;
    return run_ocr_on_rgba(rgba, w, h);
}

char* ocr_recognize_bytes(const uint8_t* data, size_t data_len) {
    // Not used — Zig side handles decoding
    (void)data; (void)data_len;
    return NULL;
}

char* ocr_recognize_file(const char* image_path) {
    FILE* f = fopen(image_path, "rb");
    if (!f) return NULL;
    
    fseek(f, 0, SEEK_END);
    size_t len = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    uint8_t* data = (uint8_t*)malloc(len);
    fread(data, 1, len, f);
    fclose(f);
    
    char* result = ocr_recognize_bytes(data, len);
    free(data);
    return result;
}

void ocr_free_text(char* text) {
    free(text);
}

void ocr_cleanup(void) {
    if (g_bubble_session) { g_ort->ReleaseSession(g_bubble_session); g_bubble_session = NULL; }
    if (g_rec_session) { g_ort->ReleaseSession(g_rec_session); g_rec_session = NULL; }
    if (g_det_session) { g_ort->ReleaseSession(g_det_session); g_det_session = NULL; }
    if (g_session_opts) { g_ort->ReleaseSessionOptions(g_session_opts); g_session_opts = NULL; }
    if (g_env) { g_ort->ReleaseEnv(g_env); g_env = NULL; }
    
    if (g_dict) {
        for (int i = 0; i < g_dict_size; i++) free(g_dict[i]);
        free(g_dict);
        g_dict = NULL;
        g_dict_size = 0;
    }
}
