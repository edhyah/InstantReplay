# InstantReplay

## Notes

- Only works in landscape mode

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
      "takeoff": 3.03,
      "peak": 3.41,
      "landing": 3.8
    }
  ]
}
```

## Project Structure

```
Shared/Detection/          # Detection algorithms (compiled into both targets)
InstantReplay/Detection/   # iOS-only (Vision framework, camera pipeline)
InstantReplayTests/        # iOS pose capture tests
InstantReplayMacTests/     # macOS algorithm tests
```
