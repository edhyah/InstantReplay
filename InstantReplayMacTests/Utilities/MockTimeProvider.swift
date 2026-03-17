import Foundation

final class MockTimeProvider: TimeProvider, @unchecked Sendable {
    private var currentTimeValue: CFTimeInterval = 0

    func currentTime() -> CFTimeInterval {
        currentTimeValue
    }

    func setTime(_ time: CFTimeInterval) {
        currentTimeValue = time
    }

    func advance(by interval: CFTimeInterval) {
        currentTimeValue += interval
    }
}
