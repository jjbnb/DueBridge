import Foundation
import Combine

/// One timer owned by the window lifecycle, observed only by deadline labels.
@MainActor
final class PreviewClock: ObservableObject {
    @Published private(set) var now: Date
    private(set) var refreshCount = 0
    private var timer: Timer?
    private let interval: TimeInterval
    private let currentDate: () -> Date
    var isRunning: Bool { timer != nil }

    init(interval: TimeInterval = 60, currentDate: @escaping () -> Date = Date.init) {
        precondition(interval > 0)
        self.interval = interval
        self.currentDate = currentDate
        self.now = currentDate()
    }
    func setRunning(_ shouldRun: Bool) {
        if shouldRun { start() } else { stop() }
    }
    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // This timer is installed only on the main run loop.
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    private func refresh() {
        now = currentDate()
        refreshCount += 1
    }
    deinit { timer?.invalidate() }
}
