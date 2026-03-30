import Foundation

/// Manages timers requested by the C++ core via schedule_timer/cancel_timer callbacks.
final class TimerService: @unchecked Sendable {
    static let shared = TimerService()

    private var timers: [Int32: Timer] = [:]

    private init() {}

    func schedule(seconds: Double, id: Int32) {
        // Cancel existing timer with same ID
        cancel(id: id)

        DispatchQueue.main.async {
            let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                core_on_timer_fired(id)
                self.timers.removeValue(forKey: id)
            }
            self.timers[id] = timer
        }
    }

    func cancel(id: Int32) {
        DispatchQueue.main.async {
            self.timers[id]?.invalidate()
            self.timers.removeValue(forKey: id)
        }
    }
}
