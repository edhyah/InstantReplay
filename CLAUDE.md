# InstantReplay — Developer Notes

## Test Targets

### InstantReplayTests (iOS, requires device)

Runs on a real iOS device. Contains **PoseCaptureTests** which captures pose data from videos and saves `.poses.json` files for offline algorithm testing.

Workflow: Run `PoseCaptureTests` on device once to generate pose data, then copy output files to `InstantReplayMacTests/Resources/` for fast iteration.

### InstantReplayMacTests (macOS, no simulator)

Runs natively on Mac in ~1 second (vs 2-3+ minutes with iOS simulator). Used for fast iteration on detection algorithms.

```bash
xcodebuild test -scheme InstantReplayMacTests -destination 'platform=macOS'
```

**Architecture:** Contains duplicated copies of detection code (`Shared/`) and test utilities (`Utilities/`) without iOS dependencies. When algorithm changes are finalized, sync them back to `InstantReplay/Detection/`.

**Resources:** Place `.poses.json` and ground truth `.json` files in `Resources/`. Tests auto-discover all pose files in this directory.

---

### Dominant mover color flickers during idle

The dominant mover (cyan skeleton) is recomputed every pose frame based on who currently has the highest absolute horizontal velocity. When the main athlete is standing still between reps, any small movement from another person (setter repositioning, someone walking) takes over the highlight. This is expected and harmless — the state machine (Phase 5) only triggers on sustained approach sequences, not momentary velocity spikes.

### Velocity units are normalized image coordinates per second

All velocities are in the range of ~0-2 units/second, not real-world meters. A value of 0.20 means the centroid moved 20% of the frame width in one second. These values shift with camera distance — thresholds are tuned for ~5m.

### Coordinate system: Vision bottom-left → UIKit top-left

`PoseEstimator` flips Y coordinates (`1.0 - y`) so all downstream code (BodyTracker, SkeletonOverlayView) works in top-left origin normalized coordinates (0-1). Positive vertical velocity means downward movement on screen.

### New bodies can't immediately become dominant mover

A newly created tracked body starts with only 1 centroid history entry. Dominant mover selection requires >= 2 history entries. This prevents a person entering the frame from instantly hijacking the state machine.

### 20-frame grace period for body tracking

Tracked bodies survive 20 consecutive frames (~1.3s at 15fps) without a matching pose observation before removal. This handles: (1) temporary Vision pose estimation dropouts, (2) two bodies overlapping during a jump (hitter crossing paths with setter at peak height — jump airtime is typically 0.5-0.8s).

### Side-view constraint

The camera is perpendicular to movement. Left and right body parts overlap from this angle. Detection uses aggregate torso centroid (average of available shoulder + hip points) rather than individual left/right joints. PoseEstimator requires at least 2 of the 4 torso joints to produce a centroid.

### Segment overlap prevents dropped frames

RollingBufferManager writes to two AVAssetWriter instances simultaneously for ~1 second during rotation. Both the old and new segment receive frames during the overlap window, ensuring no gaps in the recorded timeline.

