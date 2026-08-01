import Foundation

/// Turns a raw captured trace into a *canonical* one the diff engine can compare deterministically.
///
/// The recorder already handles the hardest sources of nondeterminism at capture time (pointers →
/// symbolic ids, OS threads → logical threads, wall time → a logical clock). What remains, and what
/// lives here, is value-level normalization that depends on the caller's declared tolerances:
///  - redacting volatile fields (UUIDs, dates) to a stable placeholder, and
///  - dropping ignored event kinds, then re-densifying the logical clock.
public enum Canonicalizer {
    /// Placeholder substituted for any volatile field's value. Chosen to be visually obvious in dumps.
    public static let volatilePlaceholder = CanonicalValue.string("⟨volatile⟩")

    /// Recursively redact volatile fields anywhere in a payload tree. `label` is the owning event's
    /// label and `path` the dotted route from the payload root to `value` (arrays contribute no
    /// component) — the coordinates scoped `VolatileField` rules match against.
    public static func redact(_ value: CanonicalValue, spec: ToleranceSpec,
                              label: String, path: [String] = []) -> CanonicalValue {
        switch value {
        case .array(let elements):
            return .array(elements.map { redact($0, spec: spec, label: label, path: path) })
        case .object(let members):
            var out: [String: CanonicalValue] = [:]
            for (key, val) in members {
                out[key] = spec.isVolatile(key: key, label: label, path: path + [key])
                    ? volatilePlaceholder
                    : redact(val, spec: spec, label: label, path: path + [key])
            }
            return .object(out)
        default:
            return value
        }
    }

    /// Produce the canonical form of a whole trace under a tolerance spec.
    public static func canonicalize(_ trace: Trace, spec: ToleranceSpec) -> Trace {
        let ignoredNotifications = Set(spec.ignoredNotificationNames)
        var events = trace.events.filter { event in
            if spec.ignoredKinds.contains(event.kind) { return false }
            // Opt-out denylist: drop named notification channels (see `ignoredNotificationNames`).
            if event.kind == .notification && ignoredNotifications.contains(event.label) { return false }
            return true
        }
        for i in events.indices {
            if let payload = events[i].payload {
                events[i].payload = redact(payload, spec: spec, label: events[i].label)
            }
            events[i].seq = i // re-densify the logical clock after any filtering
        }
        return Trace(name: trace.name, schemaVersion: trace.schemaVersion, events: events)
    }
}
