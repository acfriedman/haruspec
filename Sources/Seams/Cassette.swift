import Foundation
import HaruspecCore

/// Which side of the record/replay loop a cassette is on.
public enum SeamMode: Sendable { case record, replay }

/// A replay hit a seam position with no recorded value — surfaced, never fabricated (the
/// "never silently mock" rule in docs/seams.md: it's both a behavioral-change signal and a coverage gap).
public struct SeamMiss: Sendable, Equatable {
    public var seam: String
    public var ordinal: Int
}

/// The concrete **cassette** from docs/seams.md: an ordered, keyed transcript of one run's seam
/// interactions, **recorded once from the golden branch and replayed identically into both branches**,
/// so any divergence in the diff is attributable to the changed code, not the environment.
///
/// Each seam id owns an ordered track of values. In `.record` mode a `step` runs the real dependency,
/// appends its canonical form, and returns it. In `.replay` mode it returns the next recorded value —
/// or, if the recording is exhausted, records a `SeamMiss` and falls back to `live` rather than
/// fabricating a response.
///
/// A read qualified by its call's arguments (a stamped double answering a query) is answered per
/// argument tuple: the first time a tuple is read it draws the seam's next value and binds it, and
/// later reads of that tuple replay the binding. A cassette replayed from the baseline's snapshot
/// therefore answers the candidate by arguments, whatever order it asks in.
public final class Cassette: @unchecked Sendable {
    public private(set) var mode: SeamMode
    private let lock = NSLock()
    private var tracks: [String: [CanonicalValue]] = [:]
    private var cursors: [String: Int] = [:]
    private var recordedMisses: [SeamMiss] = []
    /// Values bound to qualified keys (`"<seam>[<arguments>]"`), in read order per key.
    private var bindings: [String: [CanonicalValue]] = [:]
    private var bindingCursors: [String: Int] = [:]
    /// Reads per seam, bound or drawn: what coverage counts as exercised.
    private var reads: [String: Int] = [:]

    /// A fresh recording cassette.
    public init() {
        mode = .record
    }

    /// A recording cassette that answers the listed seams with `preferred` values instead of the
    /// op's own fallback, recording them as it goes. Seams not listed read live, exactly as ``init()``
    /// records them.
    ///
    /// - Parameter preferred: The value to answer each listed seam with, keyed by seam; empty records
    ///   exactly as ``init()`` does.
    ///
    /// The golden template is recorded this way, from each declared domain's first interior value, so
    /// the template sits inside the declared surface — a cart with items in it — rather than at the
    /// degenerate default every edge is then measured against.
    public init(recordingPreferring preferred: [String: CanonicalValue]) {
        mode = .record
        self.preferred = preferred
    }

    /// Values a recording answers with in place of the live dependency, by seam — see ``init(recordingPreferring:)``.
    private var preferred: [String: CanonicalValue] = [:]

    /// A replay cassette primed with a prior recording.
    ///
    /// - Parameter data: The tracks to replay, and the bindings a run already made against them.
    public init(replaying data: CassetteData) {
        mode = .replay
        tracks = data.tracks
        bindings = data.bindings
        // A bound value was drawn from its seam's track, so a fresh tuple draws after it.
        for (key, values) in data.bindings {
            cursors[SeamKey.base(of: key), default: 0] += values.count
        }
    }

    /// Replay positions that found no recorded value (only meaningful in `.replay` mode).
    public var misses: [SeamMiss] {
        lock.lock(); defer { lock.unlock() }
        return recordedMisses
    }

