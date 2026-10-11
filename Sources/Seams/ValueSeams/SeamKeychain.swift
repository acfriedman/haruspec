import Foundation
import HaruspecCore

// Keychain seam — docs/seams.md: the common auth-gate seam. An injected, cassette-backed value seam: record
// the token once, replay it so an auth gate never blocks a headless run.

/// Keychain reads, recorded/replayed per key — record the token once, replay it so an auth gate never
/// blocks a headless run. Writes are kept in-memory (they must not touch the real keychain in replay).
public final class SeamKeychain: @unchecked Sendable {
    private let cassette: Cassette
    private let seam: String
    private let lock = NSLock()
    private var written: [String: String] = [:]

    public init(cassette: Cassette, seam: String = "keychain") {
        self.cassette = cassette
        self.seam = seam
    }

    public func value(forKey key: String, live: () -> String?) -> String? {
        lock.lock(); let staged = written[key]; lock.unlock()
        if let staged {
            return staged
        } // read-your-writes within a run
        return cassette.string(seam: "\(seam).\(key)", live: live)
    }

    public func set(_ value: String, forKey key: String) {
        lock.lock(); written[key] = value; lock.unlock()
    }
}
