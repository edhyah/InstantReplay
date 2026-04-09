# Pose Estimation Model Research for InstantReplay

## Goal

Find pose estimation models that are:
- **Real-time**: ~30 FPS on iPad hardware (A-series / M-series chips)
- **Accurate enough** for volleyball approach step detection (foot plants, takeoff, landing)
- **Deployable on iOS** via CoreML, TFLite, or ONNX → CoreML conversion

## Current Baseline: Apple Vision Framework

The app currently uses `VNDetectHumanBodyPoseRequest` from Apple's Vision framework.

**Pros:**
- Native iOS API — zero integration overhead
- Hardware-accelerated on Neural Engine
- Multi-person detection
- 19 keypoints including torso joints

**Cons:**
- Limited to 19 keypoints (no individual finger/toe joints)
- Accuracy on fast athletic movements (jumps, mid-air poses) may be insufficient
- No ankle confidence scoring — critical for step detection
- Black-box model — cannot fine-tune or swap variants

---

## Candidate Models

### 1. MoveNet (Google)

| Attribute | Lightning | Thunder |
|-----------|-----------|---------|
| Input size | 192×192 | 256×256 |
| Keypoints | 17 (COCO) | 17 (COCO) |
| COCO AP | 53.6 (single-person) | 64.8 (single-person) |
| Mobile FPS | 25+ FPS (older Android) | ~15 FPS (older Android) |
| Model size | ~3 MB (int8) | ~7 MB (int8) |

**iOS deployment:** TFLite models available. TensorFlow's official iOS example app demonstrates MoveNet running on-device. Can be converted to CoreML via `coremltools`.

**Relevance to InstantReplay:**
- Lightning variant is fast enough for 30+ FPS on iPad
- Single-person only — fine since we track the dominant mover
- 17 keypoints include ankles (critical for step detection)
- Smart cropping algorithm helps maintain accuracy on moving subjects
- Well-tested in fitness/sports applications

**Concerns:**
- Lower COCO AP than top-down approaches
- No left/right foot distinction at the model level (relies on spatial position)

---

### 2. MediaPipe BlazePose (Google)

| Attribute | Lite | Full | Heavy |
|-----------|------|------|-------|
| Input size | 256×256 | 256×256 | 256×256 |
| Keypoints | 33 | 33 | 33 |
| Model size | ~3 MB | ~6 MB | ~12 MB |
| Mobile FPS | 30+ | 25+ | 15-20 |

**iOS deployment:** Native iOS support via MediaPipe SDK. QuickPose.ai provides a production-ready Swift wrapper. Qualcomm has optimized ONNX models available.

**Relevance to InstantReplay:**
- 33 keypoints include heel and toe landmarks — much better for step detection
- 3D pose estimation built in (useful for side-view depth ambiguity)
- Well-documented iOS integration path
- Battle-tested in fitness apps (yoga, dance, exercise tracking)

**Concerns:**
- Single-person only (uses a person detector + pose estimator pipeline)
- The "Full" and "Heavy" variants needed for accuracy are slower
- MediaPipe's iOS SDK is less actively maintained since Google's pivot

---

### 3. YOLO11 Pose (Ultralytics)

| Attribute | yolo11n-pose | yolo11s-pose | yolo11m-pose |
|-----------|-------------|-------------|-------------|
| Params | 2.6M | 9.9M | 20.1M |
| COCO AP | 50.0 | 58.9 | 64.3 |
| FLOPs | 7.9G | 23.2G | 52.4G |
| Keypoints | 17 (COCO) | 17 (COCO) | 17 (COCO) |

**iOS deployment:** Official CoreML export (`model.export(format='coreml')`). Ultralytics has an official YOLO iOS app. YOLO11 achieves 100+ FPS on Apple Silicon via CoreML (object detection; pose is somewhat slower but still real-time for nano/small variants).

**Relevance to InstantReplay:**
- Single-stage detection + pose = simpler pipeline
- Multi-person detection built in
- Nano variant is very fast on iPad Neural Engine
- Active community, frequent updates, excellent documentation
- CoreML export is first-class

**Concerns:**
- 17 COCO keypoints (no heel/toe like BlazePose)
- Nano variant trades accuracy for speed significantly
- Single-stage approach may have lower keypoint precision than top-down methods

---

### 4. RTMPose (OpenMMLab / MMPose)

| Attribute | RTMPose-t | RTMPose-s | RTMPose-m | RTMPose-l |
|-----------|-----------|-----------|-----------|-----------|
| Params | 3.3M | 5.5M | 13.6M | 27.7M |
| COCO AP | 68.5 | 72.2 | 75.8 | 76.5 |
| Mobile FPS (SD865) | 90+ | 70+ | 45+ | 30+ |
| Input size | 256×192 | 256×192 | 256×192 | 256×192 |

**iOS deployment:** ONNX models available for conversion to CoreML. The `-s` (small) variant runs at 70+ FPS on Snapdragon 865, which has comparable NPU throughput to Apple's A15/A16 Neural Engine. ONNX → CoreML conversion via `coremltools` is well-documented.

**Relevance to InstantReplay:**
- **Best accuracy-to-speed ratio** of all candidates
- RTMPose-s at 72.2 AP is significantly better than MoveNet Lightning (53.6 AP) at similar speed
- SimCC (Simple Coordinate Classification) output format is well-suited for quantization
- Top-down approach gives better per-person keypoint accuracy
- Multi-person support when paired with a detector (RTMDet)

**Concerns:**
- Requires a separate person detector for multi-person (adds latency)
- ONNX → CoreML conversion may need manual tuning
- 17 COCO keypoints (no heel/toe)
- Less documented iOS deployment path than YOLO or MediaPipe

---

## Recommendations

### For Step Detection Accuracy: MediaPipe BlazePose (Heavy)
- 33 keypoints with heel + toe = best foot tracking
- Already proven on iOS
- Trade: slower (~15-20 FPS), single-person only

### For Best Overall Accuracy: RTMPose-s
- 72.2 AP on COCO is far ahead of other mobile-friendly options
- 70+ FPS on comparable mobile hardware
- Trade: needs ONNX→CoreML conversion, needs separate detector

### For Easiest iOS Integration: YOLO11n-Pose
- First-class CoreML support, official iOS app exists
- Multi-person detection built in
- Trade: lower keypoint accuracy (50.0 AP for nano)

### For Fastest Inference: MoveNet Lightning
- Purpose-built for mobile, ~3 MB model
- Trade: lowest accuracy, single-person only

## Suggested Evaluation Order

1. **RTMPose-s** — Best accuracy for the speed; compare against Apple Vision
2. **MediaPipe BlazePose (Heavy)** — Heel/toe keypoints could transform step detection
3. **YOLO11n-Pose** — Easiest to deploy; check if accuracy is sufficient
4. **MoveNet Thunder** — If you need a simpler fallback with decent accuracy

## Next Steps

1. Run the comparison tests in this folder against actual volleyball videos
2. Compare per-joint accuracy (especially ankles) vs Apple Vision baseline
3. Benchmark inference speed on actual iPad hardware
4. For the winning model, prototype CoreML conversion and iOS integration
