import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// The legacy async shape, stamped as pasted. A subject that answers through a completion block is
// driven and recorded with nothing reshaped; a collaborator that answers through one is stood in for
// by a double that answers with generated input; a constructor's block parameter resolves through
// `.provides`. Each role records the delivery as the same `call`/`ret` pair.

// MARK: - The subject: answers through a block

/// What a quote request fails with, asynchronously.
enum QuoteFailure: Error {
    case unknownCode
}

/// What a quote request is refused with, up front — before any work, and without the block.
enum QuoteRefusal: Error {
    case emptyCode
}

/// The pasted interface: the Obj-C shape — a throwing method for the up-front refusal, a block for
/// the answer — exactly as Swift imports it.
@Haruspec
protocol Quoting: AnyObject {
    func quote(
        _ code: String,
        completion: @escaping @Sendable (_ cents: Int, _ error: (any Error)?) -> Void
    ) throws
}

/// The quoter's own queue, injected: its answers are held for the capture and run in order.
@Haruspec(schedules: .serial)
protocol QuoterQueue: AnyObject {
    func async(_ work: @escaping () -> Void)
}

/// The baseline: refuses an empty code at once, answers everything else later, on its own queue.
final class LegacyQuoter: Quoting {
    private let queue: any QuoterQueue

    init(queue: any QuoterQueue) {
        self.queue = queue
    }

    func quote(_ code: String, completion: @escaping @Sendable (Int, (any Error)?) -> Void) throws {
        guard !code.isEmpty else { throw QuoteRefusal.emptyCode }
        queue.async { answer(code, completion) }
    }
}

/// A faithful port: a rewrite with the same channels — the throw, and the block on its own queue.
final class SwiftQuoter: Quoting {
    private let queue: any QuoterQueue

    init(queue: any QuoterQueue) {
        self.queue = queue
    }

    func quote(_ code: String, completion: @escaping @Sendable (Int, (any Error)?) -> Void) throws {
        guard !code.isEmpty else { throw QuoteRefusal.emptyCode }
        let answer: (Int, (any Error)?) = code == "SAVE10" ? (900, nil) : (0, QuoteFailure.unknownCode)
        queue.async { completion(answer.0, answer.1) }
    }
}

/// A port that answers before it returns, on the caller's thread: same values, but the caller's
/// block now runs re-entrantly, inside the request.
final class SynchronousQuoter: Quoting {
    func quote(_ code: String, completion: @escaping @Sendable (Int, (any Error)?) -> Void) throws {
        guard !code.isEmpty else { throw QuoteRefusal.emptyCode }
        answer(code, completion)
    }
}

/// A port that turns the up-front refusal into an asynchronous failure — same error, wrong channel.
final class LateRefusingQuoter: Quoting {
    private let queue: any QuoterQueue

    init(queue: any QuoterQueue) {
        self.queue = queue
    }

    func quote(_ code: String, completion: @escaping @Sendable (Int, (any Error)?) -> Void) throws {
        queue.async {
            guard !code.isEmpty else { return completion(0, QuoteRefusal.emptyCode) }
            answer(code, completion)
        }
    }
}

/// A port that forgets to answer a failure at all.
final class SilentQuoter: Quoting {
    private let queue: any QuoterQueue

    init(queue: any QuoterQueue) {
        self.queue = queue
    }

    func quote(_ code: String, completion: @escaping @Sendable (Int, (any Error)?) -> Void) throws {
        guard !code.isEmpty else { throw QuoteRefusal.emptyCode }
        queue.async {
            if code == "SAVE10" {
                completion(900, nil)
            }
        }
    }
}

/// A port that answers twice.
final class EchoingQuoter: Quoting {
    private let queue: any QuoterQueue

    init(queue: any QuoterQueue) {
        self.queue = queue
    }

    func quote(_ code: String, completion: @escaping @Sendable (Int, (any Error)?) -> Void) throws {
        guard !code.isEmpty else { throw QuoteRefusal.emptyCode }
        queue.async {
            answer(code, completion)
            answer(code, completion)
        }
    }
}

