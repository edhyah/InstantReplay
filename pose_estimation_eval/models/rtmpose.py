"""RTMPose adapter (ONNX Runtime).

RTMPose is a high-performance real-time pose estimation framework from
OpenMMLab.  This adapter uses pre-exported ONNX models so that the full
MMPose / PyTorch stack is **not** required at inference time.

Model variants
--------------
* **rtmpose-s** – 72.2 AP on COCO, 70+ FPS on Snapdragon 865
* **rtmpose-m** – 75.8 AP on COCO, 90+ FPS on desktop CPU
* **rtmpose-l** – 76.5 AP on COCO

For iPad deployment the ``-s`` (small) variant is the best candidate as it
is already proven on mobile SoCs with comparable NPU power.
"""

from __future__ import annotations

import urllib.request
from pathlib import Path

import cv2
import numpy as np

from pose_estimation_eval.models.base import CANONICAL_JOINTS, Keypoint, PoseModel, PoseResult

# RTMPose outputs COCO 17-keypoint format.
_RTMPOSE_JOINT_NAMES: list[str] = [
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

_ONNX_URL = (
    "https://download.openmmlab.com/mmpose/v1/projects/rtmposev1/"
    "onnx/rtmpose-s_simcc-body7_pt-body7-halpe26_700e-256x192-7f134165_20230605.zip"
)

_CACHE_DIR = Path.home() / ".cache" / "pose_estimation_eval"
_INPUT_SIZE = (192, 256)  # (width, height)

_MEAN = np.array([123.675, 116.28, 103.53], dtype=np.float32)
_STD = np.array([58.395, 57.12, 57.375], dtype=np.float32)


class RTMPoseModel(PoseModel):
    """RTMPose via ONNX Runtime (no PyTorch / MMPose dependency)."""

    def __init__(self, onnx_path: str | Path | None = None) -> None:
        self._onnx_path = Path(onnx_path) if onnx_path else None
        self._session: object | None = None

    def name(self) -> str:
        return "rtmpose_s"

    def load(self) -> None:
        import onnxruntime as ort

        if self._onnx_path is None:
            self._onnx_path = _ensure_model()

        self._session = ort.InferenceSession(
            str(self._onnx_path),
            providers=["CPUExecutionProvider"],
        )

    def estimate(self, frame: np.ndarray) -> list[PoseResult]:
        if self._session is None:
            raise RuntimeError("Call load() before estimate()")

        img_h, img_w = frame.shape[:2]

        # Pre-process: BGR→RGB, resize, normalise, transpose to NCHW
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        resized = cv2.resize(rgb, _INPUT_SIZE).astype(np.float32)
        normalised = (resized - _MEAN) / _STD
        blob = np.transpose(normalised, (2, 0, 1))[np.newaxis, ...]  # (1, 3, H, W)

        input_name = self._session.get_inputs()[0].name
        outputs = self._session.run(None, {input_name: blob.astype(np.float32)})

        # RTMPose SimCC outputs: simcc_x (1,17,W*2), simcc_y (1,17,H*2)
        simcc_x = outputs[0][0]  # (17, W*2)
        simcc_y = outputs[1][0]  # (17, H*2)

        keypoints: list[Keypoint] = []
        for idx, joint_name in enumerate(_RTMPOSE_JOINT_NAMES):
            if joint_name not in CANONICAL_JOINTS:
                continue
            x_idx = int(np.argmax(simcc_x[idx]))
            y_idx = int(np.argmax(simcc_y[idx]))
            conf_x = float(simcc_x[idx][x_idx])
            conf_y = float(simcc_y[idx][y_idx])
            confidence = (conf_x + conf_y) / 2.0

            # Convert SimCC indices back to normalised coordinates
            x_norm = (x_idx / simcc_x.shape[1])
            y_norm = (y_idx / simcc_y.shape[1])

            keypoints.append(
                Keypoint(name=joint_name, x=x_norm, y=y_norm, confidence=confidence)
            )

        # Derived joints
        _add_derived_joints(keypoints)

        result = PoseResult(keypoints=keypoints)
        _fill_torso_centroid(result)
        return [result]


def _ensure_model() -> Path:
    """Download and extract the RTMPose ONNX model if needed."""
    _CACHE_DIR.mkdir(parents=True, exist_ok=True)
    onnx_path = _CACHE_DIR / "rtmpose-s.onnx"

    if not onnx_path.exists():
        zip_path = _CACHE_DIR / "rtmpose-s.zip"
        if not zip_path.exists():
            urllib.request.urlretrieve(_ONNX_URL, zip_path)

        import zipfile

        with zipfile.ZipFile(zip_path, "r") as zf:
            # Find the .onnx file inside
            onnx_names = [n for n in zf.namelist() if n.endswith(".onnx")]
            if not onnx_names:
                raise FileNotFoundError("No .onnx file found in downloaded archive")
            with zf.open(onnx_names[0]) as src, open(onnx_path, "wb") as dst:
                dst.write(src.read())

    return onnx_path


def _add_derived_joints(keypoints: list[Keypoint]) -> None:
    by_name = {kp.name: kp for kp in keypoints}

    ls, rs = by_name.get("leftShoulder"), by_name.get("rightShoulder")
    if ls and rs and ls.confidence > 0.1 and rs.confidence > 0.1:
        keypoints.append(
            Keypoint(
                name="neck",
                x=(ls.x + rs.x) / 2,
                y=(ls.y + rs.y) / 2,
                confidence=min(ls.confidence, rs.confidence),
            )
        )

    lh, rh = by_name.get("leftHip"), by_name.get("rightHip")
    if lh and rh and lh.confidence > 0.1 and rh.confidence > 0.1:
        keypoints.append(
            Keypoint(
                name="root",
                x=(lh.x + rh.x) / 2,
                y=(lh.y + rh.y) / 2,
                confidence=min(lh.confidence, rh.confidence),
            )
        )


def _fill_torso_centroid(result: PoseResult) -> None:
    torso_joints = ["leftShoulder", "rightShoulder", "leftHip", "rightHip"]
    xs, ys = [], []
    for kp in result.keypoints:
        if kp.name in torso_joints and kp.confidence > 0.1:
            xs.append(kp.x)
            ys.append(kp.y)
    if len(xs) >= 2:
        result.torso_centroid_x = sum(xs) / len(xs)
        result.torso_centroid_y = sum(ys) / len(ys)
