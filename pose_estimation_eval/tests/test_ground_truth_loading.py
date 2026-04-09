"""Tests for ground truth and pose data loading utilities."""

from __future__ import annotations

from pathlib import Path

from pose_estimation_eval.ground_truth import (
    compare_joints,
    load_ground_truth,
    load_pose_data,
)


class TestGroundTruthLoading:
    """Verify we can correctly load the existing InstantReplay ground truth files."""

    def test_load_all_ground_truth_files(self, resources_dir: Path) -> None:
        """Every .json file in Resources should parse without error."""
        gt_files = sorted(resources_dir.glob("*.json"))
        gt_files = [f for f in gt_files if not f.name.endswith(".poses.json")]
        assert gt_files, "No ground truth files found"

        for path in gt_files:
            gt = load_ground_truth(path)
            assert len(gt.approaches) > 0, f"{path.name}: no approaches"
            for approach in gt.approaches:
                assert approach.takeoff > approach.approach_start, (
                    f"{path.name}: takeoff should be after approach_start"
                )
                assert approach.peak > approach.takeoff, (
                    f"{path.name}: peak should be after takeoff"
                )
                assert approach.landing > approach.peak, (
                    f"{path.name}: landing should be after peak"
                )

    def test_load_all_pose_files(self, resources_dir: Path) -> None:
        """Every .poses.json file should parse without error."""
        pose_files = sorted(resources_dir.glob("*.poses.json"))
        assert pose_files, "No .poses.json files found"

        for path in pose_files:
            pd = load_pose_data(path)
            assert pd.frames, f"{path.name}: no frames"
            assert pd.video_info.frame_count > 0
            assert pd.video_info.duration > 0

    def test_ground_truth_steps_are_ordered(self, resources_dir: Path) -> None:
        """Step timestamps must be in order: first < second < orientation < plant < takeoff."""
        gt_files = sorted(resources_dir.glob("*.json"))
        gt_files = [f for f in gt_files if not f.name.endswith(".poses.json")]

        for path in gt_files:
            gt = load_ground_truth(path)
            for approach in gt.approaches:
                if approach.steps is None:
                    continue
                steps = approach.steps
                ordered = [
                    steps.get("first"),
                    steps.get("second"),
                    steps.get("orientation"),
                    steps.get("plant"),
                ]
                timestamps = [s.timestamp for s in ordered if s is not None]
                for i in range(1, len(timestamps)):
                    assert timestamps[i] > timestamps[i - 1], (
                        f"{path.name}: steps not in order"
                    )
                # Plant should be before takeoff
                if "plant" in steps:
                    assert steps["plant"].timestamp < approach.takeoff

    def test_pose_frames_are_chronological(self, resources_dir: Path) -> None:
        """Frame timestamps should be in increasing order."""
        pose_files = sorted(resources_dir.glob("*.poses.json"))

        for path in pose_files:
            pd = load_pose_data(path)
            timestamps = [f.timestamp for f in pd.frames]
            for i in range(1, len(timestamps)):
                assert timestamps[i] >= timestamps[i - 1], (
                    f"{path.name}: frame timestamps not in order at index {i}"
                )


class TestCompareJoints:
    """Unit tests for the joint comparison utility."""

    def test_perfect_match(self) -> None:
        joints = {"nose": (0.5, 0.3), "leftHip": (0.3, 0.7)}
        errors = compare_joints(joints, joints)
        assert all(e.euclidean_distance == 0.0 for e in errors)

    def test_missing_prediction(self) -> None:
        predicted: dict[str, tuple[float, float]] = {}
        reference = {"nose": (0.5, 0.3)}
        errors = compare_joints(predicted, reference)
        assert len(errors) == 1
        assert errors[0].predicted is None
        assert errors[0].euclidean_distance == float("inf")

    def test_known_distance(self) -> None:
        predicted = {"nose": (0.0, 0.0)}
        reference = {"nose": (0.3, 0.4)}
        errors = compare_joints(predicted, reference)
        assert abs(errors[0].euclidean_distance - 0.5) < 1e-6  # 3-4-5 triangle

    def test_extra_predicted_joints_ignored(self) -> None:
        predicted = {"nose": (0.5, 0.3), "extra": (0.1, 0.1)}
        reference = {"nose": (0.5, 0.3)}
        errors = compare_joints(predicted, reference)
        assert len(errors) == 1  # Only reference joints matter
