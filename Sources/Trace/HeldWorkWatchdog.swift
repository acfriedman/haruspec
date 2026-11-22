import Foundation
import HaruspecCore

/// Fails a capture that waits on its own held work, with a message, instead of hanging it.
///
/// Held work runs only at the capture's settle points and its drain, inside a `sync`, and while a
/// derived operation waits for a completion block. Anything that waits for held work some other way
/// waits forever: an operation awaiting a continuation that queued work resumes, a semaphore that
/// queued work signals, a held task awaiting work queued behind it. Each is fine in production, and
/// each would stall the capture with no word of why.
///
/// The watchdog watches one region of a capture at a time (an operation, a settle step, the drain).
/// When the region hasn't returned, work is held, and nothing has moved for ``stallLimit`` (no event
/// recorded, no held item taken), it calls ``onStall`` with a message naming the region, the held work,
/// and the shapes that cause it. The default traps.
public enum HeldWorkWatchdog {
    /// Seconds a region may hold work without progress before the watchdog calls ``onStall``.
    @TaskLocal public static var stallLimit: TimeInterval = 10

    /// What the watchdog does with a stall's message; trapping with it by default. Tests bind a handler
    /// that records the message and unsticks the capture.
    @TaskLocal public static var onStall: @Sendable (String) -> Void = { preconditionFailure($0) }

    /// Runs `body`, the capture's `region`, watching it for a stall on held work.
    ///
    /// - Parameters:
    ///   - region: What the capture is running, as the message names it: `operation 'fetch'`.
    ///   - backlog: The capture's held work.
    ///   - recorder: The capture's recorder, whose events count as progress.
    ///   - isolation: The caller's isolation, which `body` keeps.
    ///   - body: The region.
    /// - Returns: What `body` returns.
    public static func watching<Result>(
        _ region: String,
        backlog: WorkBacklog,
        recorder: TraceRecorder,
        isolation _: isolated (any Actor)? = #isolation,
        _ body: () async -> Result
    ) async -> Result {
        let watch = Watch(region: region, backlog: backlog, recorder: recorder, limit: stallLimit, onStall: onStall)
        Ticker.shared.add(watch)
        defer { Ticker.shared.remove(watch) }
        return await body()
    }

    /// One watched region and the progress it has made, sampled only on the ticker's queue.
    private final class Watch: @unchecked Sendable {
        let region: String
        let backlog: WorkBacklog
        let recorder: TraceRecorder
        let limit: TimeInterval
        let onStall: @Sendable (String) -> Void
        var lastProgress = -1
        var lastChange = Date()
        var fired = false

        init(
            region: String,
            backlog: WorkBacklog,
            recorder: TraceRecorder,
            limit: TimeInterval,
            onStall: @escaping @Sendable (String) -> Void
        ) {
            self.region = region
            self.backlog = backlog
            self.recorder = recorder
            self.limit = limit
            self.onStall = onStall
        }

        /// Samples progress, calling ``onStall`` once the region has stalled on held work.
        ///
        /// - Parameter now: The tick's wall-clock time.
        func tick(at now: Date) {
            guard !fired else { return }
            let progress = recorder.eventCount + backlog.itemsTaken
            if progress != lastProgress {
                lastProgress = progress
                lastChange = now
                return
            }
            let stalled = now.timeIntervalSince(lastChange)
            guard stalled >= limit, backlog.pendingCount > 0 else { return }
            fired = true
            onStall(HeldWorkWatchdog.message(region: region, held: backlog.heldSummary(), seconds: stalled))
        }
    }

    /// Returns the message for a stalled region.
    ///
    /// - Parameters:
    ///   - region: The region that stalled.
    ///   - held: The held work, summarized.
    ///   - seconds: How long it went without progress.
    /// - Returns: The message: what stalled, on what, why, and what to do.
    static func message(region: String, held: String, seconds: TimeInterval) -> String {
        """
        The capture's \(region) has waited \(Int(seconds.rounded())) seconds, with nothing recorded and \
        no held work run, while the capture holds \(held).

        The capture runs held work only when an operation returns (at settle points and the drain), \
        inside a sync, and while a derived operation waits for a completion block. Code that waits for \
        held work any other way waits forever. The usual shapes:
            an operation awaiting a continuation that queued work resumes:
                withCheckedContinuation { c in queue.async { c.resume() } }
            a semaphore or group wait on work handed to a queue
            a held task awaiting work queued after it

        Each runs fine in production; Haruspec can't capture it yet. Check the callback API the wait \
        wraps instead (a derived operation waits for a completion block by running held work), or move \
        the wait out of the operation so the work lands at the next settle point.
        """
    }

    /// The one timer every watched region shares, so entering a region costs a locked insertion, not a
    /// timer. It stops itself on the first tick with nothing to watch, so back-to-back regions keep it.
    private final class Ticker: @unchecked Sendable {
        static let shared = Ticker()

        private let queue = DispatchQueue(label: "haruspec.held-work-watchdog")
        private let lock = NSLock()
        private var watches: [ObjectIdentifier: Watch] = [:]
        private var timer: DispatchSourceTimer?

        func add(_ watch: Watch) {
            lock.lock(); defer { lock.unlock() }
            watches[ObjectIdentifier(watch)] = watch
            guard timer == nil else { return }
            let interval = max(0.01, min(0.25, watch.limit / 4))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [self] in tick() }
            timer.resume()
            self.timer = timer
        }

        /// Samples every watched region, or stops when there is none. Runs on `queue`.
        private func tick() {
            lock.lock()
            let current = Array(watches.values)
            if current.isEmpty {
                timer?.cancel()
                timer = nil
            }
            lock.unlock()
            let now = Date()
            for watch in current {
                watch.tick(at: now)
            }
        }

        func remove(_ watch: Watch) {
            lock.lock(); defer { lock.unlock() }
            watches[ObjectIdentifier(watch)] = nil
        }
    }
}
