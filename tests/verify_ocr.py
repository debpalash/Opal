import onnxruntime as ort
import numpy as np
from PIL import Image

# Load models
det = ort.InferenceSession('models/ppocr_det.onnx')
rec = ort.InferenceSession('models/ppocr_rec.onnx')

# Load dict
with open('models/en_dict.txt', 'r') as f:
    chars = [' '] + [line.strip() for line in f] + [' ']
print(f"Dict: {len(chars)} chars, first 10: {chars[:10]}")

# Load test image
img = Image.open('/tmp/comic_test/page1.png').convert('RGB')
w, h = img.size
print(f"Image: {w}x{h}")

# Preprocess for detection
max_dim = max(w, h)
scale = 960.0 / max_dim if max_dim > 960 else 1.0
nw = int(w * scale) // 32 * 32
nh = int(h * scale) // 32 * 32
resized = img.resize((nw, nh))
arr = np.array(resized).astype(np.float32) / 255.0
mean = np.array([0.485, 0.456, 0.406])
std = np.array([0.229, 0.224, 0.225])
arr = (arr - mean) / std
arr = arr.transpose(2, 0, 1)[np.newaxis, ...]  # NCHW
print(f"Det input shape: {arr.shape}")

# Run detection
det_out = det.run(None, {'x': arr.astype(np.float32)})
heatmap = det_out[0]
print(f"Det output shape: {heatmap.shape}, min={heatmap.min():.3f}, max={heatmap.max():.3f}")

# Find boxes from heatmap - simple approach without scipy
mask = heatmap[0, 0] > 0.3
# Find rows and cols with text
rows = np.any(mask, axis=1)
cols = np.any(mask, axis=0)

# Find contiguous row-groups
boxes = []
in_region = False
y_start = 0
for y in range(len(rows)):
    if rows[y] and not in_region:
        y_start = y
        in_region = True
    elif not rows[y] and in_region:
        # Find x bounds for this row range
        region_mask = mask[y_start:y, :]
        x_cols = np.any(region_mask, axis=0)
        x_starts = np.where(np.diff(np.concatenate(([0], x_cols.astype(int)))) == 1)[0]
        x_ends = np.where(np.diff(np.concatenate((x_cols.astype(int), [0]))) == -1)[0]
        for xs, xe in zip(x_starts, x_ends):
            x1 = int(xs * w / nw)
            y1 = int(y_start * h / nh)
            x2 = int(xe * w / nw)
            y2 = int(y * h / nh)
            pad = 5
            x1 = max(0, x1 - pad)
            y1 = max(0, y1 - pad)
            x2 = min(w, x2 + pad)
            y2 = min(h, y2 + pad)
            if (x2 - x1) > 10 and (y2 - y1) > 5:
                boxes.append((x1, y1, x2, y2))
        in_region = False

print(f"Found {len(boxes)} text regions")
for i, b in enumerate(boxes):
    print(f"  Box {i}: ({b[0]},{b[1]})-({b[2]},{b[3]}) size {b[2]-b[0]}x{b[3]-b[1]}")

# Sort boxes top-to-bottom
boxes.sort(key=lambda b: b[1])

# Recognize each box
for bx in boxes:
    x1, y1, x2, y2 = bx
    crop = img.crop((x1, y1, x2, y2))
    cw, ch = crop.size
    target_h = 48
    ratio = target_h / ch
    target_w = max(int(cw * ratio), 1)
    crop = crop.resize((target_w, target_h))
    
    arr = np.array(crop).astype(np.float32) / 255.0
    arr = (arr - 0.5) / 0.5
    arr = arr.transpose(2, 0, 1)[np.newaxis, ...]
    
    rec_out = rec.run(None, {'x': arr.astype(np.float32)})
    probs = rec_out[0][0]  # [seq_len, num_classes]
    
    # CTC decode
    indices = probs.argmax(axis=1)
    text = ''
    prev = 0
    for idx in indices:
        if idx != 0 and idx != prev and idx < len(chars):
            text += chars[idx]
        prev = idx
    
    if text.strip():
        print(f"  [{x1},{y1}-{x2},{y2}] -> '{text}'")