/// The quote every port answers with: the price for the one valid code, a failure for any other.
///
/// - Parameters:
///   - code: A non-empty promo code.
///   - completion: The caller's block, called once.
private func answer(_ code: String, _ completion: (Int, (any Error)?) -> Void) {
    if code == "SAVE10" {
        completion(900, nil)
    } else {
        completion(0, QuoteFailure.unknownCode)
    }
}

// MARK: - The collaborator: answers through a block

/// The boundary the subject depends on, as its Obj-C header declares it.
@Haruspec
protocol Rating: AnyObject {
    func rate(grams: Int, completion: @escaping (Int, (any Error)?) -> Void)
}

/// The subject reads its clock through a block parameter, and prices through `Rating`; a failed
/// rating posts the failure instead of the price.
@Haruspec
protocol Shipping: AnyObject {
    init(rating: any Rating, center: NotificationCenter, clock: @escaping () -> Int)
    func ship(grams: Int)
}

final class LegacyShipper: Shipping {
    private let rating: any Rating
    private let center: NotificationCenter
    private let clock: () -> Int

    init(rating: any Rating, center: NotificationCenter, clock: @escaping () -> Int) {
        self.rating = rating
        self.center = center
        self.clock = clock
    }

    func ship(grams: Int) {
        let day = clock()
        rating.rate(grams: max(1, grams)) { [center] cents, error in
            let outcome: [String: Any] = error == nil ? ["cents": cents, "day": day] : ["failed": true, "day": day]
            center.post(name: .init("ShipmentPriced"), object: nil, userInfo: outcome)
        }
    }
}

/// A port that ignores the rating's error, posting whatever price came with it.
final class TrustingShipper: Shipping {
    private let rating: any Rating
    private let center: NotificationCenter
    private let clock: () -> Int

    init(rating: any Rating, center: NotificationCenter, clock: @escaping () -> Int) {
        self.rating = rating
        self.center = center
        self.clock = clock
    }

    func ship(grams: Int) {
        let day = clock()
        rating.rate(grams: max(1, grams)) { [center] cents, _ in
            center.post(name: .init("ShipmentPriced"), object: nil, userInfo: ["cents": cents, "day": day])
        }
    }
}

struct CarrierTimeout: Error {}

// MARK: - Tests

final class CompletionBlockTests: XCTestCase {
    private var quoting: BaselinedSpec<any Quoting> {
        Spec<any Quoting>("quoting.completion") {
            Amend("quote").varying("code", over: .oneOf("SAVE10", "NOPE", ""))
        }
        .vary {
            Ordering(max: 4)
            Budget(runs: 30)
        }
        .baselined { context in LegacyQuoter(queue: context.double(DoubleQuoterQueue.self)) }
    }

    private var shipping: BaselinedSpec<any Shipping> {
        Spec<any Shipping>("shipping.completion")
            .provides((() -> Int).self) { context in { Int(context.int("Clock.day", default: 1)) } }
            .generates((any Error).self) { _, _ in CarrierTimeout() }
            .vary {
                Seam("Rating.rate.completion.0", .int(0 ... 2400))
                Seam("Rating.rate.completion.1", .bool)
                Ordering(max: 4)
                Budget(runs: 40)
            }
            .baselined(on: LegacyShipper.self)
    }

    // MARK: The forwarder records the delivery

    func testTheForwarderRecordsTheDeliveryWithTheBlocksArguments() async throws {
        let recorder = TraceRecorder(name: "quote")
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())
        let quoter = TracedQuoting(LegacyQuoter(queue: context.double(DoubleQuoterQueue.self)))

        await TraceContext.$current.withValue(recorder) {
            await WorkBacklog.$current.withValue(context.backlog) {
                await CompletionDelivery.awaited { delivered in
                    try quoter.quote("SAVE10") { _, _ in delivered() }
                }
            }
        }

