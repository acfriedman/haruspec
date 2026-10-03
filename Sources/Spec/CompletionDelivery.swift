import Foundation
import HaruspecTrace

/// How a derived op drives a requirement that answers through a completion block: it hands in a block
/// that only signals, and waits for it, so the next op runs after the answer as a caller's would.
///
/// The delivery itself is recorded by the forwarder, not here. Waiting is bounded by the work that
/// could still deliver it: once nothing enqueued through the dispatch seam is outstanding and the
/// block has not run, nothing will run it, and the op ends. A block that is never called is then
/// visible in the trace as a delivery only the other side made. Work the seam cannot count (a binary
/// framework's own queues) ends the wait early; its delivery still records whenever it lands.
public enum CompletionDelivery {
    /// The longest an op waits for a completion block while work is still outstanding. It is the
    /// capture drain's patience, so a stuck delivery costs an op no more than the snapshot.
    static let timeout: TimeInterval = 5

    /// Runs `start` with a signalling block and returns once the block has run, or once nothing
    /// outstanding could still run it.
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
        let deadline = Date().addingTimeInterval(timeout)
        while !latch.isSignalled {
            if DispatchSeam.outstanding == 0 || Date() >= deadline {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
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
