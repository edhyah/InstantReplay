# InstantReplay

Instant replay app for volleyball training. Point your iPad at a player, and the app automatically detects spike approaches and plays them back in slow-motion for immediate technique review.

## How It Works

1. **Pose detection** — Uses Vision framework to track body skeletons in real-time
2. **Approach detection** — State machine identifies the dominant mover and detects approach → jump → landing sequences
3. **Instant replay** — On landing, plays back the jump from a rolling buffer at 0.25x–1.0x speed

## Requirements

- iPad (landscape orientation)
- Camera positioned perpendicular to the approach (side view, ~5m distance)

## Modes

- **Camera** — Live capture and replay
- **Video** — Import pre-recorded videos for analysis

## Testing

This project uses a two-stage testing workflow for fast iteration on detection algorithms.

### Stage 1: Capture Pose Data (iOS Device)

`InstantReplayTests` runs on a real iOS device (not simulator) to extract pose data from videos using the Vision framework.

**Add new videos:** Place `.mov`/`.mp4`/`.m4v` files in `InstantReplayTests/Resources/`

**Run via Xcode:**
1. Connect an iOS device
2. Select the `InstantReplayTests` scheme
3. Run tests with `Cmd+U`

**Run via command line:**
```bash
xcodebuild test -scheme InstantReplayTests -destination 'platform=iOS,name=<YourDeviceName>'
```

**Retrieve output files:**
1. Xcode → Window → Devices and Simulators
2. Select your device → find InstantReplay
3. Click gear icon → Download Container
4. Find `.poses.json` files in Documents folder
5. Copy to `InstantReplayMacTests/Resources/`

### Stage 2: Iterate on Algorithms (macOS)

`InstantReplayMacTests` runs natively on Mac in ~1 second. Place `.poses.json` files and matching ground truth `.json` files in `InstantReplayMacTests/Resources/`.

```bash
xcodebuild test -scheme InstantReplayMacTests -destination 'platform=macOS'
```

**Ground truth format** (e.g., `IMG_1118.json` to pair with `IMG_1118.poses.json`):
```json
{
  "approaches": [
    {
      "approachStart": 2.01,
      "steps": {
        "first": { "timestamp": 2.50, "foot": "left" },
        "second": { "timestamp": 2.70, "foot": "right" },
        "orientation": { "timestamp": 2.85, "foot": "left" },
        "plant": { "timestamp": 2.95, "foot": "right" }
      },
      "takeoff": 3.03,
      "peak": 3.41,
      "landing": 3.8
    }
  ]
}
```

**Labeling guide:**

| Field | What to mark | Precision |
|-------|--------------|-----------|
| `approachStart` | Ball leaves hitter's hands/forearms | Rough (~0.5s) |
| `steps.first` | First foot plant + which foot | Precise (~0.1s) |
| `steps.second` | Second foot plant + which foot | Precise (~0.1s) |
| `steps.orientation` | Third foot plant + which foot | Precise (~0.1s) |
| `steps.plant` | Fourth foot plant before jump + which foot | Precise (~0.1s) |
| `takeoff` | Feet leave ground | Precise (~0.2s) |
| `peak` | Highest point of jump | Precise (~0.2s) |
| `landing` | Feet touch ground | Precise (~0.2s) |

## Project Structure

```
Shared/Detection/          # Detection algorithms (compiled into both targets)
InstantReplay/Detection/   # iOS-only (Vision framework, camera pipeline)
InstantReplayTests/        # iOS pose capture tests
InstantReplayMacTests/     # macOS algorithm tests
```
