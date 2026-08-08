import Foundation
import HaruspecCore

/// The Swift half of the GCD **preprocessing seam** (`Sources/DispatchSeam/haruspec_dispatch.h`).
///
/// Three things happen at an enqueue, and only at an enqueue:
///  - the ambient recorder is still reachable (the enqueueing thread is inside the capture window),
///  - the work becomes outstanding, and stays so until the block finishes, and
///  - the causal link between the enqueueing event and the spawned work exists.
///
/// The C shim calls the three `@_cdecl` entry points below around each wrapped block.
public enum DispatchSeam {
    // `NSLock` rather than `Synchronization.Mutex`, matching `TraceRecorder` — the package still
    // supports macOS 13, where `Mutex` does not exist.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var inFlight = 0
    private nonisolated(unsafe) static var waiters: [DispatchSemaphore] = []

    /// Wait until every block enqueued through the seam has finished, or `timeout` elapses.
    ///
    /// This is the exact form of the question a trace snapshot needs to ask. "Has this queue gone
    /// idle?" has no general answer; "has the work I know about finished?" does, because the seam
    /// counted it out.
    ///
    /// Suspending rather than blocking is not a preference — it is the only correct option. Outstanding
    /// work is routinely a hop *back* to the main queue (the callback pyramid's second leg), so blocking
    /// the main thread deadlocks against the work being waited on, and pumping the run loop instead
    /// re-enters the main actor, which Swift 6 traps. Awaiting frees the thread with neither problem.
    ///
    /// Returns `false` on timeout — a caller that snapshots anyway is knowingly taking a racy trace,
    /// which the harness should decide loudly rather than by default.
    @discardableResult
    public static func quiesce(timeout: TimeInterval = 5) async -> Bool {
        // Polled rather than continuation-signalled: racing a continuation against a timeout needs
        // more machinery than a harness-speed wait justifies, and the poll suspends, so it costs a
        // thread nothing.
        let deadline = Date().addingTimeInterval(timeout)
        while outstanding > 0 {
            if Date() >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }

    /// The blocking form, for a caller that is definitely **not** on a thread the outstanding work
    /// needs. Prefer `quiesce(timeout:)`; this deadlocks if any pending block targets the caller's
    /// queue, which for the main queue is the common case rather than the exotic one.
    @discardableResult
    public static func quiesceBlocking(timeout: TimeInterval = 5) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        if inFlight == 0 {
            lock.unlock()
            return true
        }
        waiters.append(semaphore)
        lock.unlock()
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    /// Outstanding blocks enqueued through the seam. Diagnostic — a spec that times out in `quiesce`
    /// wants to say how much work it gave up on.
    public static var outstanding: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    /// Internal accessors the Swift-side overloads reach; the C entry points use `acquire`/`finish`.
    static func acquireForSwift() -> TraceRecorder? {
        acquire()
    }

    static func finishForSwift() {
        finish()
    }

    fileprivate static func acquire() -> TraceRecorder? {
        guard let recorder = TraceContext.active else { return nil }
        lock.lock(); defer { lock.unlock() }
        inFlight += 1
        return recorder
    }

    fileprivate static func finish() {
        lock.lock()
        inFlight -= 1
        let released = inFlight == 0 ? waiters : []
        if inFlight == 0 {
            waiters.removeAll()
        }
        lock.unlock()
        released.forEach { $0.signal() }
    }
}

// MARK: - C entry points

/// Returns a retained opaque handle to the ambient recorder, or `nil` when no capture is active — in
/// which case the shim passes the block through untouched and nothing is counted.
@_cdecl("haruspec_context_acquire")
public func haruspecContextAcquire() -> UnsafeMutableRawPointer? {
    guard let recorder = DispatchSeam.acquire() else { return nil }
    return Unmanaged.passRetained(recorder).toOpaque()
}

/// Runs the enqueued block with the captured recorder rebound, so `@Traced` code inside it finds the
/// same recorder the enqueueing thread had. This is the whole of the reachability fix.
@_cdecl("haruspec_context_run")
public func haruspecContextRun(
    _ context: UnsafeMutableRawPointer,
    _ block: @convention(block) () -> Void
) {
    let recorder = Unmanaged<TraceRecorder>.fromOpaque(context).takeUnretainedValue()
    TraceContext.withThreadRecorder(recorder) { block() }
}

/// Balances `acquire`: releases the handle and marks the work no longer outstanding.
@_cdecl("haruspec_context_release")
public func haruspecContextRelease(_ context: UnsafeMutableRawPointer) {
    Unmanaged<TraceRecorder>.fromOpaque(context).release()
    DispatchSeam.finish()
}
