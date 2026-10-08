import Foundation

/// Turns a raw captured trace into a *canonical* one the diff engine can compare deterministically.
///
/// The recorder already handles the nondeterminism of capture itself (pointers → symbolic ids, OS
/// threads → logical threads, wall time → a logical clock). What lives here depends on the declared
/// comparison: dropping ignored event kinds and notification channels, then re-densifying the logical
/// clock. Payload values are never rewritten; a value that varies run to run is an uncontrolled seam.
public enum Canonicalizer {
    /// Returns the canonical form of a whole trace under a comparison.
    ///
    /// - Parameters:
    ///   - trace: The captured trace.
    ///   - comparison: The comparison the trace will be diffed under.
    /// - Returns: The trace without the events `comparison` ignores, its logical clock and spawn
    ///   edges renumbered to stay dense.
    public static func canonicalize(_ trace: Trace, comparison: Comparison) -> Trace {
        let ignoredNotifications = Set(comparison.ignoredNotificationNames)
        var events = trace.events.filter { event in
            if comparison.ignoredKinds.contains(event.kind) {
                return false
            }
            // Opt-out denylist: drop named notification channels (see `ignoredNotificationNames`).
            if event.kind == .notification, ignoredNotifications.contains(event.label) {
                return false
            }
            return true
        }
        // Re-densifying the clock moves every `seq`, and a spawn edge is a `seq` — so the edges are
        // remapped with it. An edge whose cause was filtered out is dropped rather than left pointing
        // at whichever event inherited that number, which would be a fabricated causal claim.
        let renumbered = Dictionary(uniqueKeysWithValues: events.enumerated().map { ($1.seq, $0) })
        for index in events.indices {
            events[index].spawnedBy = events[index].spawnedBy.flatMap { renumbered[$0] }
            events[index].seq = index // re-densify the logical clock after any filtering
        }
        return Trace(
            name: trace.name,
            schemaVersion: trace.schemaVersion,
            events: events
        )
    }
}
