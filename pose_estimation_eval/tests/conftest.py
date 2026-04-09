"""Shared pytest fixtures for pose estimation model comparison tests."""

from __future__ import annotations

from pathlib import Path

import pytest

# Path to the existing Mac test resources (ground truth + Apple Vision poses)
_MAC_RESOURCES = Path(__file__).resolve().parents[2] / "InstantReplayMacTests" / "Resources"


def _discover_videos() -> list[str]:
    """Return base names of videos that have both .poses.json and .json files."""
    if not _MAC_RESOURCES.is_dir():
        return []
    pose_files = sorted(_MAC_RESOURCES.glob("*.poses.json"))
    names: list[str] = []
    for pf in pose_files:
        base = pf.name.removesuffix(".poses.json")
        gt = _MAC_RESOURCES / f"{base}.json"
        if gt.exists():
            names.append(base)
    return names


VIDEO_NAMES: list[str] = _discover_videos()


@pytest.fixture(params=VIDEO_NAMES, ids=VIDEO_NAMES)
def video_name(request: pytest.FixtureRequest) -> str:
    """Parametrised fixture yielding each available video base name."""
    return request.param


@pytest.fixture
def resources_dir() -> Path:
    """Path to InstantReplayMacTests/Resources."""
    return _MAC_RESOURCES
