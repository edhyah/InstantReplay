import QuartzCore

protocol TimeProvider: Sendable {
    func currentTime() -> CFTimeInterval
}

final class SystemTimeProvider: TimeProvider, Sendable {
    func currentTime() -> CFTimeInterval {
        CACurrentMediaTime()
    }
}
