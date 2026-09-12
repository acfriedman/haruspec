import Foundation
import HaruspecCore

/// Which side of the record/replay loop a cassette is on.
public enum SeamMode: Sendable { case record, replay }

/// A replay hit a seam position with no recorded value — surfaced, never fabricated (SEAMS.md's
/// "unrecorded interaction" policy: it's both a behavioral-change signal and a coverage gap).
public struct SeamMiss: Sendable, Equatable {
    public var seam: String
    public var ordinal: Int
}

/// The concrete **cassette** from SEAMS.md: an ordered, keyed transcript of one run's seam
/// interactions, **recorded once from the golden branch and replayed identically into both branches**,
/// so any divergence in the diff is attributable to the changed code, not the environment.
///
/// Each seam id owns an ordered track of values. In `.record` mode a `step` runs the real dependency,
/// appends its canonical form, and returns it. In `.replay` mode it returns the next recorded value —
/// or, if the recording is exhausted, records a `SeamMiss` and falls back to `live` rather than
/// fabricating a response.
public final class Cassette: @unchecked Sendable {
    public private(set) var mode: SeamMode
    private let lock = NSLock()
    private var tracks: [String: [CanonicalValue]] = [:]
    private var cursors: [String: Int] = [:]
    private var recordedMisses: [SeamMiss] = []

    /// A fresh recording cassette.
    public init() {
        mode = .record
    }

    /// A recording cassette that answers the listed seams with `preferred` values instead of the
    /// op's own fallback, recording them as it goes. The golden template is recorded this way, from
    /// each declared domain's first interior value, so the template sits inside the declared surface
    /// — a cart with items in it — rather than at the degenerate default every edge is then measured
    /// against. Seams not listed read live, exactly as `init()` records them.
    public init(recordingPreferring preferred: [String: CanonicalValue]) {
        mode = .record
        self.preferred = preferred
    }

    /// Values a recording answers with in place of `live()`, by seam — see `init(recordingPreferring:)`.
    private var preferred: [String: CanonicalValue] = [:]

    /// A replay cassette primed with a prior recording.
    public init(replaying data: CassetteData) {
        mode = .replay
        tracks = data.tracks
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
        return cursors
    }

    /// The core record/replay step, in the trace's own `CanonicalValue` currency.
    public func step(seam: String, live: () -> CanonicalValue) -> CanonicalValue {
        lock.lock(); defer { lock.unlock() }
        switch mode {
        case .record:
            let value = preferred[seam] ?? live()
            tracks[seam, default: []].append(value)
            return value
        case .replay:
            let cursor = cursors[seam, default: 0]
            guard let track = tracks[seam], cursor < track.count else {
                recordedMisses.append(SeamMiss(seam: seam, ordinal: cursor))
                return live()
            }
            cursors[seam] = cursor + 1
            return track[cursor]
        }
    }

    /// A serializable snapshot of what has been recorded so far.
    public func snapshot() -> CassetteData {
        lock.lock(); defer { lock.unlock() }
        return CassetteData(tracks: tracks)
    }
}

// MARK: - Typed accessors (one `step` each; `live` is invoked once on record/miss, never on a hit)

public extension Cassette {
    func int(seam: String, live: () -> Int64) -> Int64 {
        if case let .int(value) = step(seam: seam, live: { .int(live()) }) {
            return value
        }
        return live()
    }

    func double(seam: String, live: () -> Double) -> Double {
        if case let .double(value) = step(seam: seam, live: { .double(live()) }) {
            return value
        }
        return live()
    }

    func bool(seam: String, live: () -> Bool) -> Bool {
        if case let .bool(value) = step(seam: seam, live: { .bool(live()) }) {
            return value
        }
        return live()
    }

    /// Records `nil` as `.null`; a recorded `.null` replays back to `nil`.
    func string(seam: String, live: () -> String?) -> String? {
        let recorded = step(seam: seam, live: { live().map(CanonicalValue.string) ?? .null })
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

/// The on-disk form of a cassette: seam id → ordered recorded values.
public struct CassetteData: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var tracks: [String: [CanonicalValue]]

    public init(schemaVersion: Int = 1, tracks: [String: [CanonicalValue]]) {
        self.schemaVersion = schemaVersion
        self.tracks = tracks
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
