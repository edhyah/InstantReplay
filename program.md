# InstantReplay Detection Program

## Core Mission

Autonomously iterate on detection algorithms until all Mac tests pass. The system operates using red/green TDD: run tests, see failures, fix code, repeat until green.

**You have complete freedom to use ANY approach.** There are no constraints on algorithm choice, code structure, or implementation strategy. The only measure of success is: do the tests pass? Everything else is negotiable.

## Setup Phase

1. **Branch setup**: Work on a feature branch (e.g., `step-detection`) or the current branch.

2. **Context acquisition**: Review these files before starting:
   - `CLAUDE.md` - Architecture notes and constraints
   - `Shared/Detection/*.swift` - Editable detection algorithms
   - `InstantReplayMacTests/Utilities/ReplayDetectionRunner.swift` - Test harness (may need edits for new features)
   - `InstantReplayMacTests/StepDetectionTests.swift` - Step detection tests (read-only during iteration)
   - `InstantReplayMacTests/Resources/*.json` - Ground truth labels (read-only)

3. **Baseline test run**: Run tests to establish current state:
   ```bash
   timeout 60 xcodebuild test -scheme InstantReplayMacTests -destination "platform=macOS" 2>&1
   ```
   Tests should complete in under 30 seconds. If they hang, kill and investigate.

## Operational Constraints

**Modifiable elements**:
- `Shared/Detection/*.swift` - Detection algorithms, state machine, thresholds
- `InstantReplayMacTests/Utilities/ReplayDetectionRunner.swift` - Test runner (to wire up new detection)
- New files in `Shared/Detection/` if needed for step detection

**Fixed elements** (do not modify during iteration):
- `InstantReplayMacTests/StepDetectionTests.swift` - Test expectations
- `InstantReplayMacTests/Resources/*.json` - Ground truth labels
- Test tolerances defined in test files

**Constraints from CLAUDE.md**:
- Velocities are normalized image coordinates per second (0-2 range typical)
- Y coordinates are flipped (Vision bottom-left → UIKit top-left)
- Side-view camera: left/right body parts overlap
- Detection must be precise for: steps, takeoff, peak
- Detection can be approximate for: approachStart, landing

## Design Philosophy

1. **Complete algorithmic freedom**: You have full authority to try ANY approach:
   - Rewrite detection from scratch if needed
   - Try entirely different algorithms (velocity-based, position-based, ML-inspired, signal processing, etc.)
   - Delete existing code that isn't working
   - Change the architecture completely
   - Add new files, remove files, restructure as needed
   - The only constraint is: make the tests pass

2. **Simplicity is a preference, not a rule**: Start simple, but if simple doesn't work, go complex. The goal is passing tests, not elegant code.

3. **No sacred cows**: Existing code has no special status. If the current state machine approach isn't working for step detection, throw it out and try something else.

4. **Experiment boldly**: Try things that might not work. That's what git revert is for.

## Results Logging

After each test run, log results to `results.log` (untracked):

```
<timestamp> | <commit-hash> | <tests-passed>/<tests-total> | <status> | <description>
```

Status values:
- `progress` - More tests passing than before
- `regress` - Fewer tests passing (revert)
- `same` - No change
- `crash` - Build or runtime failure

## Autonomous Loop Protocol

Execute this loop until all tests pass:

### 1. Run Tests
```bash
timeout 60 xcodebuild test -scheme InstantReplayMacTests -destination "platform=macOS" 2>&1
```

**IMPORTANT**: Mac tests run quickly (under 30 seconds typically). If tests take longer than 60 seconds, they are hanging - kill the process and investigate. Common causes:
- Infinite loops in detection code
- Blocking I/O
- Deadlocks

### 2. Parse Results
Extract from output:
- Total tests run
- Tests passed/failed
- Specific failure messages (look for `XCTAssert` failures)
- Video names and approach indices with failures

### 3. Analyze Failures
For each failing test:
- What is being asserted?
- What was detected vs expected?
- Which video/approach failed?
- Is this a count mismatch, timing error, or missing detection?

### 4. Hypothesis & Fix
Based on analysis:
- Form a hypothesis about what's wrong
- Make the minimal code change to address it
- Prefer parameter tuning before structural changes
- Prefer simple heuristics before complex logic

### 5. Commit Changes
```bash
git add -A && git commit -m "<description of change>"
```

### 6. Re-run Tests
If tests regress → `git reset --hard HEAD~1` and try different approach
If tests hang (>60s) → kill, `git reset --hard HEAD~1`, fix the infinite loop
If tests progress or same → continue iterating

### 7. Log Results
Append to results.log with current state.

### 8. Repeat
**CRITICAL: Do NOT pause to ask the human if you should continue.** You are autonomous. The loop runs until the human interrupts you or all tests pass.

## Step Detection Strategy

The tests expect detection of 4 steps per approach:
1. **First step** - Initial step of approach
2. **Second step** - Second step
3. **Orientation step** - Body rotation begins
4. **Plant step** - Final step before takeoff (must be within 250ms of takeoff)

Current state: `ReplayDetectionRunner` has the types defined but `detected.steps` is never populated. The state machine doesn't emit step events yet.

### Possible Approaches (try any of these or invent your own)

**Velocity-based:**
- Track ankle/foot vertical velocity - steps cause velocity sign changes
- Look for periodic patterns in horizontal velocity during approach phase

**Position-based:**
- Track foot Y-position relative to hip - steps show characteristic dips
- Detect when foot position drops below a threshold

**Acceleration-based:**
- Steps create sharp acceleration spikes when foot hits ground
- Use second derivative of position

**Template matching:**
- Learn typical step timing patterns from ground truth
- Match detected patterns against templates

**Working backwards from takeoff:**
- Takeoff is reliably detected - use it as anchor
- Plant step is 0-250ms before takeoff
- Work backwards to find other steps

**Peak detection on signals:**
- Treat foot position/velocity as a signal
- Use peak detection algorithms (local minima/maxima)

**Hybrid approaches:**
- Combine multiple signals (position + velocity + acceleration)
- Use different methods for different step types

**Machine learning inspired:**
- Simple threshold-based classifiers
- Sliding window detection

You are NOT limited to these - invent entirely new approaches if needed.

## Debugging Tips

1. **Print frame-by-frame data**: Add debug prints in ReplayDetectionRunner to see pose data
2. **Visualize velocity curves**: Log ankle velocities to understand step patterns
3. **Work backwards from takeoff**: The takeoff timestamp is reliable - use it as anchor
4. **Check one video first**: Focus on getting one video passing before generalizing

## Success Criteria

All tests in `InstantReplayMacTests` pass:
- `ReplayDetectionTests` - Approach detection (likely already passing)
- `StepDetectionTests` - Step detection within tolerance
- `ThresholdTuningTests` - Parameter validation

When all tests pass, stop the loop and report success.
