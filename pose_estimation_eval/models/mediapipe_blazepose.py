"""MediaPipe BlazePose adapter.

BlazePose detects 33 keypoints including hands and feet, with optional
3D coordinates.  This adapter uses the ``mediapipe`` Python package and
maps the 33-point topology to the canonical joint names used by the
comparison harness.
"""

from __future__ import annotations

import cv2
import numpy as np

from pose_estimation_eval.models.base import CANONICAL_JOINTS, Keypoint, PoseModel, PoseResult

# MediaPipe BlazePose landmark indices → canonical names.
# Only the joints that exist in CANONICAL_JOINTS are mapped.
_BLAZEPOSE_MAP: dict[int, str] = {
    0: "nose",
    2: "leftEye",
    5: "rightEye",
    7: "leftEar",
    8: "rightEar",
    11: "leftShoulder",
    12: "rightShoulder",
    13: "leftElbow",
    14: "rightElbow",
    15: "leftWrist",
    16: "rightWrist",
    23: "leftHip",
    24: "rightHip",
    25: "leftKnee",
    26: "rightKnee",
    27: "leftAnkle",
    28: "rightAnkle",
}


class MediaPipeBlazePoseModel(PoseModel):
    """MediaPipe BlazePose (Heavy model by default for best accuracy)."""

    def __init__(self, model_complexity: int = 2) -> None:
        self._model_complexity = model_complexity
        self._pose: object | None = None

    def name(self) -> str:
        complexity_label = {0: "lite", 1: "full", 2: "heavy"}
        label = complexity_label.get(self._model_complexity, str(self._model_complexity))
        return f"mediapipe_blazepose_{label}"

    def load(self) -> None:
        import mediapipe as mp

        self._pose = mp.solutions.pose.Pose(
            static_image_mode=False,
            model_complexity=self._model_complexity,
            min_detection_confidence=0.5,
            min_tracking_confidence=0.5,
        )

    def estimate(self, frame: np.ndarray) -> list[PoseResult]:
        if self._pose is None:
            raise RuntimeError("Call load() before estimate()")

        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        mp_result = self._pose.process(rgb)

        if not mp_result.pose_landmarks:
            return []

        landmarks = mp_result.pose_landmarks.landmark
        keypoints: list[Keypoint] = []

        for idx, joint_name in _BLAZEPOSE_MAP.items():
            if joint_name not in CANONICAL_JOINTS:
                continue
            lm = landmarks[idx]
            keypoints.append(
                Keypoint(
                    name=joint_name,
                    x=float(lm.x),
                    y=float(lm.y),
                    confidence=float(lm.visibility),
                )
            )

        # Derive "neck" as midpoint of shoulders
        left_shoulder = landmarks[11]
        right_shoulder = landmarks[12]
        if left_shoulder.visibility > 0.1 and right_shoulder.visibility > 0.1:
            keypoints.append(
                Keypoint(
                    name="neck",
                    x=(left_shoulder.x + right_shoulder.x) / 2,
                    y=(left_shoulder.y + right_shoulder.y) / 2,
                    confidence=min(left_shoulder.visibility, right_shoulder.visibility),
                )
            )

        # Derive "root" as midpoint of hips
        left_hip = landmarks[23]
        right_hip = landmarks[24]
        if left_hip.visibility > 0.1 and right_hip.visibility > 0.1:
            keypoints.append(
                Keypoint(
                    name="root",
                    x=(left_hip.x + right_hip.x) / 2,
                    y=(left_hip.y + right_hip.y) / 2,
                    confidence=min(left_hip.visibility, right_hip.visibility),
                )
            )

        result = PoseResult(keypoints=keypoints)
        _fill_torso_centroid(result)
        return [result]


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
