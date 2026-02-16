import CoreMedia

nonisolated enum CaptureConstants {
    static let captureFPS: Double = 60
    static let poseSubsamplingRate: Int = 4
    static let bufferDuration: TimeInterval = 15
    static let segmentRotationInterval: TimeInterval = 10
    static let segmentOverlapDuration: TimeInterval = 1
}
