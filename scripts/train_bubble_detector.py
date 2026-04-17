#!/usr/bin/env python3
"""
Train a tiny (~200K params) speech bubble detector for ZigZag comic reader.

Architecture: Lightweight Faster R-CNN with custom tiny backbone
- Input: 320x320 RGB
- Output: Bounding boxes + confidence for speech bubbles
- Target: ~200K params, <1MB ONNX, <5ms inference on CPU

Dataset: Comic speech bubble annotations (Roboflow / COMICS Text+)

Usage:
    # 1. Download dataset
    python train_bubble_detector.py --download

    # 2. Train
    python train_bubble_detector.py --train --epochs 50

    # 3. Export to ONNX
    python train_bubble_detector.py --export

    # 4. Test on a comic page
    python train_bubble_detector.py --test image.jpg
"""

import argparse
import os
import sys
import json

import torch
import torch.nn as nn
import torch.nn.functional as F
import torchvision
from torchvision import transforms
from torch.utils.data import Dataset, DataLoader
from PIL import Image
import numpy as np

MODELS_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "models")
DATASET_DIR = os.path.join(os.path.dirname(__file__), "bubble_dataset")
MODEL_PATH = os.path.join(MODELS_DIR, "bubble_det.onnx")


# ══════════════════════════════════════════════════════════
#  Tiny Backbone (~150K params)
# ══════════════════════════════════════════════════════════

class TinyConvBlock(nn.Module):
    """Depthwise separable convolution block for parameter efficiency."""
    def __init__(self, in_ch, out_ch, stride=1):
        super().__init__()
        self.dw = nn.Conv2d(in_ch, in_ch, 3, stride, 1, groups=in_ch, bias=False)
        self.bn1 = nn.BatchNorm2d(in_ch)
        self.pw = nn.Conv2d(in_ch, out_ch, 1, bias=False)
        self.bn2 = nn.BatchNorm2d(out_ch)

    def forward(self, x):
        x = F.relu6(self.bn1(self.dw(x)))
        x = F.relu6(self.bn2(self.pw(x)))
        return x


class TinyBackbone(nn.Module):
    """
    Tiny backbone for bubble detection. ~160K params.
    320x320 → 20x20 feature map (stride 16)
    """
    def __init__(self):
        super().__init__()
        self.stem = nn.Sequential(
            nn.Conv2d(3, 32, 3, 2, 1, bias=False),  # 160x160
            nn.BatchNorm2d(32),
            nn.ReLU6(inplace=True),
        )
        self.stage1 = nn.Sequential(
            TinyConvBlock(32, 64, stride=2),   # 80x80
            TinyConvBlock(64, 64),
            TinyConvBlock(64, 64),
        )
        self.stage2 = nn.Sequential(
            TinyConvBlock(64, 128, stride=2),  # 40x40
            TinyConvBlock(128, 128),
            TinyConvBlock(128, 128),
        )
        self.stage3 = nn.Sequential(
            TinyConvBlock(128, 256, stride=2), # 20x20
            TinyConvBlock(256, 256),
        )
        self.out_channels = 256

    def forward(self, x):
        x = self.stem(x)
        x = self.stage1(x)
        x = self.stage2(x)
        x = self.stage3(x)
        return x


# ══════════════════════════════════════════════════════════
#  Detection Head (~50K params)
# ══════════════════════════════════════════════════════════

