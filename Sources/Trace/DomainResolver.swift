import Dispatch
import Foundation
import HaruspecCore

/// Resolves the `ConcurrencyDomain` an event was recorded on.
///
/// There is no single runtime "what am I isolated to?" accessor, so this is a two-source ladder — the
/// isolating actor first, the dispatch queue's label second:
///
/// 1. **`#isolation`**, supplied by the caller as a defaulted argument, so it resolves *at the
///    recording call site* to the enclosing isolation. It names `MainActor.shared` or an actor
///    instance, and is `nil` for every nonisolated context — detached tasks, task-group children, and
///    all of GCD.
/// 2. **The dispatch queue label**, which covers exactly that remainder and is nominal by
///    construction (`com.emporium.checkout`). It reports the queue even when a `sync` borrows the
///    calling thread, which is the right attribution: the work ran *as* that queue.
///
/// Order matters — an actor scheduled onto the cooperative pool reports the pool's label, so asking
/// the label first would erase it.
///
/// Anything that names neither is `.pool`: interchangeable workers whose identity is a scheduling
/// accident rather than a fact about the behavior.
enum DomainResolver {
    /// The cooperative pool's queue label. Reaching this means Swift concurrency scheduled the work
    /// and no actor isolated it, so there is nothing nominal left to key on.
    private static let cooperativePoolPrefix = "com.apple.root."
    private static let mainQueueLabel = "com.apple.main-thread"

    /// Resolve the current domain. `instanceID` assigns the symbolic id for an actor instance, and is
    /// the recorder's existing subject numbering — so an actor that is also a traced subject keeps one
    /// identity across both.
    static func resolve(isolation: (any Actor)?, instanceID: (AnyObject) -> Int) -> ConcurrencyDomain {
        if let isolation {
            if isolation === MainActor.shared {
                return .main
            }
            return .actor(String(describing: type(of: isolation)), instance: instanceID(isolation))
        }
        let label = currentQueueLabel()
        if label == mainQueueLabel || (label.isEmpty && Thread.isMainThread) {
            return .main
        }
        if label.isEmpty || label.hasPrefix(cooperativePoolPrefix) {
            return .pool
        }
        return .queue(label)
    }

    /// The label of the queue currently executing, or empty when there is none.
    ///
    /// `dispatch_get_current_queue` is deprecated and unsound to compare against other queues, but
    /// reading the *label* of the running queue is exactly the narrow use it remains valid for — this
    /// never treats the result as a queue reference.
    private static func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }
}
