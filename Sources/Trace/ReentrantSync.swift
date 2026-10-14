import Foundation
import HaruspecCore

// A sync onto the serial queue whose work is running deadlocks under Grand Central Dispatch. The
// backlog could run it inline, but that would check a schedule no real run reaches, so it refuses.

extension WorkBacklog {
    /// Returns why a `sync` onto `queue` can't run here, when it is a serial queue's own work syncing
    /// onto that queue.
    ///
    /// - Parameters:
    ///   - queue: The double the sync is handed to.
    ///   - label: The double's label, which names the queue in the message.
    ///   - discipline: How the double's protocol orders its work.
    /// - Returns: The message to trap with; `nil` when the sync can run: outside the queue's own work,
    ///   or onto a concurrent queue, which may sync onto itself.
    ///
    /// GCD deadlocks here: the sync waits for the queue to run its block, and the queue is busy running
    /// the caller. libdispatch crashes it. Running the block inline instead would read a schedule no
    /// real run can reach, so a port that deadlocks in production would read equivalent.
    static func syncRefusal(onto queue: AnyObject, label: String, discipline: ScheduleDiscipline) -> String? {
        guard discipline != .concurrent, let entered, entered.queue == ObjectIdentifier(queue) else {
            return nil
        }
        return """
        A sync onto \(discipline.domain(label: label)) from work already running on that queue.

        Under Grand Central Dispatch this deadlocks: the sync waits for the queue to run its block, and \
        the queue is busy running the caller. libdispatch crashes the app here. Running it inline would \
        check a schedule no real run can reach.

        Read the state directly inside the queue's work, since it already runs there, or hand the read \
        to the queue with async and continue from its block.
        """
    }
}
