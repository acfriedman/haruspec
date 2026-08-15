import Foundation
import HaruspecCore

/// An `OperationQueue` that carries capture across the hop it schedules — the operation-queue
/// counterpart to the GCD seam, reached by **injection** rather than by a seam.
///
/// The distinction is the one that decides every mechanism here: `dispatch_async` is a C function
/// nobody hands in, so it needs a seam. An operation queue is an *object*, so a subject can be given
/// one — and where injection is possible it is the answer, even though the work done inside is the
/// same wrapping the seam performs.
///
/// That does mean a subject holding a privately-constructed queue has to be made injectable first.
/// There is no way around that dilemma and no attempt to invent one: the alternative is swizzling a
/// framework class, which this engine does not do for observation.
public final class RecordingOperationQueue: OperationQueue, @unchecked Sendable {
    /// Blocks are wrapped exactly as a dispatched one is: the recorder and the spawning call are read
    /// at the enqueue, and the work is counted so `quiesce()` waits for it.
    override public func addOperation(_ block: @escaping @Sendable () -> Void) {
        // `name` is the nominal identity; the underlying label carries an object address. The
        // discipline is read here too — the queue object is the one party that knows its own width.
        super.addOperation(DispatchSeam.seamWrap(block, serial: maxConcurrentOperationCount == 1))
    }
}
