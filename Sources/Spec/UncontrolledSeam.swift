import Foundation
import HaruspecCore

/// A payload field that took different values over identical inputs. It is a value the subject
/// makes up itself (a fresh identifier, a clock reading) instead of reading through a seam.
///
/// Two runs that cannot agree on it cannot be compared, so the remedy is to inject its source;
/// redacting it would hide the seam along with any real change to the field.
public struct UncontrolledSeam: Codable, Sendable, Equatable {
    /// The label of the event carrying the field.
    public var label: String
    /// The leaf path within the payload, as a `valueMismatch` names it (`"receipt.issuedAt"`).
    public var field: String
    /// The value's shape (see ``CanonicalValue/shape``), which the remedy is chosen by.
    public var shape: String

    public init(label: String, field: String, shape: String) {
        self.label = label
        self.field = field
        self.shape = shape
    }

    /// What controls a value of this shape: the source to inject so both sides draw the same one.
    public var remedy: String {
        switch shape {
        case "UUID", "uuid", "mixed-case uuid":
            "a fresh identifier — inject its source (a `() -> UUID` the initializer takes, supplied "
                + "by the spec's `.provides`)"
        case "ISO 8601 timestamp", "ISO 8601 timestamp, fractional seconds", "double":
            "likely a clock reading — inject the clock (a `() -> Date` the initializer takes, "
                + "supplied by `.provides` and read through a seam)"
        default:
            "a value the subject makes up itself — inject its source through the initializer and "
                + "supply it with `.provides`"
        }
    }

    /// The one-line rendering every report surface shares.
    public var summary: String {
        "\(label).\(field) (\(shape)): \(remedy)"
    }

    /// Where a seam sits: the identity two mismatches share when they are about the same field.
    private struct Position: Hashable {
        var label: String
        var field: String
    }

    /// Returns the seam a divergence names, with its position.
    ///
    /// - Parameter divergence: One divergence of any kind.
    /// - Returns: The position and seam for a `valueMismatch` that names its field; `nil` otherwise.
    private static func seam(of divergence: Divergence) -> (Position, UncontrolledSeam)? {
        guard divergence.kind == .valueMismatch, let field = divergence.field else {
            return nil
        }
        let value = divergence.candidateValue ?? divergence.baselineValue ?? .null
        return (
            Position(label: divergence.label, field: field),
            UncontrolledSeam(label: divergence.label, field: field, shape: value.shape)
        )
    }

    /// Returns the fields a set of divergences shows varying — every `valueMismatch` with a field,
    /// once per label and field, in reported order.
    ///
    /// - Parameter divergences: A comparison of one implementation against itself, where any value
    ///   mismatch is a value the run made up.
    /// - Returns: The uncontrolled seams, deduplicated.
    static func found(in divergences: [Divergence]) -> [UncontrolledSeam] {
        var seen: Set<Position> = []
        return divergences.compactMap(seam(of:)).compactMap { position, seam in
            seen.insert(position).inserted ? seam : nil
        }
    }

    /// Returns the fields whose mismatch differed between replay passes over identical inputs —
    /// present in some passes and not others, or with different values.
    ///
    /// - Parameter passes: Each pass's divergences, in pass order.
    /// - Returns: The uncontrolled seams, in first-seen order.
    static func found(across passes: [[Divergence]]) -> [UncontrolledSeam] {
        var firstSeen: [(Position, UncontrolledSeam)] = []
        // Per position, each pass's (baseline, candidate) values; a pass without the mismatch is absent.
        var readings: [Position: [Int: [CanonicalValue?]]] = [:]
        for (pass, divergences) in passes.enumerated() {
            for divergence in divergences {
                guard let (position, seam) = seam(of: divergence) else {
                    continue
                }
                if readings[position] == nil {
                    firstSeen.append((position, seam))
                }
                readings[position, default: [:]][pass] = [divergence.baselineValue, divergence.candidateValue]
            }
        }
        return firstSeen.compactMap { position, seam in
            let byPass = readings[position] ?? [:]
            return passes.indices.contains { byPass[$0] != byPass[0] } ? seam : nil
        }
    }
}
