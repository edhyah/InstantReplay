"""Ultralytics YOLO11 Pose adapter.

YOLO11-Pose performs single-stage detection + keypoint estimation.
It detects multiple people and outputs 17 COCO keypoints per person.

Model variants
--------------
* **yolo11n-pose** – nano, fastest, ~2.5M params
* **yolo11s-pose** – small, good balance
* **yolo11m-pose** – medium, higher accuracy

The ``ultralytics`` package handles model download automatically.
"""

from __future__ import annotations

import numpy as np

from pose_estimation_eval.models.base import CANONICAL_JOINTS, Keypoint, PoseModel, PoseResult

# YOLO pose uses the standard COCO 17-keypoint order.
_YOLO_JOINT_NAMES: list[str] = [
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


class YOLOPoseModel(PoseModel):
    """YOLO11 Pose model via the ``ultralytics`` package."""

    def __init__(self, variant: str = "yolo11n-pose") -> None:
        self._variant = variant
        self._model: object | None = None

    def name(self) -> str:
        return self._variant.replace("-", "_")

    def load(self) -> None:
        from ultralytics import YOLO

        self._model = YOLO(f"{self._variant}.pt")

    def estimate(self, frame: np.ndarray) -> list[PoseResult]:
        if self._model is None:
            raise RuntimeError("Call load() before estimate()")

        # Run inference (frame is BGR which YOLO expects)
        results = self._model(frame, verbose=False)
        poses: list[PoseResult] = []

        for result in results:
            if result.keypoints is None:
                continue

            kps_data = result.keypoints.data  # shape: (N, 17, 3) → x, y, conf
            img_h, img_w = frame.shape[:2]

            for person_idx in range(kps_data.shape[0]):
                keypoints: list[Keypoint] = []
                person_kps = kps_data[person_idx].cpu().numpy()  # (17, 3)

                for joint_idx, joint_name in enumerate(_YOLO_JOINT_NAMES):
                    if joint_name not in CANONICAL_JOINTS:
                        continue
                    x_px, y_px, conf = person_kps[joint_idx]
                    # Normalise to 0-1
                    x_norm = float(x_px) / img_w if img_w > 0 else 0.0
                    y_norm = float(y_px) / img_h if img_h > 0 else 0.0
                    keypoints.append(
                        Keypoint(name=joint_name, x=x_norm, y=y_norm, confidence=float(conf))
                    )

                # Derive "neck" and "root"
                _add_derived_joints(keypoints)

                pose = PoseResult(keypoints=keypoints)
                _fill_torso_centroid(pose)
                poses.append(pose)

        return poses


def _add_derived_joints(keypoints: list[Keypoint]) -> None:
    """Add neck and root as midpoints of shoulders and hips."""
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
