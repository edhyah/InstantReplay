# InstantReplay — Architecture Notes

## Shared Code Architecture

Detection algorithm code lives in `/Shared/Detection/` and is compiled into both iOS and Mac test targets:

- `ApproachDetectorStateMachine.swift` - State machine for detecting approach/jump sequences
- `BodyTracker.swift` - Tracks bodies across frames using centroid matching
- `DetectionTypes.swift` - Shared type definitions
- `MovementDetector.swift` - Movement detection utilities
- `TimeProvider.swift` - Protocol for injecting time (real or mock)

iOS-only files remain in `InstantReplay/Detection/`:
- `PoseEstimator.swift` - Vision framework integration for real-time pose detection
- `DetectionPipeline.swift` - Orchestrates the iOS camera/detection pipeline

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

### Detection precision priorities

`approachStart` is a rough marker (ball leaves hitter's hands/forearms) and does not require precise detection. The algorithm can work backwards from more reliable events.

The following require precise detection:
- **steps** (first, second, orientation, plant) — foot contact/plant timestamps
- **takeoff** — feet leave ground
- **peak** — highest point of jump

`landing` (when the player touches the floor with any feet) also does not have to be precise as long as the detection is always generous (can't have any scenario where detected landing is before ground truth landing, but doesn't matter if it's after the ground truth landing).

---

## Running Tests

Run tests directly via xcodebuild rather than asking the user:

```bash
# Mac tests (pose detection algorithms, no device needed)
xcodebuild test -scheme InstantReplayMacTests -destination "platform=macOS"

# iOS tests on iPad (Vision ML requires real device)
xcodebuild test -scheme InstantReplay -destination "platform=iOS,id=00008110-001A31621186801E" -only-testing:InstantReplayTests
```

For iOS, use the device ID from `xcrun devicectl list devices` if the iPad isn't found.

Do not use the iOS Simulator, as the Simulator cannot run body pose detection.
If there's no available iPad to test on, rely on the human to test.