        let events = recorder.trace().events.map { "\($0.kind) \($0.label)" }
        XCTAssertEqual(events, [
            "call Quoting.quote",
            "ret Quoting.quote",
            "call Quoting.quote.completion",
            "ret Quoting.quote.completion"
        ])
        let delivery = try XCTUnwrap(recorder.trace().events.first { $0.label == "Quoting.quote.completion" })
        XCTAssertEqual(delivery.payload, .object(["cents": .int(900), "error": .null]))
        let call = try XCTUnwrap(recorder.trace().events.first)
        XCTAssertEqual(call.payload, .object(["code": .string("SAVE10")]), "the block is not an argument value")
    }

    func testARefusedRequestRecordsTheThrowAndNoDelivery() async {
        let recorder = TraceRecorder(name: "refused")
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())
        let quoter = TracedQuoting(LegacyQuoter(queue: context.double(DoubleQuoterQueue.self)))

        await TraceContext.$current.withValue(recorder) {
            await WorkBacklog.$current.withValue(context.backlog) {
                await CompletionDelivery.awaited { delivered in
                    try quoter.quote("") { _, _ in delivered() }
                }
            }
        }

        XCTAssertEqual(recorder.trace().events.map(\.label), ["Quoting.quote", "Quoting.quote"])
        XCTAssertFalse(recorder.trace().events.contains { $0.label.hasSuffix(".completion") })
    }

    // MARK: The derived op awaits it

    func testTheBlockIsNotGeneratedInput() {
        let quote = DerivedQuoting.derivedOps.first { $0.label == "quote" }
        XCTAssertEqual(quote?.arguments.map(\.name), ["code"])
    }

    func testAFaithfulPortIsEquivalent() async {
        let verdict = await quoting
            .verify { context in SwiftQuoter(queue: context.double(DoubleQuoterQueue.self)) }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testAnAnswerMovedOntoTheCallersThreadDiverges() async {
        let verdict = await quoting.verify { _ in SynchronousQuoter() }

        XCTAssertEqual(verdict.verdict, .diverged, "where the block runs is contract")
        XCTAssertTrue(
            verdict.report().contains("Quoting.quote.completion: ran on a different domain"),
            verdict.report()
        )
    }

    func testARefusalMovedIntoTheBlockDiverges() async {
        let verdict = await quoting
            .verify { context in LateRefusingQuoter(queue: context.double(DoubleQuoterQueue.self)) }

        XCTAssertEqual(verdict.verdict, .diverged, "a throw and a delivered error are different contracts")
    }

    func testABlockNeverCalledDiverges() async {
        let verdict = await quoting
            .verify { context in SilentQuoter(queue: context.double(DoubleQuoterQueue.self)) }

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
    }

    func testABlockCalledTwiceDiverges() async {
        let verdict = await quoting
            .verify { context in EchoingQuoter(queue: context.double(DoubleQuoterQueue.self)) }

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
    }

    // MARK: The double answers with generated input

    func testTheDoubleDeliversGeneratedArgumentsAndRecordsTheDelivery() {
        let recorder = TraceRecorder(name: "rate")
        let context = SeamContext(notifications: NotificationCenter(), cassette: Cassette())
        let rating = DoubleRating(context)
        nonisolated(unsafe) var delivered: (Int, Bool)?

        TraceContext.$current.withValue(recorder) {
            rating.rate(grams: 500) { cents, error in delivered = (cents, error != nil) }
        }

        XCTAssertEqual(delivered?.0, 0, "the price defaults to the type's zero")
        XCTAssertEqual(delivered?.1, false, "a delivery succeeds until a spec sweeps its error slot")
        XCTAssertEqual(recorder.trace().events.map { "\($0.kind) \($0.label)" }, [
            "call Rating.rate",
            "call Rating.rate.completion",
            "ret Rating.rate.completion",
            "ret Rating.rate"
        ])
    }

    func testABaselineChecksAgainstItselfThroughTheDerivedWiring() async throws {
        let verdict = try await shipping.check(LegacyShipper.self)

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    func testASweptErrorSlotReachesTheFailureBranch() async {
        let verdict = await shipping.verify { context in
            TrustingShipper(
                rating: context.double(DoubleRating.self),
                center: context.notifications,
                clock: context.resolve((() -> Int).self)
            )
        }

        XCTAssertEqual(verdict.verdict, .diverged, "only a failing rating tells the ports apart")
    }
}
