"""MoveNet Lightning / Thunder adapter.

Uses TensorFlow Lite via the ``tflite-runtime`` package (or falls back to
the full ``tensorflow`` package) to run Google's MoveNet single-pose model.

Model variants
--------------
* **Lightning** – 192x192 input, ~6 ms on modern mobile, 17 keypoints
* **Thunder**  – 256x256 input, ~11 ms on modern mobile, 17 keypoints

Both variants are downloaded automatically from TF Hub on first use.
"""

from __future__ import annotations

import urllib.request
from pathlib import Path

import cv2
import numpy as np

from pose_estimation_eval.models.base import CANONICAL_JOINTS, Keypoint, PoseModel, PoseResult

# MoveNet outputs 17 keypoints in COCO order.
_MOVENET_JOINT_NAMES: list[str] = [
    "nose",
    "leftEye",
    "rightEye",
    "leftEar",
    "rightEar",
    "leftShoulder",
    "rightShoulder",
    "leftElbow",
    "rightElbow",
    "leftWrist",
    "rightWrist",
    "leftHip",
    "rightHip",
    "leftKnee",
    "rightKnee",
    "leftAnkle",
    "rightAnkle",
]

_MODEL_URLS: dict[str, str] = {
    "lightning": (
        "https://tfhub.dev/google/lite-model/movenet/singlepose/lightning/tflite/int8/4"
        "?lite-format=tflite"
    ),
    "thunder": (
        "https://tfhub.dev/google/lite-model/movenet/singlepose/thunder/tflite/int8/4"
        "?lite-format=tflite"
    ),
}

_INPUT_SIZES: dict[str, int] = {
    "lightning": 192,
    "thunder": 256,
}

_CACHE_DIR = Path.home() / ".cache" / "pose_estimation_eval"


def _download_model(variant: str) -> Path:
    """Download the TFLite model if not already cached."""
    _CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = _CACHE_DIR / f"movenet_{variant}.tflite"
    if not path.exists():
        url = _MODEL_URLS[variant]
        urllib.request.urlretrieve(url, path)
    return path


class MoveNetModel(PoseModel):
    """MoveNet single-pose model (Lightning or Thunder)."""

    def __init__(self, variant: str = "lightning") -> None:
        if variant not in _MODEL_URLS:
            raise ValueError(f"Unknown variant {variant!r}; choose 'lightning' or 'thunder'")
        self._variant = variant
        self._input_size = _INPUT_SIZES[variant]
        self._interpreter: object | None = None

    def name(self) -> str:
        return f"movenet_{self._variant}"

    def load(self) -> None:
        try:
            from tflite_runtime.interpreter import Interpreter
        except ImportError:
            from tensorflow.lite.python.interpreter import Interpreter  # type: ignore[import]

        model_path = _download_model(self._variant)
        self._interpreter = Interpreter(model_path=str(model_path))
        self._interpreter.allocate_tensors()

    def estimate(self, frame: np.ndarray) -> list[PoseResult]:
        if self._interpreter is None:
            raise RuntimeError("Call load() before estimate()")

        input_details = self._interpreter.get_input_details()
        output_details = self._interpreter.get_output_details()

        # Pre-process: resize, convert to RGB, add batch dim
        img = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        img = cv2.resize(img, (self._input_size, self._input_size))

        # Handle int8 quantized models
        input_dtype = input_details[0]["dtype"]
        if input_dtype == np.uint8:
            input_data = np.expand_dims(img.astype(np.uint8), axis=0)
        else:
            input_data = np.expand_dims(img.astype(np.float32) / 255.0, axis=0)

        self._interpreter.set_tensor(input_details[0]["index"], input_data)
        self._interpreter.invoke()

        # Output shape: [1, 1, 17, 3] → (y, x, confidence)
        output = self._interpreter.get_tensor(output_details[0]["index"])
        keypoints_raw = output[0, 0]  # shape (17, 3)

        keypoints: list[Keypoint] = []
        for idx, joint_name in enumerate(_MOVENET_JOINT_NAMES):
            if joint_name not in CANONICAL_JOINTS:
                continue
            y_norm, x_norm, conf = keypoints_raw[idx]
            keypoints.append(Keypoint(
                name=joint_name,
                x=float(x_norm),
                y=float(y_norm),
                confidence=float(conf),
            ))

        result = PoseResult(keypoints=keypoints)
        _fill_torso_centroid(result)
        return [result]


def _fill_torso_centroid(result: PoseResult) -> None:
    """Compute torso centroid from shoulder and hip joints."""
    torso_joints = ["leftShoulder", "rightShoulder", "leftHip", "rightHip"]
    xs, ys = [], []
    for kp in result.keypoints:
        if kp.name in torso_joints and kp.confidence > 0.1:
            xs.append(kp.x)
            ys.append(kp.y)
    if len(xs) >= 2:
        result.torso_centroid_x = sum(xs) / len(xs)
        result.torso_centroid_y = sum(ys) / len(ys)