class BubbleDetector(nn.Module):
    """
    Single-class anchor-free detector.
    For each cell in 40x40 grid, predicts:
    - 1 confidence score (bubble or not)
    - 4 bbox offsets (cx, cy, w, h relative to cell)

    Total: ~200K params
    """
    def __init__(self):
        super().__init__()
        self.backbone = TinyBackbone()

        # Detection head — depthwise separable + standard 1x1 for predictions
        self.head = nn.Sequential(
            TinyConvBlock(256, 256),
            nn.Conv2d(256, 96, 1, bias=False),
            nn.BatchNorm2d(96),
            nn.ReLU6(inplace=True),
        )
        self.cls = nn.Conv2d(96, 1, 1)   # Confidence
        self.reg = nn.Conv2d(96, 4, 1)   # Bbox: cx_off, cy_off, w, h

    def forward(self, x):
        feat = self.backbone(x)
        h = self.head(feat)
        cls_out = torch.sigmoid(self.cls(h))  # [B, 1, H, W]
        reg_out = self.reg(h)                  # [B, 4, H, W]
        return cls_out, reg_out

    def decode_boxes(self, cls_out, reg_out, conf_thresh=0.5, img_size=320):
        """Decode grid predictions to actual bounding boxes."""
        B, _, H, W = cls_out.shape
        stride = img_size / H  # 8

        # Create grid
        yy, xx = torch.meshgrid(torch.arange(H), torch.arange(W), indexing='ij')
        xx = xx.float().to(cls_out.device)
        yy = yy.float().to(cls_out.device)

        # Decode: center = (grid_cell + offset) * stride
        cx = (xx + torch.sigmoid(reg_out[:, 0])) * stride
        cy = (yy + torch.sigmoid(reg_out[:, 1])) * stride
        w = torch.exp(reg_out[:, 2].clamp(-5, 5)) * stride * 2
        h = torch.exp(reg_out[:, 3].clamp(-5, 5)) * stride * 2

        # Convert to x1y1x2y2
        x1 = cx - w / 2
        y1 = cy - h / 2
        x2 = cx + w / 2
        y2 = cy + h / 2

        boxes = torch.stack([x1, y1, x2, y2], dim=-1)  # [B, H, W, 4]
        scores = cls_out[:, 0]  # [B, H, W]

        results = []
        for b in range(B):
            mask = scores[b] > conf_thresh
            b_boxes = boxes[b][mask]  # [N, 4]
            b_scores = scores[b][mask]  # [N]

            if len(b_boxes) > 0:
                # NMS
                keep = torchvision.ops.nms(b_boxes, b_scores, iou_threshold=0.4)
                results.append((b_boxes[keep], b_scores[keep]))
            else:
                results.append((torch.zeros(0, 4), torch.zeros(0)))

        return results


# ══════════════════════════════════════════════════════════
#  Dataset
# ══════════════════════════════════════════════════════════

class BubbleDataset(Dataset):
    """
    Loads comic pages with speech bubble bounding box annotations.
    Supports YOLO format (class cx cy w h, normalized) or COCO JSON.
    """
    def __init__(self, img_dir, label_dir, img_size=320, augment=True):
        self.img_size = img_size
        self.augment = augment
        self.samples = []

        if not os.path.exists(img_dir):
            print(f"[WARN] Dataset not found at {img_dir}")
            return

        for fname in sorted(os.listdir(img_dir)):
            if not fname.lower().endswith(('.jpg', '.jpeg', '.png')):
                continue
            img_path = os.path.join(img_dir, fname)
            label_path = os.path.join(label_dir, os.path.splitext(fname)[0] + '.txt')
            self.samples.append((img_path, label_path))

        print(f"[BubbleDataset] Loaded {len(self.samples)} samples from {img_dir}")

    def __len__(self):
        return max(len(self.samples), 1)

    def __getitem__(self, idx):
        if len(self.samples) == 0:
            # Return dummy data
            img = torch.randn(3, self.img_size, self.img_size)
            return img, torch.zeros(0, 4), torch.zeros(0)

        img_path, label_path = self.samples[idx % len(self.samples)]

        # Load image
        img = Image.open(img_path).convert('RGB')
        orig_w, orig_h = img.size
        img = img.resize((self.img_size, self.img_size), Image.BILINEAR)

        # Augmentation
        if self.augment:
            if torch.rand(1) > 0.5:
                img = img.transpose(Image.FLIP_LEFT_RIGHT)

        img_tensor = transforms.ToTensor()(img)
        img_tensor = transforms.Normalize([0.485, 0.456, 0.406],
                                           [0.229, 0.224, 0.225])(img_tensor)

        # Load labels (YOLO format: class cx cy w h, all normalized 0-1)
        boxes = []
        if os.path.exists(label_path):
            with open(label_path) as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) >= 5:
                        # class_id, cx, cy, w, h (normalized)
                        cx = float(parts[1]) * self.img_size
                        cy = float(parts[2]) * self.img_size
                        bw = float(parts[3]) * self.img_size
                        bh = float(parts[4]) * self.img_size
                        x1 = cx - bw / 2
                        y1 = cy - bh / 2
                        x2 = cx + bw / 2
                        y2 = cy + bh / 2
                        boxes.append([x1, y1, x2, y2])

        if len(boxes) > 0:
            boxes_tensor = torch.tensor(boxes, dtype=torch.float32)
            labels = torch.ones(len(boxes), dtype=torch.float32)
        else:
            boxes_tensor = torch.zeros(0, 4)
            labels = torch.zeros(0)

        return img_tensor, boxes_tensor, labels


