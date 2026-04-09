# Pose Estimation Model Evaluation

Python test harness for comparing pose estimation models against each other and against the Apple Vision baseline used by the main InstantReplay iOS app.

## Why

Apple's Vision framework pose estimation may not be accurate enough for detailed volleyball approach analysis (step detection, foot tracking). This harness lets you evaluate alternative models on your actual test videos before committing to an iOS integration.

## Models Tested

| Model | Keypoints | Multi-Person | Mobile-Ready | Notes |
|-------|-----------|-------------|-------------|-------|
| **MoveNet Lightning** | 17 (COCO) | No | Yes (TFLite) | Fastest, good for single-player tracking |
| **MoveNet Thunder** | 17 (COCO) | No | Yes (TFLite) | Higher accuracy variant of Lightning |
| **MediaPipe BlazePose** | 33 | No | Yes (native iOS) | Includes hands/feet, 3D capable |
| **YOLO11n-Pose** | 17 (COCO) | Yes | Yes (CoreML) | Single-stage detection + pose |
| **RTMPose-s** | 17 (COCO) | Yes | Yes (ONNX/CoreML) | Best accuracy/speed tradeoff |

## Setup

```bash
cd pose_estimation_eval
pip install -e ".[dev]"
```

## Running Tests

### Without video files (harness validation only)

```bash
pytest tests/ -v
```

This runs the ground truth loading tests and comparison utility tests using the existing `.poses.json` files from `InstantReplayMacTests/Resources/`.

### With real video files

Place your test videos (`.mov`/`.mp4`) in a directory and set the environment variable:

```bash
POSE_EVAL_VIDEO_DIR=/path/to/videos pytest tests/ -v -s
```

Video filenames should match the ground truth files (e.g. `IMG_1118.mov` pairs with `InstantReplayMacTests/Resources/IMG_1118.json`).

### Run benchmarks only

```bash
POSE_EVAL_VIDEO_DIR=/path/to/videos pytest tests/test_model_comparison.py -v -s -k "benchmark"
```

### Run cross-model comparison

```bash
POSE_EVAL_VIDEO_DIR=/path/to/videos pytest tests/test_model_comparison.py -v -s -k "cross_model"
```

## Project Structure

```
pose_estimation_eval/
├── models/
│   ├── base.py                  # PoseModel ABC, shared types
│   ├── movenet.py               # MoveNet Lightning/Thunder (TFLite)
│   ├── mediapipe_blazepose.py   # MediaPipe BlazePose
│   ├── yolo_pose.py             # YOLO11 Pose (Ultralytics)
│   └── rtmpose.py               # RTMPose (ONNX Runtime)
├── tests/
│   ├── conftest.py              # Shared fixtures
│   ├── test_ground_truth_loading.py  # Ground truth + pose data parsing
│   └── test_model_comparison.py      # Cross-model comparison tests
├── ground_truth.py              # Ground truth & pose data loaders
├── data/                        # Place test videos here (gitignored)
├── pyproject.toml
└── README.md
```

## Adding a New Model

1. Create a new file in `models/` that subclasses `PoseModel`
2. Implement `name()`, `load()`, and `estimate()`
3. Map the model's joint indices to `CANONICAL_JOINTS` names
4. Add an import to `models/__init__.py`
5. Add benchmark/comparison entries to the test files
