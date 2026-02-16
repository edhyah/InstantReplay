import CoreGraphics
import Vision

struct TrackedBody: Sendable {
    let id: Int
    let centroid: CGPoint
    let centroidHistory: [CGPoint]
    let jointPoints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    let horizontalVelocity: CGFloat
    let verticalVelocity: CGFloat
    let age: Int
}

struct BodyTrackingResult: Sendable {
    let trackedBodies: [TrackedBody]
    let dominantMoverID: Int?
}

final class BodyTracker: Sendable {
    private nonisolated(unsafe) var bodies: [MutableTrackedBody] = []
    private nonisolated(unsafe) var nextID: Int = 0

    private let maxMatchDistance: CGFloat = 0.15
    private let maxAge: Int = 20
    private let historyLength: Int = 5
    private let velocityWindow: Int = 3

    func update(with observations: [BodyObservation]) -> BodyTrackingResult {
        var newCentroids: [(index: Int, centroid: CGPoint, observation: BodyObservation)] = []
        for (i, obs) in observations.enumerated() {
            newCentroids.append((index: i, centroid: obs.torsoCentroid, observation: obs))
        }

        var matched = Set<Int>()
        var matchedObservationIndices = Set<Int>()

        // Greedy nearest-neighbor matching
        var pairs: [(bodyIdx: Int, obsIdx: Int, distance: CGFloat)] = []
        for (bi, body) in bodies.enumerated() {
            for (oi, entry) in newCentroids.enumerated() {
                let dist = hypot(body.centroid.x - entry.centroid.x, body.centroid.y - entry.centroid.y)
                if dist < maxMatchDistance {
                    pairs.append((bodyIdx: bi, obsIdx: oi, distance: dist))
                }
            }
        }
        pairs.sort { $0.distance < $1.distance }

        for pair in pairs {
            if matched.contains(pair.bodyIdx) || matchedObservationIndices.contains(pair.obsIdx) {
                continue
            }
            matched.insert(pair.bodyIdx)
            matchedObservationIndices.insert(pair.obsIdx)

            let entry = newCentroids[pair.obsIdx]
            let body = bodies[pair.bodyIdx]
            body.centroid = entry.centroid
            body.centroidHistory.append(entry.centroid)
            if body.centroidHistory.count > historyLength {
                body.centroidHistory.removeFirst(body.centroidHistory.count - historyLength)
            }
            body.latestObservation = entry.observation
            body.age = 0
        }

        // Create new bodies for unmatched observations
        for (oi, entry) in newCentroids.enumerated() {
            if matchedObservationIndices.contains(oi) { continue }
            let body = MutableTrackedBody(
                id: nextID,
                centroid: entry.centroid,
                centroidHistory: [entry.centroid],
                latestObservation: entry.observation,
                age: 0
            )
            nextID += 1
            bodies.append(body)
        }

        // Age unmatched existing bodies
        for (bi, body) in bodies.enumerated() {
            if !matched.contains(bi) {
                body.age += 1
            }
        }

        // Remove stale bodies
        bodies.removeAll { $0.age > maxAge }

        // Compute velocities and build results
        let poseInterval = 1.0 / (CaptureConstants.captureFPS / Double(CaptureConstants.poseSubsamplingRate))

        var trackedBodies: [TrackedBody] = []
        for body in bodies {
            let hVel: CGFloat
            let vVel: CGFloat

            let history = body.centroidHistory
            if history.count >= 2 {
                let window = min(velocityWindow, history.count - 1)
                let current = history[history.count - 1]
                let previous = history[history.count - 1 - window]
                let dt = CGFloat(window) * CGFloat(poseInterval)
                hVel = (current.x - previous.x) / dt
                vVel = (current.y - previous.y) / dt
            } else {
                hVel = 0
                vVel = 0
            }

            trackedBodies.append(TrackedBody(
                id: body.id,
                centroid: body.centroid,
                centroidHistory: body.centroidHistory,
                jointPoints: body.latestObservation.jointPoints,
                horizontalVelocity: hVel,
                verticalVelocity: vVel,
                age: body.age
            ))
        }

        // Dominant mover: highest absolute horizontal velocity
        let dominantID = trackedBodies
            .filter { $0.centroidHistory.count >= 2 }
            .max(by: { abs($0.horizontalVelocity) < abs($1.horizontalVelocity) })?
            .id

        return BodyTrackingResult(trackedBodies: trackedBodies, dominantMoverID: dominantID)
    }

    func reset() {
        bodies.removeAll()
        nextID = 0
    }
}

private final class MutableTrackedBody {
    let id: Int
    var centroid: CGPoint
    var centroidHistory: [CGPoint]
    var latestObservation: BodyObservation
    var age: Int

    init(id: Int, centroid: CGPoint, centroidHistory: [CGPoint], latestObservation: BodyObservation, age: Int) {
        self.id = id
        self.centroid = centroid
        self.centroidHistory = centroidHistory
        self.latestObservation = latestObservation
        self.age = age
    }
}
