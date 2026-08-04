import QuartzCore
import SwiftUI

/// Drives the ink current. Accumulates a phase at 60fps (`phase += dt·speed`)
/// so motion is always monotonic — the river only ever flows one way, no matter
/// how the speed changes. `targetSpeed` is smoothed toward, so voice/state can
/// nudge the current faster or slower without any jump or reversal.
final class FlowClock: ObservableObject {
    @Published var phase: Double = 0
    var targetSpeed: Double = 0.014

    private var speed: Double = 0.014
    private var timer: Timer?
    private var last = CACurrentMediaTime()

    func start() {
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            let dt = min(0.05, now - self.last)
            self.last = now
            // ease speed toward target (slow → flow reacts gently, unlike the light)
            self.speed += (self.targetSpeed - self.speed) * min(1, dt * 2)
            self.phase -= self.speed * dt
        }
        RunLoop.main.add(t, forMode: .common)   // keep flowing during interaction
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }
    deinit { stop() }
}
