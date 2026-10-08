import Foundation

/// Turns a raw captured trace into a *canonical* one the diff engine can compare deterministically.
///
/// The recorder already handles the hardest sources of nondeterminism at capture time (pointers →
/// symbolic ids, OS threads → logical threads, wall time → a logical clock). What remains, and what
/// lives here, is value-level normalization that depends on the caller's declared tolerances:
///  - redacting volatile fields (UUIDs, dates) to a placeholder naming their shape, and
///  - dropping ignored event kinds, then re-densifying the logical clock.
public enum Canonicalizer {
    /// Returns the placeholder a volatile field's value is redacted to: its shape, not its value.
    /// An identifier may differ every run, but an empty or lowercased one is a change consumers see.
    ///
    /// - Parameter value: The volatile field's value.
    /// - Returns: A string naming the value's kind, and for a string its format: empty, an upper- or
    ///   lowercase UUID, an ISO 8601 timestamp with or without fractional seconds, or other text.
    public static func volatilePlaceholder(for value: CanonicalValue) -> CanonicalValue {
        .string("⟨volatile \(value.shape)⟩")
    }

    /// Recursively redacts volatile fields anywhere in a payload tree. `label` is the owning event's
    /// label and `path` the dotted route from the payload root to `value` (arrays contribute no
    /// component) — the coordinates scoped `VolatileField` rules match against.
    public static func redact(
        _ value: CanonicalValue,
        spec: Tolerance,
        label: String,
        path: [String] = []
    ) -> CanonicalValue {
        switch value {
        case let .array(elements):
            return .array(elements.map { redact($0, spec: spec, label: label, path: path) })
        case let .object(members):
            var out: [String: CanonicalValue] = [:]
            for (key, val) in members {
                out[key] = spec.isVolatile(key: key, label: label, path: path + [key])
                    ? volatilePlaceholder(for: val)
                    : redact(val, spec: spec, label: label, path: path + [key])
            }
            return .object(out)
        default:
            return value
        }
    }

    /// Produces the canonical form of a whole trace under a tolerance spec.
    public static func canonicalize(_ trace: Trace, spec: Tolerance) -> Trace {
        let ignoredNotifications = Set(spec.ignoredNotificationNames)
        var events = trace.events.filter { event in
            if spec.ignoredKinds.contains(event.kind) {
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
            if let payload = events[index].payload {
                events[index].payload = redact(payload, spec: spec, label: events[index].label)
            }
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