    /// How far replay advanced through each seam's track (seam id → recorded values consumed). A seam
    /// with a positive cursor was *exercised*; the coverage adapter reads this to tell an exercised
    /// boundary from a declared-but-never-reached one. Empty in `.record` mode.
    public var replayProgress: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    /// The core record/replay step, in the trace's own `CanonicalValue` currency.
    ///
    /// - Parameters:
    ///   - seam: The seam id: its track, and the key its declared domain is found under.
    ///   - qualifier: The reading call's arguments, rendered by ``SeamKey/qualifier(_:)``; `nil` for
    ///     a read that is not a call's answer, or a call without arguments.
    ///   - live: The real dependency, run on a recording or a miss.
    /// - Returns: The value this read is answered with.
    public func step(seam: String, qualifier: String? = nil, live: () -> CanonicalValue) -> CanonicalValue {
        lock.lock(); defer { lock.unlock() }
        reads[seam, default: 0] += 1
        let key = qualifier.map { SeamKey.qualified(seam, $0) }
        if mode == .replay, let key, let bound = bindings[key], bindingCursors[key, default: 0] < bound.count {
            defer { bindingCursors[key, default: 0] += 1 }
            return bound[bindingCursors[key, default: 0]]
        }
        let value: CanonicalValue
        switch mode {
        case .record:
            value = preferred[seam] ?? live()
            tracks[seam, default: []].append(value)
        case .replay:
            let cursor = cursors[seam, default: 0]
            guard let track = tracks[seam], cursor < track.count else {
                recordedMisses.append(SeamMiss(seam: seam, ordinal: cursor))
                return live()
            }
            cursors[seam] = cursor + 1
            value = track[cursor]
        }
        if let key {
            bindings[key, default: []].append(value)
            bindingCursors[key, default: 0] += 1
        }
        return value
    }

    /// Returns a serializable snapshot of the cassette.
    ///
    /// - Returns: The tracks, and every binding made so far.
    public func snapshot() -> CassetteData {
        lock.lock(); defer { lock.unlock() }
        return CassetteData(tracks: tracks, bindings: bindings)
    }
}

// MARK: - Typed accessors (one `step` each; `live` is invoked once on record/miss, never on a hit)

public extension Cassette {
    /// Returns an integer seam read; see ``step(seam:qualifier:live:)``.
    ///
    /// - Parameters:
    ///   - seam: The seam id.
    ///   - qualifier: The reading call's rendered arguments; `nil` for an unqualified read.
    ///   - live: The real dependency, run on a recording or a miss.
    /// - Returns: The integer this read is answered with; `live`'s value when the recorded value is another kind.
    func int(seam: String, qualifier: String? = nil, live: () -> Int64) -> Int64 {
        if case let .int(value) = step(seam: seam, qualifier: qualifier, live: { .int(live()) }) {
            return value
        }
        return live()
    }

    /// Returns a floating-point seam read; see ``step(seam:qualifier:live:)``.
    ///
    /// - Parameters:
    ///   - seam: The seam id.
    ///   - qualifier: The reading call's rendered arguments; `nil` for an unqualified read.
    ///   - live: The real dependency, run on a recording or a miss.
    /// - Returns: The number this read is answered with; `live`'s value when the recorded value is another kind.
    func double(seam: String, qualifier: String? = nil, live: () -> Double) -> Double {
        if case let .double(value) = step(seam: seam, qualifier: qualifier, live: { .double(live()) }) {
            return value
        }
        return live()
    }

    /// Returns a Boolean seam read; see ``step(seam:qualifier:live:)``.
    ///
    /// - Parameters:
    ///   - seam: The seam id.
    ///   - qualifier: The reading call's rendered arguments; `nil` for an unqualified read.
    ///   - live: The real dependency, run on a recording or a miss.
    /// - Returns: The Boolean this read is answered with; `live`'s value when the recorded value is another kind.
    func bool(seam: String, qualifier: String? = nil, live: () -> Bool) -> Bool {
        if case let .bool(value) = step(seam: seam, qualifier: qualifier, live: { .bool(live()) }) {
            return value
        }
        return live()
    }

