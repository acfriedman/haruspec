import Foundation
import HaruspecCore

/// A queue that holds work in the capture's backlog, and how a spec creates one with a name of its own.
///
/// Read only for the message that asks two queues on one domain to be named apart, so it can show the
/// spelling for the kind of queue the spec made.
public protocol QueueNaming: AnyObject {
    /// What the spec calls this kind of queue, as in `DoubleSerialQueue` or `HeldScheduler`.
    var queueKind: String { get }

    /// Returns the spelling that creates this kind of queue named `label`.
    ///
    /// - Parameter label: The name to show, as in `"io"`.
    /// - Returns: Swift, as in `context.double(DoubleSerialQueue.self, label: "io")`.
    func naming(_ label: String) -> String
}

public extension QueueNaming {
    // gloss:exempt default for QueueNaming.queueKind, documented on the protocol
    var queueKind: String {
        String(describing: type(of: self))
    }
}

/// The queue each domain belongs to in one capture.
///
/// A domain is a queue's label and discipline, nothing more, so two queues that share both record as
/// one: their order against each other, which is noise, would read as a guarantee, work moved from one
/// to the other would go unseen, and order across them would be compared. The capture refuses that
/// rather than guess. `main` is exempt: every main-queue seam is the one main queue.
struct DomainOwners {
    private var owners: [ConcurrencyDomain: AnyObject] = [:]

    /// Records that `queue` owns `domain`.
    ///
    /// - Parameters:
    ///   - domain: The domain the queue's work records on.
    ///   - queue: The queue handing work over.
    /// - Returns: `nil` when `queue` owns `domain`, or `domain` is `main`; otherwise the message to trap
    ///   with, naming both queues and how to tell them apart.
    mutating func claim(_ domain: ConcurrencyDomain, for queue: AnyObject) -> String? {
        guard domain != .main else { return nil }
        guard let owner = owners[domain] else {
            owners[domain] = queue
            return nil
        }
        return owner === queue ? nil : Self.conflict(on: domain, between: owner, and: queue)
    }

    /// Records that `queue` owns `domain`, trapping with ``claim(_:for:)``'s message when it can't.
    ///
    /// - Parameters:
    ///   - domain: The domain the queue's work records on.
    ///   - queue: The queue handing work over.
    /// - Precondition: No other queue in this capture records on `domain`.
    mutating func claimOrTrap(_ domain: ConcurrencyDomain, for queue: AnyObject) {
        if let conflict = claim(domain, for: queue) {
            preconditionFailure(conflict)
        }
    }

    /// Returns the message for two queues on `domain`.
    ///
    /// - Parameters:
    ///   - domain: The domain both record on.
    ///   - first: The queue that claimed it first.
    ///   - second: The queue that arrived after.
    /// - Returns: The trap's message: the domain, both queues, why it matters, and the fix.
    static func conflict(on domain: ConcurrencyDomain, between first: AnyObject, and second: AnyObject) -> String {
        """
        Two different queues record as \(domain) in this capture: a \(kind(of: first)) and a \(kind(of: second)).

        Their order against each other is noise, but one domain would read it as a guarantee: work moved \
        from one to the other would go unseen, and order across them would be compared.

        Name each queue where you create it, the same way on both sides of the spec:
            \(naming(first, "io"))
            \(naming(second, "state"))
        """
    }

    private static func kind(of queue: AnyObject) -> String {
        (queue as? QueueNaming)?.queueKind ?? String(describing: type(of: queue))
    }

    private static func naming(_ queue: AnyObject, _ label: String) -> String {
        (queue as? QueueNaming)?.naming(label) ?? "a \(kind(of: queue)) labelled \"\(label)\""
    }
}
