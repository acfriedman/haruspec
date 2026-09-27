import Dispatch
import Foundation
@testable import HaruspecCore
@testable import HaruspecTrace
import XCTest

/// The domain a `TraceRecorder` stamps on an event, end to end through the real ladder — `#isolation`
/// resolved at the recording call site, then the dispatch queue label.
///
/// These are the tests that would have caught the old `worker-N` scheme: it named every context below
/// `main` or a first-seen integer, and reused one integer across unrelated domains.
final class ConcurrencyDomainTests: XCTestCase {
    private actor Ledger {
        let recorder: TraceRecorder
        init(recorder: TraceRecorder) {
            self.recorder = recorder
        }

        /// No isolation argument here on purpose: this is the shape a sync forwarded call expands to, and the
        /// default `#isolation` has to pick the actor up without the call site naming it.
        func post() {
            recorder.marker("Ledger.post")
        }
    }

    @MainActor
    private func recordOnMain(_ recorder: TraceRecorder) {
        recorder.marker("onMain")
    }

    private func domains(of recorder: TraceRecorder) -> [String: ConcurrencyDomain] {
        Dictionary(uniqueKeysWithValues: recorder.trace().events.map { ($0.label, $0.domain) })
    }

    @MainActor
    func testResolvesMainActorAndActorInstances() async {
        let recorder = TraceRecorder(name: "domains")
        recordOnMain(recorder)
        await Ledger(recorder: recorder).post()

        let byLabel = domains(of: recorder)
        XCTAssertEqual(byLabel["onMain"], .main)
        // Nominal type, not a scheduling artifact — the actor runs on the cooperative pool, which the
        // label rung would have reported as `ambient`.
        XCTAssertEqual(byLabel["Ledger.post"], .actor("Ledger", instance: 1))
    }

    /// Two instances of one actor type are distinct domains, numbered by the same symbolic-identity
    /// map that numbers traced subjects.
    @MainActor
    func testDistinguishesTwoInstancesOfOneActorType() async {
        let recorder = TraceRecorder(name: "domains")
        let first = Ledger(recorder: recorder)
        let second = Ledger(recorder: recorder)
        await first.post()
        await second.post()

        let observed = recorder.trace().events.map(\.domain)
        XCTAssertEqual(observed, [.actor("Ledger", instance: 1), .actor("Ledger", instance: 2)])
    }

    /// The rung below `#isolation`: nonisolated work carries the queue's own label — and the
    /// discipline stated at creation, which the `DispatchQueue.init` overload registered.
    func testResolvesNamedDispatchQueuesByLabel() {
        let recorder = TraceRecorder(name: "domains")
        let checkout = DispatchQueue(label: "com.emporium.checkout")
        let analytics = DispatchQueue(label: "com.emporium.analytics", attributes: .concurrent)

        checkout.sync { recorder.marker("checkout-work") }
        analytics.sync { recorder.marker("analytics-work") }

        let byLabel = domains(of: recorder)
        XCTAssertEqual(byLabel["checkout-work"], .queue("com.emporium.checkout", serial: true))
        XCTAssertEqual(byLabel["analytics-work"], .queue("com.emporium.analytics", serial: false))
    }

    /// Work the runtime scheduled with nothing nominal to key on is `.ambient` — explicitly unordered,
    /// rather than a worker number that would differ between runs.
    func testUnattributedConcurrentWorkIsAmbient() async {
        let recorder = TraceRecorder(name: "domains")
        await Task.detached { recorder.marker("nonisolated") }.value

        XCTAssertEqual(recorder.trace().events.first?.domain, .ambient)
        XCTAssertFalse(ConcurrencyDomain.ambient.isOrdered)
        XCTAssertTrue(ConcurrencyDomain.queue("q", serial: true).isOrdered)
        // A concurrent queue is a *named* unordered context: nominal identity, no order contract.
        XCTAssertFalse(ConcurrencyDomain.queue("q", serial: false).isOrdered)
    }

    /// The property the old scheme could not hold: one OS thread serving several domains in a single
    /// run must still produce several *distinct* domains.
    @MainActor
    func testOneThreadServingSeveralDomainsStaysDistinct() async {
        let recorder = TraceRecorder(name: "domains")
        let checkout = DispatchQueue(label: "com.emporium.checkout")

        await Ledger(recorder: recorder).post()
        await withCheckedContinuation { continuation in
            checkout.async {
                recorder.marker("onCheckoutQueue")
                continuation.resume()
            }
        }
        await Task.detached { recorder.marker("nonisolated") }.value

        XCTAssertEqual(Set(recorder.trace().events.map(\.domain)).count, 3)
    }
}

final class ConcurrencyDomainCodingTests: XCTestCase {
    func testRoundTripsEveryCase() throws {
        let cases: [ConcurrencyDomain] = [
            .main,
            .ambient,
            .queue("com.emporium.checkout", serial: true),
            .queue("com.emporium.delivery", serial: false),
            .actor("Ledger", instance: 7)
        ]
        for domain in cases {
            let data = try JSONEncoder().encode(domain)
            XCTAssertEqual(try JSONDecoder().decode(ConcurrencyDomain.self, from: data), domain)
        }
    }

    /// Readable on-disk spellings — a plan artifact is reviewed in a PR diff, so the domain has to be
    /// legible without a decoder.
    func testEncodesReadableSpellings() throws {
        func encoded(_ domain: ConcurrencyDomain) throws -> String {
            try XCTUnwrap(String(bytes: JSONEncoder().encode(domain), encoding: .utf8))
        }
        XCTAssertEqual(try encoded(.main), "\"main\"")
        XCTAssertEqual(try encoded(.ambient), "\"ambient\"")
        XCTAssertEqual(
            try encoded(.queue("com.emporium.checkout", serial: true)),
            "\"queue(serial):com.emporium.checkout\""
        )
        XCTAssertEqual(
            try encoded(.queue("com.emporium.delivery", serial: false)),
            "\"queue(concurrent):com.emporium.delivery\""
        )
        XCTAssertEqual(try encoded(.actor("Ledger", instance: 2)), "\"actor:Ledger#2\"")
    }

    /// A queue label may legitimately contain the separators, so parsing splits at the right place.
    func testParsesLabelsContainingSeparators() throws {
        let awkward = ConcurrencyDomain.queue("com.emporium.a#b:c", serial: false)
        let data = try JSONEncoder().encode(awkward)
        XCTAssertEqual(try JSONDecoder().decode(ConcurrencyDomain.self, from: data), awkward)
    }

    /// Fail fast on an unrecognized spelling rather than coercing it to `.main` — a plan whose domains
    /// silently collapse would replay a lie. A pre-discipline `queue:` is unrecognized on purpose:
    /// guessing serial would turn a stale artifact's noise into a contract.
    func testRejectsUnrecognizedSpelling() {
        for stale in ["\"worker-3\"", "\"queue:com.emporium.checkout\""] {
            XCTAssertThrowsError(try JSONDecoder().decode(ConcurrencyDomain.self, from: Data(stale.utf8)))
        }
    }
}
