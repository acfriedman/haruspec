import Foundation
@testable import HaruspecSpec
import XCTest

/// Each op records its closure's isolation, and a capture refuses an isolated one.
///
/// An op's closure takes the isolation of the context it is written in. A capture reads the main
/// thread as the subject's doing, so an op that runs on main would make the subject's nonisolated
/// code read `main`.
final class IsolatedOpTests: XCTestCase {
    private typealias Refusal = Spec<PromoCart>

    func testAnOpWrittenInANonisolatedContextIsNonisolated() {
        let op = Op<PromoCart>("add") { _ in }

        XCTAssertNil(op.isolation)
        XCTAssertNil(Refusal.isolationRefusal(op))
    }

    func testAnOpWrittenInAMainActorContextIsRefused() async throws {
        let op = await MainActorSpec().op
        let refusal = try XCTUnwrap(Refusal.isolationRefusal(op.value))

        XCTAssertTrue(op.value.isolation === MainActor.shared)
        XCTAssertTrue(refusal.hasPrefix("op 'add' runs on the main actor"), refusal)
        XCTAssertTrue(refusal.contains("`nonisolated`"), "the refusal names the fix: \(refusal)")
    }

    func testAnOpFromAMainActorFunctionReferenceIsRefused() {
        let op = Op<PromoCart>("apply", applyOnMain)

        XCTAssertTrue(op.isolation === MainActor.shared)
    }

    func testAParameterizedOpCarriesItsIsolation() async {
        let op = await MainActorSpec().parameterized

        XCTAssertTrue(op.value.isolation === MainActor.shared)
    }

    func testADerivedOpCarriesItsIsolationToTheOpItResolvesTo() async {
        let derived = await MainActorSpec().derived

        XCTAssertTrue(derived.value.resolved().isolation === MainActor.shared)
        XCTAssertNil(DerivedOp<PromoCart>("add") { _, _ in }.resolved().isolation)
    }
}

/// Carries a non-`Sendable` op out of the main actor for inspection.
private struct Carried<T>: @unchecked Sendable {
    let value: T
}

/// A spec type stamped `@MainActor`, whose op closures inherit it.
@MainActor
private struct MainActorSpec {
    var op: Carried<Op<PromoCart>> {
        Carried(value: Op("add") { _ in })
    }

    var parameterized: Carried<Op<PromoCart>> {
        Carried(value: Op("add") { _, _ in })
    }

    var derived: Carried<DerivedOp<PromoCart>> {
        Carried(value: DerivedOp("add") { _, _ in })
    }
}

@MainActor
private func applyOnMain(_: PromoCart) async {}
