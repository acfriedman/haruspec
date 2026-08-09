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
    private static let mainQueueLabel = "com.apple.main-thread"
    /// Queues Apple owns: the cooperative pool, the main queue, and the rest of the `com.apple.*`
    /// namespace. A subject never *declares* one of these as its own domain — landing on one says
    /// where the caller was, not what the code is.
    private static let systemQueuePrefix = "com.apple."

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

        // A queue the subject was genuinely handed work on. The seam marks that entry, because
        // *being* on a queue and *having been dispatched to* one are different facts — the harness is
        // always on some queue, and reading the label unconditionally is how its context leaked in.
        if DispatchSeam.isInsideEnteredQueue {
            if label == mainQueueLabel {
                return .main
            }
            if !label.isEmpty {
                return .queue(label, serial: discipline(for: label))
            }
        }

        // An app-owned queue names itself, so being on one is evidence enough without a marker —
        // this is the `dispatch_sync` path, which the seam deliberately does not wrap.
        if !label.isEmpty, !label.hasPrefix(systemQueuePrefix) {
            return .queue(label, serial: discipline(for: label))
        }

        return .ambient
    }

    /// The queue's ordering discipline: the enqueue site's own answer first (an injected operation
    /// queue knows its width), the creation-seam registry second, **serial** when nothing was seen.
    ///
    /// Serial is the strict default on purpose. It treats the queue's order as a contract, which is
    /// what every queue created with a `NULL` attr actually is — and a concurrent queue that slipped
    /// past both sources fails toward a flapping *reported* order, never toward silently unchecked.
    private static func discipline(for label: String) -> Bool {
        DispatchSeam.enteredQueueSerial ?? DispatchSeam.registeredDiscipline(label: label) ?? true
    }

    /// The label of the queue currently executing, or empty when there is none.
    ///
    /// `dispatch_get_current_queue` is deprecated and unsound to compare against other queues, but
    /// reading the *label* of the running queue is exactly the narrow use it remains valid for — this
    /// never treats the result as a queue reference.
    ///
    /// Foundation decorates an `OperationQueue`'s underlying label with a QoS suffix —
    /// `com.emporium.delivery (QOS: UNSPECIFIED)` — which is scheduling detail, not identity. It is
    /// stripped so the domain matches the name the code declared, the registry key, and anything an
    /// author would write in an `Intent` declaration.
    private static func currentQueueLabel() -> String {
        let label = String(cString: __dispatch_queue_get_label(nil))
        guard let suffix = label.range(of: " (QOS:") else {
            return label
        }
        return String(label[..<suffix.lowerBound])
    }
}