def collate_fn(batch):
    imgs = torch.stack([b[0] for b in batch])
    boxes = [b[1] for b in batch]
    labels = [b[2] for b in batch]
    return imgs, boxes, labels


# ══════════════════════════════════════════════════════════
#  Training
# ══════════════════════════════════════════════════════════

def compute_targets(boxes_list, grid_h, grid_w, img_size, device):
    """Convert ground truth boxes to grid-based targets."""
    B = len(boxes_list)
    stride = img_size / grid_h

    cls_target = torch.zeros(B, grid_h, grid_w, device=device)
    reg_target = torch.zeros(B, 4, grid_h, grid_w, device=device)

    for b, boxes in enumerate(boxes_list):
        for box in boxes:
            x1, y1, x2, y2 = box
            cx = (x1 + x2) / 2
            cy = (y1 + y2) / 2
            bw = x2 - x1
            bh = y2 - y1

            # Which grid cell
            gx = int(cx / stride)
            gy = int(cy / stride)
            gx = max(0, min(gx, grid_w - 1))
            gy = max(0, min(gy, grid_h - 1))

            cls_target[b, gy, gx] = 1.0
            # Store offsets
            reg_target[b, 0, gy, gx] = cx / stride - gx  # cx offset
            reg_target[b, 1, gy, gx] = cy / stride - gy  # cy offset
            reg_target[b, 2, gy, gx] = torch.log(torch.tensor(bw / (stride * 2)).clamp(min=1e-6))
            reg_target[b, 3, gy, gx] = torch.log(torch.tensor(bh / (stride * 2)).clamp(min=1e-6))

    return cls_target, reg_target


def train(epochs=50, batch_size=8, lr=1e-3):
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"[Train] Device: {device}")

    model = BubbleDetector().to(device)

    # Count params
    total = sum(p.numel() for p in model.parameters())
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"[Train] Parameters: {total:,} total, {trainable:,} trainable")

    # Dataset
    train_imgs = os.path.join(DATASET_DIR, "train", "images")
    train_labels = os.path.join(DATASET_DIR, "train", "labels")
    dataset = BubbleDataset(train_imgs, train_labels)
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=True,
                        collate_fn=collate_fn, num_workers=2)

    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, epochs)

    best_loss = float('inf')

    for epoch in range(epochs):
        model.train()
        total_loss = 0
        n_batches = 0

        for imgs, boxes_list, _ in loader:
            imgs = imgs.to(device)

            cls_out, reg_out = model(imgs)
            _, _, H, W = cls_out.shape

            cls_target, reg_target = compute_targets(
                boxes_list, H, W, 320, device
            )

            # Focal loss for classification
            cls_pred = cls_out[:, 0]  # [B, H, W]
            alpha = 0.25
            gamma = 2.0
            bce = F.binary_cross_entropy(cls_pred, cls_target, reduction='none')
            pt = torch.where(cls_target == 1, cls_pred, 1 - cls_pred)
            focal = alpha * (1 - pt) ** gamma * bce
            cls_loss = focal.mean()

            # Regression loss (only for positive cells)
            pos_mask = cls_target > 0.5  # [B, H, W]
            if pos_mask.sum() > 0:
                # Expand mask to match [B, 4, H, W]
                pos_mask_4d = pos_mask.unsqueeze(1).expand_as(reg_out)
                reg_loss = F.smooth_l1_loss(
                    reg_out[pos_mask_4d],
                    reg_target[pos_mask_4d],
                    reduction='mean'
                )
            else:
                reg_loss = torch.tensor(0.0, device=device)

            loss = cls_loss + reg_loss

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

            total_loss += loss.item()
            n_batches += 1

        scheduler.step()
        avg_loss = total_loss / max(n_batches, 1)

        if (epoch + 1) % 5 == 0 or epoch == 0:
            print(f"  Epoch {epoch+1}/{epochs}  loss={avg_loss:.4f}")

        if avg_loss < best_loss:
            best_loss = avg_loss
            torch.save(model.state_dict(), os.path.join(MODELS_DIR, "bubble_det.pth"))

    print(f"\n[Train] Best loss: {best_loss:.4f}")
    print(f"[Train] Saved to {MODELS_DIR}/bubble_det.pth")
    return model


