import CoreMedia

nonisolated enum CaptureConstants {
    static let captureFPS: Double = 120
    static let poseSubsamplingRate: Int = 8
    static let bufferDuration: TimeInterval = 10
    static let segmentRotationInterval: TimeInterval = 7
    static let segmentOverlapDuration: TimeInterval = 1

    // Clip extraction
    static let clipPreRollDuration: TimeInterval = 3.0
    static let clipPostRollDuration: TimeInterval = 0.5
    static let clipPostLandingWait: TimeInterval = 0.5
    static let defaultPlaybackRate: Float = 0.5
}
