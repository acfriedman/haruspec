import Foundation
import HaruspecCore

// Persistence seam — docs/seams.md: `UserDefaults`. An injected, cassette-backed value seam: config *reads*
// are recorded/replayed; *writes* are behavior, kept in-memory during replay.

/// A key/value store whose *reads* are recorded/replayed (the seam is the config a code path reads;
/// writes are behavior, kept in-memory during replay so they never touch real defaults). Each key owns
/// its own ordered track, so repeated reads of a key replay in order.
public final class SeamDefaults: @unchecked Sendable {
    private let cassette: Cassette
    private let seam: String
    private let lock = NSLock()
    private var writes: [String: CanonicalValue] = [:]

    public init(cassette: Cassette, seam: String = "defaults") {
        self.cassette = cassette
        self.seam = seam
    }

    public func string(forKey key: String, live: () -> String?) -> String? {
        cassette.string(seam: track(key), live: live)
    }

    public func integer(forKey key: String, live: () -> Int) -> Int {
        Int(cassette.int(seam: track(key), live: { Int64(live()) }))
    }

    public func bool(forKey key: String, live: () -> Bool) -> Bool {
        cassette.bool(seam: track(key), live: live)
    }

    /// Writes are recorded as observable behavior and kept in-memory; they do not mutate real storage.
    public func set(_ value: CanonicalValue, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        writes[key] = value
    }

    /// The set of writes performed during this run (for asserting write-side behavior).
    public func recordedWrites() -> [String: CanonicalValue] {
        lock.lock(); defer { lock.unlock() }
        return writes
    }

    private func track(_ key: String) -> String {
        "\(seam).\(key)"
    }
}
