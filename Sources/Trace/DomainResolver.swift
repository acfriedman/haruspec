import Dispatch
import Foundation
import HaruspecCore

/// Resolves the `ConcurrencyDomain` an event was recorded on.
///
/// There is no single runtime "what am I isolated to?" accessor, so this is a ladder:
///
/// 1. **`#isolation`**, supplied by the caller as a defaulted argument, so it resolves *at the
///    recording call site* to the enclosing isolation. It names `MainActor.shared` or an actor
///    instance, and is `nil` for every nonisolated context.
/// 2. **The scheduling seam the work was handed to.** Held work runs on the capture's draining task,
///    but it ran *as* the queue the subject handed it to, and ``WorkBacklog`` binds that domain
///    around it — `main`, or the stamped protocol's queue with its declared discipline.
/// 3. **An app-owned dispatch queue label** (`com.emporium.checkout`): a raw queue the subject made
///    itself, nominal by construction. It is read as serial, the strict direction, because nothing
///    stated otherwise. A subject reaching one is outside the controlled seams, and the audit's
///    dispatch rule names it.
///
/// Order matters — an actor scheduled onto the cooperative pool reports the pool's label, so asking
/// the label first would erase it.
///
/// Anything that names none of these is `.ambient` — the code declares no isolation of its own; see
/// `ConcurrencyDomain.ambient`.
enum DomainResolver {
    /// Queues Apple owns: the cooperative pool, the main queue, and the rest of the `com.apple.*`
    /// namespace. A subject never *declares* one of these as its own domain — landing on one says
    /// where the caller was, not what the code is.
    private static let systemQueuePrefix = "com.apple."

    /// Resolves the current domain. `instanceID` assigns the symbolic id for an actor instance, and is
    /// the recorder's existing subject numbering — so an actor that is also a traced subject keeps one
    /// identity across both.
    static func resolve(isolation: (any Actor)?, instanceID: (AnyObject) -> Int) -> ConcurrencyDomain {
        if let isolation {
            if isolation === MainActor.shared {
                return .main
            }
            return .actor(String(describing: type(of: isolation)), instance: instanceID(isolation))
        }
        if let entered = WorkBacklog.enteredDomain {
            return entered
        }
        let label = currentQueueLabel()
        if !label.isEmpty, !label.hasPrefix(systemQueuePrefix) {
            return .queue(label, serial: true)
        }
        return .ambient
    }

    /// The label of the queue currently executing, or empty when there is none.
    ///
    /// `dispatch_get_current_queue` is deprecated and unsound to compare against other queues, but
    /// reading the *label* of the running queue is exactly the narrow use it remains valid for — this
    /// never treats the result as a queue reference.
    ///
    /// Foundation decorates an `OperationQueue`'s underlying label with a QoS suffix —
    /// `com.emporium.delivery (QOS: UNSPECIFIED)` — which is scheduling detail, not identity. It is
    /// stripped so the domain matches the name the code declared and anything an
    /// author would write in an `Intent` declaration.
    private static func currentQueueLabel() -> String {
        let label = String(cString: __dispatch_queue_get_label(nil))
        guard let suffix = label.range(of: " (QOS:") else {
            return label
        }
        return String(label[..<suffix.lowerBound])
    }
}
