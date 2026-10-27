#!/usr/bin/env python3
"""Measure player-marker detection on human-annotated game frames.

Input JSON:
{"frames": [{"id":"match1/frame001","truth":[{"box":[0.1,0.1,0.2,0.2],"side":"enemy"}],
"predictions":[{"box":[0.1,0.1,0.2,0.2],"side":"enemy"}]}]}
Coordinates are [x, y, width, height], normalized 0..1.
Results are measurements only; confidence scores are not accuracy claims.
"""
import argparse
import json
import math
from pathlib import Path


def iou(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    iw = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    ih = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    union = aw * ah + bw * bh - iw * ih
    return iw * ih / union if union > 0 else 0.0


def valid_box(box):
    return (isinstance(box, list) and len(box) == 4 and
            all(isinstance(v, (int, float)) and math.isfinite(v) for v in box) and
            box[2] > 0 and box[3] > 0 and
            box[0] >= 0 and box[1] >= 0 and
            box[0] + box[2] <= 1 and box[1] + box[3] <= 1)


def evaluate(data, side="enemy", min_iou=0.5):
    tp = fp = fn = 0
    for frame in data.get("frames", []):
        truths = frame.get("truth", [])
        predictions = frame.get("predictions", [])
        for obj in truths + predictions:
            if not valid_box(obj.get("box")):
                raise ValueError("Invalid normalized bounding box in frame " + str(frame.get("id")))
            if obj.get("side") not in ("enemy", "friendly", "unknown"):
                raise ValueError("Invalid side in frame " + str(frame.get("id")))
        ground = [obj["box"] for obj in truths if obj["side"] == side]
        output = [obj["box"] for obj in predictions if obj["side"] == side]
        pairs = sorted(((iou(p, g), pi, gi)
                        for pi, p in enumerate(output)
                        for gi, g in enumerate(ground)), reverse=True)
        used_prediction, used_truth = set(), set()
        for overlap, pi, gi in pairs:
            if overlap < min_iou:
                break
            if pi not in used_prediction and gi not in used_truth:
                used_prediction.add(pi)
                used_truth.add(gi)
        tp += len(used_prediction)
        fp += len(output) - len(used_prediction)
        fn += len(ground) - len(used_truth)
    precision = tp / (tp + fp) if tp + fp else None
    recall = tp / (tp + fn) if tp + fn else None
    return {"frames": len(data.get("frames", [])), "TP": tp, "FP": fp, "FN": fn,
            "precision": precision, "recall": recall}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("annotations", type=Path, help="Human-reviewed JSON annotation dataset")
    ap.add_argument("--side", choices=["enemy", "friendly"], default="enemy")
    ap.add_argument("--iou", type=float, default=0.5)
    args = ap.parse_args()
    if not 0 < args.iou <= 1:
        ap.error("--iou must be in (0, 1]")
    result = evaluate(json.loads(args.annotations.read_text(encoding="utf-8")), args.side, args.iou)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if result["precision"] is None:
        print("No positive predictions: precision cannot be measured.")
    else:
        print("Precision goal 99%: " + ("PASS on this dataset" if result["precision"] >= 0.99 else "NOT MET"))
    print("Synthetic examples do not establish live-game accuracy.")


if __name__ == "__main__":
    main()