# ══════════════════════════════════════════════════════════
#  Export to ONNX
# ══════════════════════════════════════════════════════════

def export_onnx():
    model = BubbleDetector()
    state_path = os.path.join(MODELS_DIR, "bubble_det.pth")
    if os.path.exists(state_path):
        model.load_state_dict(torch.load(state_path, map_location='cpu'))
    model.eval()

    dummy = torch.randn(1, 3, 320, 320)
    torch.onnx.export(
        model, dummy, MODEL_PATH,
        input_names=['image'],
        output_names=['confidence', 'boxes'],
        opset_version=13,
        dynamic_axes={
            'image': {0: 'batch'},
            'confidence': {0: 'batch'},
            'boxes': {0: 'batch'},
        }
    )

    size_kb = os.path.getsize(MODEL_PATH) / 1024
    print(f"[Export] Saved to {MODEL_PATH} ({size_kb:.0f} KB)")


# ══════════════════════════════════════════════════════════
#  Dataset Download (Roboflow)
# ══════════════════════════════════════════════════════════

def download_dataset():
    """Download a comic speech bubble dataset or generate synthetic training data."""
    os.makedirs(os.path.join(DATASET_DIR, "train", "images"), exist_ok=True)
    os.makedirs(os.path.join(DATASET_DIR, "train", "labels"), exist_ok=True)

    print("[Download] Generating synthetic speech bubble training data...")
    print("           (For best results, use a real dataset from Roboflow)")

    from PIL import ImageDraw, ImageFont

    for i in range(200):
        # Create a comic-style page
        w, h = 800, 1200
        img = Image.new('RGB', (w, h), color=(240, 230, 220))
        draw = ImageDraw.Draw(img)

        # Draw some "comic art" rectangles as background
        for _ in range(np.random.randint(3, 8)):
            rx1 = np.random.randint(0, w - 100)
            ry1 = np.random.randint(0, h - 100)
            rx2 = rx1 + np.random.randint(50, 300)
            ry2 = ry1 + np.random.randint(50, 300)
            color = tuple(np.random.randint(50, 200, 3).tolist())
            draw.rectangle([rx1, ry1, rx2, ry2], fill=color)

        # Draw speech bubbles (1-4 per page)
        bubbles = []
        n_bubbles = np.random.randint(1, 5)
        for _ in range(n_bubbles):
            bw = np.random.randint(80, 250)
            bh = np.random.randint(40, 150)
            bx = np.random.randint(20, w - bw - 20)
            by = np.random.randint(20, h - bh - 20)

            # Draw elliptical bubble (white with black outline)
            draw.ellipse([bx, by, bx + bw, by + bh], fill='white', outline='black', width=2)

            # Add text inside
            try:
                font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 14)
            except:
                font = ImageFont.load_default()

            texts = [
                "Hello there!", "What happened?", "I can't believe it!",
                "We need to go NOW!", "This is the end.", "Are you okay?",
                "LISTEN TO ME!", "I understand.", "Let's do this!",
                "You're wrong.", "It was my fault.", "There's no time!",
            ]
            text = np.random.choice(texts)
            text_w = draw.textlength(text, font=font) if hasattr(draw, 'textlength') else len(text) * 8
            tx = bx + (bw - text_w) // 2
            ty = by + (bh - 20) // 2
            draw.text((tx, ty), text, fill='black', font=font)

            # Store YOLO format: class cx cy w h (normalized)
            cx = (bx + bw / 2) / w
            cy = (by + bh / 2) / h
            nw = bw / w
            nh = bh / h
            bubbles.append(f"0 {cx:.6f} {cy:.6f} {nw:.6f} {nh:.6f}")

        # Also draw some SFX text NOT in bubbles (negative examples)
        for _ in range(np.random.randint(0, 3)):
            sfx = np.random.choice(["BOOM!", "CRASH!", "WHAM!", "POW!", "THUD!"])
            sx = np.random.randint(50, w - 100)
            sy = np.random.randint(50, h - 50)
            try:
                sfx_font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 28)
            except:
                sfx_font = ImageFont.load_default()
            sfx_color = tuple(np.random.randint(150, 255, 3).tolist())
            draw.text((sx, sy), sfx, fill=sfx_color, font=sfx_font)

        # Save
        img_path = os.path.join(DATASET_DIR, "train", "images", f"page_{i:04d}.jpg")
        label_path = os.path.join(DATASET_DIR, "train", "labels", f"page_{i:04d}.txt")
        img.save(img_path, quality=90)
        with open(label_path, 'w') as f:
            f.write('\n'.join(bubbles))

    print(f"[Download] Generated {200} synthetic training pages")
    print(f"[Download] Dataset at: {DATASET_DIR}")


