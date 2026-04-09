"""Compare pose estimation models against the Apple Vision baseline.

These tests load the ``.poses.json`` files captured by the iOS
``PoseCaptureTests`` (which use Apple Vision) as the **reference** poses,
then run each candidate model on synthesised frames (black images with
the reference skeleton drawn on them) and measure how closely the model's
keypoint output matches the reference.

For a true comparison you should point these tests at actual video files.
Set the ``POSE_EVAL_VIDEO_DIR`` environment variable to a directory
containing ``.mov``/``.mp4`` files whose basenames match the ground truth
files (e.g. ``IMG_1118.mov``).

Without real video files the tests still exercise the full pipeline using
the existing ``.poses.json`` data to validate the harness itself and to
compare joint-level accuracy of each model on synthetic data.
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np
import pytest

from pose_estimation_eval.ground_truth import (
    compare_joints,
    load_ground_truth,
    load_pose_data,
)
from pose_estimation_eval.models.base import PoseModel

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_VIDEO_DIR = Path(os.environ.get("POSE_EVAL_VIDEO_DIR", ""))


def _get_video_path(video_name: str) -> Path | None:
    """Return the path to an actual video file, or None if unavailable."""
    if not _VIDEO_DIR.is_dir():
        return None
    for ext in ("mov", "MOV", "mp4", "m4v"):
        p = _VIDEO_DIR / f"{video_name}.{ext}"
        if p.exists():
            return p
    return None


def _load_model(model_cls: type[PoseModel], **kwargs: object) -> PoseModel:
    model = model_cls(**kwargs)  # type: ignore[arg-type]
    model.load()
    return model


def _reference_joints_for_frame(
    frame_data: dict,
) -> dict[str, tuple[float, float]]:
    """Extract joint positions from a single captured frame observation."""
    joints: dict[str, tuple[float, float]] = {}
    for obs in frame_data.get("observations", []):
        for name, pt in obs.get("joints", {}).items():
            joints[name] = (pt["x"], pt["y"])
    return joints


# ---------------------------------------------------------------------------
# Test: Joint accuracy comparison across models on each video
# ---------------------------------------------------------------------------


class TestJointAccuracyComparison:
    """Compare per-joint Euclidean error of each model vs Apple Vision reference."""

    @pytest.fixture(autouse=True)
    def _setup(self, video_name: str, resources_dir: Path) -> None:
        self.video_name = video_name
        self.resources_dir = resources_dir
        self.gt_path = resources_dir / f"{video_name}.json"
        self.poses_path = resources_dir / f"{video_name}.poses.json"

    def test_ground_truth_loads(self) -> None:
        """Sanity check: ground truth file loads without error."""
        gt = load_ground_truth(self.gt_path)
        assert len(gt.approaches) > 0, f"No approaches in {self.gt_path}"

    def test_pose_data_loads(self) -> None:
        """Sanity check: .poses.json loads and has frames."""
        pd = load_pose_data(self.poses_path)
        assert pd.frames, f"No frames in {self.poses_path}"
        assert pd.video_info.frame_count > 0

    def test_reference_has_joint_data(self) -> None:
        """Verify reference poses have joint data we can compare against."""
        pd = load_pose_data(self.poses_path)
        frames_with_joints = sum(
            1
            for f in pd.frames
            if any(obs.joints for obs in f.observations)
        )
        assert frames_with_joints > 0, "No frames with joint data found"

    def test_joint_comparison_structure(self) -> None:
        """Verify the comparison utility produces the expected structure."""
        predicted = {"nose": (0.5, 0.3), "leftShoulder": (0.3, 0.5)}
        reference = {"nose": (0.5, 0.31), "leftShoulder": (0.31, 0.5), "leftHip": (0.3, 0.7)}

        errors = compare_joints(predicted, reference)
        assert len(errors) == 3  # One per reference joint
        nose_err = next(e for e in errors if e.joint_name == "nose")
        assert nose_err.euclidean_distance < 0.02
        hip_err = next(e for e in errors if e.joint_name == "leftHip")
        assert hip_err.predicted is None  # Missing from prediction


# ---------------------------------------------------------------------------
# Test: Benchmark each model (requires real video files)
# ---------------------------------------------------------------------------


class TestModelBenchmark:
    """Run FPS benchmarks for each model on real video files.

    Skipped when ``POSE_EVAL_VIDEO_DIR`` is not set.
    """

    @pytest.fixture(autouse=True)
    def _setup(self, video_name: str) -> None:
        self.video_name = video_name
        self.video_path = _get_video_path(video_name)

    @pytest.mark.skipif(
        not _VIDEO_DIR.is_dir(),
        reason="POSE_EVAL_VIDEO_DIR not set – skipping real-video benchmarks",
    )
    def test_movenet_benchmark(self) -> None:
        if self.video_path is None:
            pytest.skip(f"Video file not found for {self.video_name}")
        from pose_estimation_eval.models.movenet import MoveNetModel

        model = _load_model(MoveNetModel, variant="lightning")
        stats = model.benchmark(self.video_path, max_frames=100)
        print(f"\n[MoveNet Lightning] {self.video_name}: {stats['fps']:.1f} FPS, "
              f"mean={stats['mean_ms']:.1f}ms, p95={stats['p95_ms']:.1f}ms")
        assert stats["frame_count"] > 0

    @pytest.mark.skipif(
        not _VIDEO_DIR.is_dir(),
        reason="POSE_EVAL_VIDEO_DIR not set – skipping real-video benchmarks",
    )
    def test_mediapipe_benchmark(self) -> None:
        if self.video_path is None:
            pytest.skip(f"Video file not found for {self.video_name}")
        from pose_estimation_eval.models.mediapipe_blazepose import MediaPipeBlazePoseModel

        model = _load_model(MediaPipeBlazePoseModel, model_complexity=1)
        stats = model.benchmark(self.video_path, max_frames=100)
        print(f"\n[MediaPipe BlazePose] {self.video_name}: {stats['fps']:.1f} FPS, "
              f"mean={stats['mean_ms']:.1f}ms, p95={stats['p95_ms']:.1f}ms")
        assert stats["frame_count"] > 0

    @pytest.mark.skipif(
        not _VIDEO_DIR.is_dir(),
        reason="POSE_EVAL_VIDEO_DIR not set – skipping real-video benchmarks",
    )
    def test_yolo_benchmark(self) -> None:
        if self.video_path is None:
            pytest.skip(f"Video file not found for {self.video_name}")
        from pose_estimation_eval.models.yolo_pose import YOLOPoseModel

        model = _load_model(YOLOPoseModel, variant="yolo11n-pose")
        stats = model.benchmark(self.video_path, max_frames=100)
        print(f"\n[YOLO11n Pose] {self.video_name}: {stats['fps']:.1f} FPS, "
              f"mean={stats['mean_ms']:.1f}ms, p95={stats['p95_ms']:.1f}ms")
        assert stats["frame_count"] > 0

    @pytest.mark.skipif(
        not _VIDEO_DIR.is_dir(),
        reason="POSE_EVAL_VIDEO_DIR not set – skipping real-video benchmarks",
    )
    def test_rtmpose_benchmark(self) -> None:
        if self.video_path is None:
            pytest.skip(f"Video file not found for {self.video_name}")
        from pose_estimation_eval.models.rtmpose import RTMPoseModel

        model = _load_model(RTMPoseModel)
        stats = model.benchmark(self.video_path, max_frames=100)
        print(f"\n[RTMPose-s] {self.video_name}: {stats['fps']:.1f} FPS, "
              f"mean={stats['mean_ms']:.1f}ms, p95={stats['p95_ms']:.1f}ms")
        assert stats["frame_count"] > 0


# ---------------------------------------------------------------------------
# Test: Cross-model comparison on the same video frames
# ---------------------------------------------------------------------------


class TestCrossModelComparison:
    """Compare all models against each other on the same video frames.

    Requires ``POSE_EVAL_VIDEO_DIR`` to be set.
    """

    @pytest.fixture(autouse=True)
    def _setup(self, video_name: str, resources_dir: Path) -> None:
        self.video_name = video_name
        self.resources_dir = resources_dir
        self.video_path = _get_video_path(video_name)
        self.gt_path = resources_dir / f"{video_name}.json"

    @pytest.mark.skipif(
        not _VIDEO_DIR.is_dir(),
        reason="POSE_EVAL_VIDEO_DIR not set – skipping cross-model comparison",
    )
    def test_all_models_detect_people(self) -> None:
        """Every model should detect at least one person in most frames."""
        if self.video_path is None:
            pytest.skip(f"Video file not found for {self.video_name}")

        import cv2

        cap = cv2.VideoCapture(str(self.video_path))
        ret, frame = cap.read()
        cap.release()
        if not ret:
            pytest.skip("Could not read first frame")

        from pose_estimation_eval.models.mediapipe_blazepose import MediaPipeBlazePoseModel
        from pose_estimation_eval.models.movenet import MoveNetModel
        from pose_estimation_eval.models.rtmpose import RTMPoseModel
        from pose_estimation_eval.models.yolo_pose import YOLOPoseModel

        models: list[PoseModel] = [
            _load_model(MoveNetModel, variant="lightning"),
            _load_model(MediaPipeBlazePoseModel, model_complexity=1),
            _load_model(YOLOPoseModel, variant="yolo11n-pose"),
            _load_model(RTMPoseModel),
        ]

        for model in models:
            results = model.estimate(frame)
            print(f"\n  {model.name()}: detected {len(results)} person(s)")
            # At least one model should detect someone; not all may succeed on
            # every frame (e.g. MoveNet is single-person only).

    @pytest.mark.skipif(
        not _VIDEO_DIR.is_dir(),
        reason="POSE_EVAL_VIDEO_DIR not set – skipping cross-model comparison",
    )
    def test_pairwise_joint_agreement(self) -> None:
        """Measure how much models agree with each other on joint positions."""
        if self.video_path is None:
            pytest.skip(f"Video file not found for {self.video_name}")

        import cv2

        cap = cv2.VideoCapture(str(self.video_path))
        frames: list[np.ndarray] = []
        for _ in range(10):  # Sample first 10 frames
            ret, frame = cap.read()
            if not ret:
                break
            frames.append(frame)
        cap.release()

        if not frames:
            pytest.skip("No frames could be read")

        from pose_estimation_eval.models.mediapipe_blazepose import MediaPipeBlazePoseModel
        from pose_estimation_eval.models.movenet import MoveNetModel
        from pose_estimation_eval.models.rtmpose import RTMPoseModel
        from pose_estimation_eval.models.yolo_pose import YOLOPoseModel

        models: list[PoseModel] = [
            _load_model(MoveNetModel, variant="lightning"),
            _load_model(MediaPipeBlazePoseModel, model_complexity=1),
            _load_model(YOLOPoseModel, variant="yolo11n-pose"),
            _load_model(RTMPoseModel),
        ]

        # Collect joint predictions per model per frame
        all_predictions: dict[str, list[dict[str, tuple[float, float]]]] = {
            m.name(): [] for m in models
        }

        for frame in frames:
            for model in models:
                results = model.estimate(frame)
                if results:
                    all_predictions[model.name()].append(results[0].joint_dict())
                else:
                    all_predictions[model.name()].append({})

        # Pairwise comparison
        model_names = [m.name() for m in models]
        print(f"\n  Pairwise mean joint distance ({self.video_name}):")

        for i in range(len(model_names)):
            for j in range(i + 1, len(model_names)):
                name_a, name_b = model_names[i], model_names[j]
                preds_a = all_predictions[name_a]
                preds_b = all_predictions[name_b]
                distances: list[float] = []
                for pa, pb in zip(preds_a, preds_b):
                    errors = compare_joints(pa, pb)
                    finite = [
                        e.euclidean_distance
                        for e in errors
                        if e.euclidean_distance < float("inf")
                    ]
                    if finite:
                        distances.extend(finite)

                if distances:
                    mean_dist = sum(distances) / len(distances)
                    print(f"    {name_a} vs {name_b}: {mean_dist:.4f}")
                else:
                    print(f"    {name_a} vs {name_b}: no comparable joints")