    /// Returns a string seam read. A `nil` records as `.null`, and a recorded `.null` replays as `nil`.
    ///
    /// - Parameters:
    ///   - seam: The seam id.
    ///   - qualifier: The reading call's rendered arguments; `nil` for an unqualified read.
    ///   - live: The real dependency, run on a recording or a miss.
    /// - Returns: The string this read is answered with; `nil` when it recorded none.
    func string(seam: String, qualifier: String? = nil, live: () -> String?) -> String? {
        let recorded = step(seam: seam, qualifier: qualifier, live: { live().map(CanonicalValue.string) ?? .null })
        if case let .string(value) = recorded {
            return value
        }
        return nil
    }

    /// Binary payloads (e.g. a recorded HTTP body) ride as base64 strings.
    func data(seam: String, live: () -> Data) -> Data {
        let recorded = step(seam: seam, live: { .string(live().base64EncodedString()) })
        if case let .string(b64) = recorded, let decoded = Data(base64Encoded: b64) {
            return decoded
        }
        return live()
    }
}

// MARK: - Serialization (same JSON-bundle discipline as a Trace)

/// The on-disk form of a cassette: seam id → ordered recorded values, and the values a run bound to
/// its calls' arguments.
public struct CassetteData: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var tracks: [String: [CanonicalValue]]
    /// Qualified key → the values reads of that argument tuple were answered with. Empty for a
    /// generated input, which no run has read yet.
    public var bindings: [String: [CanonicalValue]]

    public init(
        schemaVersion: Int = 1,
        tracks: [String: [CanonicalValue]],
        bindings: [String: [CanonicalValue]] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.tracks = tracks
        self.bindings = bindings
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, tracks, bindings }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        tracks = try container.decode([String: [CanonicalValue]].self, forKey: .tracks)
        // Absent means no run bound anything: a generated input, or a subject with no qualified reads.
        bindings = try container.decodeIfPresent([String: [CanonicalValue]].self, forKey: .bindings) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tracks, forKey: .tracks)
        if !bindings.isEmpty {
            try container.encode(bindings, forKey: .bindings)
        }
    }
}

/// How a read qualified by its call's arguments is keyed.
public enum SeamKey {
    /// Renders a call's arguments as a qualifier, sorted by name so a key does not ride on
    /// dictionary order.
    ///
    /// - Parameter arguments: Argument name → canonical value, as the call's event records them.
    /// - Returns: `name=value` pairs joined by `", "`, or a stable digest when that would run past
    ///   96 characters; `nil` when there are no arguments.
    public static func qualifier(_ arguments: [String: CanonicalValue]) -> String? {
        guard !arguments.isEmpty else { return nil }
        let rendered = arguments.keys.sorted().map { "\($0)=\(arguments[$0]!.canonicalString)" }.joined(separator: ", ")
        guard rendered.count > 96 else { return rendered }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in rendered.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return "#" + String(hash, radix: 16)
    }

    /// Returns `seam` qualified by `qualifier`: `"Inventory.stock[sku="MUG"]"`.
    ///
    /// - Parameters:
    ///   - seam: The seam id.
    ///   - qualifier: A rendered qualifier.
    /// - Returns: The qualified key.
    public static func qualified(_ seam: String, _ qualifier: String) -> String {
        "\(seam)[\(qualifier)]"
    }

    /// Returns the seam id a qualified key reads, or `key` itself when it is not qualified.
    ///
    /// - Parameter key: A seam id or qualified key.
    /// - Returns: The part before the first `[`.
    public static func base(of key: String) -> String {
        key.firstIndex(of: "[").map { String(key[..<$0]) } ?? key
    }
}

public extension CassetteData {
    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    func jsonData() throws -> Data {
        try Self.canonicalEncoder().encode(self)
    }

    func write(to url: URL) throws {
        try jsonData().write(to: url)
    }

    init(jsonData: Data) throws {
        self = try JSONDecoder().decode(CassetteData.self, from: jsonData)
    }

    init(contentsOf url: URL) throws {
        try self.init(jsonData: Data(contentsOf: url))
    }
}
