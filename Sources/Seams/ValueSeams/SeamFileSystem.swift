import Foundation
import HaruspecCore

// File-system seam — SEAMS.md: FileManager / file I/O. An injected, cassette-backed value seam: reads
// recorded/replayed by path; writes kept in-memory (sandboxed away from real disk).

/// File **reads** recorded/replayed by path; **writes** kept in-memory (sandboxed away from real disk),
/// with read-your-writes so a path written this run reads back consistently.
public final class SeamFileSystem: @unchecked Sendable {
    private let cassette: Cassette
    private let seam: String
    private let lock = NSLock()
    private var written: [String: Data] = [:]

    public init(cassette: Cassette, seam: String = "fs") {
        self.cassette = cassette
        self.seam = seam
    }

    public func readData(atPath path: String, live: () -> Data) -> Data {
        lock.lock(); let staged = written[path]; lock.unlock()
        if let staged {
            return staged
        }
        return cassette.data(seam: "\(seam).read:\(path)", live: live)
    }

    public func write(_ data: Data, toPath path: String) {
        lock.lock(); written[path] = data; lock.unlock()
    }

    /// Writes performed during this run (in-memory; for asserting write-side behavior).
    public func recordedWrites() -> [String: Data] {
        lock.lock(); defer { lock.unlock() }
        return written
    }
}
