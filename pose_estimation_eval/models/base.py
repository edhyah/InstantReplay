"""Base interface for pose estimation models.

Every model adapter must subclass ``PoseModel`` and implement the two
abstract methods so that the comparison harness can treat all models
uniformly.
"""

from __future__ import annotations

import abc
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# Shared keypoint taxonomy
# ---------------------------------------------------------------------------

# Canonical joint names shared across all models.  Individual model adapters
# map their own joint indices to this list.  The names deliberately mirror the
# Apple Vision ``VNHumanBodyPoseObservation.JointName`` values used by the
# existing Swift codebase so that results are directly comparable.
CANONICAL_JOINTS: list[str] = [
    "nose",
    "neck",
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
    "leftEye",
    "rightEye",
    "leftEar",
    "rightEar",
    "root",
]


@dataclass
class Keypoint:
    """A single detected joint in normalised image coordinates (0-1)."""

    name: str
    x: float
    y: float
    confidence: float


@dataclass
class PoseResult:
    """Pose estimation result for a single frame."""

    keypoints: list[Keypoint] = field(default_factory=list)
    torso_centroid_x: float = 0.0
    torso_centroid_y: float = 0.0
    inference_time_ms: float = 0.0

    def joint_dict(self) -> dict[str, tuple[float, float]]:
        """Return a mapping ``{name: (x, y)}`` for recognised joints."""
        return {kp.name: (kp.x, kp.y) for kp in self.keypoints if kp.confidence > 0}


# ---------------------------------------------------------------------------
# Abstract base class
# ---------------------------------------------------------------------------


class PoseModel(abc.ABC):
    """Unified interface that every pose-estimation model adapter must implement."""

    @abc.abstractmethod
    def name(self) -> str:
        """Human-readable model identifier (e.g. ``movenet_lightning``)."""

    @abc.abstractmethod
    def load(self) -> None:
        """Download / initialise the model.  Called once before inference."""

    @abc.abstractmethod
    def estimate(self, frame: np.ndarray) -> list[PoseResult]:
        """Run inference on a single BGR frame (OpenCV convention).

        Parameters
        ----------
        frame:
            HxWx3 ``uint8`` BGR image.

        Returns
        -------
        list[PoseResult]
            One entry per detected person.
        """

    # ------------------------------------------------------------------
    # Convenience helpers
    # ------------------------------------------------------------------

    def estimate_timed(self, frame: np.ndarray) -> list[PoseResult]:
        """Like :meth:`estimate` but fills in ``inference_time_ms``."""
        t0 = time.perf_counter()
        results = self.estimate(frame)
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        for r in results:
            r.inference_time_ms = elapsed_ms
        return results

    def benchmark(self, video_path: str | Path, max_frames: int = 300) -> dict:
        """Run the model over a video and return timing statistics.

        Returns a dict with keys ``fps``, ``mean_ms``, ``p50_ms``,
        ``p95_ms``, ``p99_ms``, ``frame_count``.
        """
        import cv2

        cap = cv2.VideoCapture(str(video_path))
        times: list[float] = []
        count = 0
        while cap.isOpened() and count < max_frames:
            ret, frame = cap.read()
            if not ret:
                break
            results = self.estimate_timed(frame)
            if results:
                times.append(results[0].inference_time_ms)
            count += 1
        cap.release()

        arr = np.array(times) if times else np.array([0.0])
        return {
            "fps": 1000.0 / arr.mean() if arr.mean() > 0 else 0.0,
            "mean_ms": float(arr.mean()),
            "p50_ms": float(np.percentile(arr, 50)),
            "p95_ms": float(np.percentile(arr, 95)),
            "p99_ms": float(np.percentile(arr, 99)),
            "frame_count": count,
        }