# ══════════════════════════════════════════════════════════
#  Test
# ══════════════════════════════════════════════════════════

def test_image(image_path):
    model = BubbleDetector()
    state_path = os.path.join(MODELS_DIR, "bubble_det.pth")
    if os.path.exists(state_path):
        model.load_state_dict(torch.load(state_path, map_location='cpu'))
    model.eval()

    img = Image.open(image_path).convert('RGB')
    orig_w, orig_h = img.size
    img_resized = img.resize((320, 320), Image.BILINEAR)

    tensor = transforms.ToTensor()(img_resized)
    tensor = transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225])(tensor)
    tensor = tensor.unsqueeze(0)

    with torch.no_grad():
        cls_out, reg_out = model(tensor)
        results = model.decode_boxes(cls_out, reg_out, conf_thresh=0.3)

    boxes, scores = results[0]
    print(f"\n[Test] Found {len(boxes)} speech bubbles in {image_path}")

    scale_x = orig_w / 320
    scale_y = orig_h / 320

    for i, (box, score) in enumerate(zip(boxes, scores)):
        x1 = int(box[0] * scale_x)
        y1 = int(box[1] * scale_y)
        x2 = int(box[2] * scale_x)
        y2 = int(box[3] * scale_y)
        print(f"  Bubble {i+1}: ({x1},{y1})-({x2},{y2}) conf={score:.2f}")

    # Draw and save
    from PIL import ImageDraw
    draw = ImageDraw.Draw(img)
    for box, score in zip(boxes, scores):
        x1 = int(box[0] * scale_x)
        y1 = int(box[1] * scale_y)
        x2 = int(box[2] * scale_x)
        y2 = int(box[3] * scale_y)
        draw.rectangle([x1, y1, x2, y2], outline='lime', width=3)
        draw.text((x1, y1 - 12), f"{score:.2f}", fill='lime')

    out_path = image_path.replace('.', '_bubbles.')
    img.save(out_path)
    print(f"  Saved annotated: {out_path}")


# ══════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Train tiny speech bubble detector')
    parser.add_argument('--download', action='store_true', help='Download/generate training data')
    parser.add_argument('--train', action='store_true', help='Train the model')
    parser.add_argument('--export', action='store_true', help='Export to ONNX')
    parser.add_argument('--test', type=str, help='Test on an image')
    parser.add_argument('--epochs', type=int, default=50)
    parser.add_argument('--batch-size', type=int, default=8)
    parser.add_argument('--lr', type=float, default=1e-3)
    parser.add_argument('--all', action='store_true', help='Download + Train + Export')
    args = parser.parse_args()

    if args.all or args.download:
        download_dataset()

    if args.all or args.train:
        train(epochs=args.epochs, batch_size=args.batch_size, lr=args.lr)

    if args.all or args.export:
        export_onnx()

    if args.test:
        test_image(args.test)

    if not any([args.download, args.train, args.export, args.test, args.all]):
        # Quick info
        model = BubbleDetector()
        total = sum(p.numel() for p in model.parameters())
        print(f"BubbleDetector: {total:,} parameters")
        print(f"\nUsage:")
        print(f"  python {sys.argv[0]} --all          # Full pipeline")
        print(f"  python {sys.argv[0]} --download     # Get dataset")
        print(f"  python {sys.argv[0]} --train        # Train model")
        print(f"  python {sys.argv[0]} --export       # Export ONNX")
        print(f"  python {sys.argv[0]} --test img.jpg # Test on image")
