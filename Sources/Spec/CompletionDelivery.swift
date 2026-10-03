import Foundation
import HaruspecTrace

/// How a derived op drives a requirement that answers through a completion block: it hands in a block
/// that only signals, and waits for it, so the next op runs after the answer as a caller's would.
///
/// The delivery itself is recorded by the forwarder, not here. The subject's own work is held by its
/// scheduling doubles, so waiting means *running* it: the op steps the capture's ``WorkBacklog`` one
/// item at a time until the block has run. Once nothing held can run and the block has not, nothing
/// will run it, and the op ends. A block that is never called is then visible in the trace as a
/// delivery only the other side made.
public enum CompletionDelivery {
    /// Runs `start` with a signalling block and returns once the block has run, or once no held work
    /// is left that could run it.
    ///
    /// - Parameter start: Calls the requirement, passing the signal as (or inside) its completion
    ///   block. A throw is a request refused up front — the forwarder has recorded it, and the block
    ///   will never run — so the wait ends at once.
    public static func awaited(_ start: (@escaping @Sendable () -> Void) throws -> Void) async {
        let latch = Latch()
        do {
            try start { latch.signal() }
        } catch {
            return
        }
        guard let backlog = WorkBacklog.current else { return }
        var steps = 0
        while !latch.isSignalled, steps < WorkBacklog.stepLimit, await backlog.step(recorder: TraceContext.active) {
            steps += 1
        }
    }

    /// A one-way flag set from whichever thread delivers.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var signalled = false

        var isSignalled: Bool {
            lock.lock(); defer { lock.unlock() }
            return signalled
        }

        func signal() {
            lock.lock(); defer { lock.unlock() }
            signalled = true
        }
    }
}
