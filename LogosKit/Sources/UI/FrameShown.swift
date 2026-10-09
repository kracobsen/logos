import QuartzCore

/// Waiting for the screen: work that must not hold up a frame (the launch sync and file checks, restoring the
/// last-played Book) waits until the frame being prepared now has been shown, and the return-from-background
/// signpost ends there.
///
/// `Task.yield()` only lets other main-actor work run; it says nothing about rendering. A display link fires on each
/// screen refresh, so by its second tick the frame committed when it started is on screen.
enum FrameShown {
    /// Returns once the frame being prepared now is on screen. While the app isn't visible, the display link doesn't
    /// tick, so this waits until it is.
    static func next() async {
        await withCheckedContinuation { continuation in
            FrameTicker(ticks: 2) { continuation.resume() }.start()
        }
    }
}

/// Counts display refreshes, then calls `done` once. The display link keeps it alive until then.
private final class FrameTicker: NSObject {
    private var ticksLeft: Int
    private let done: () -> Void
    private var link: CADisplayLink?

    init(ticks: Int, done: @escaping () -> Void) {
        ticksLeft = ticks
        self.done = done
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        ticksLeft -= 1
        guard ticksLeft <= 0 else { return }
        link?.invalidate()
        link = nil
        done()
    }
}
