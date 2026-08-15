import Foundation
@testable import HaruspecAudit
import HaruspecTrace
import XCTest

// What an audit means once the author's acceptances are applied. The partition is four ways because
// "declared" is not one fact — and the fourth (declared, found nowhere) is the notification-allowlist
// failure, which cost this project months of a declaration nothing could satisfy.

final class AuditOutcomeTests: XCTestCase {
    private func finding(_ channel: String, use: ChannelUse = .bypass) -> ChannelFinding {
        ChannelFinding(channel: channel, use: use, file: "Sources/Cart.swift", line: 1, text: "…")
    }

    private func unresolved(_ symbol: String) -> SourceResolution {
        SourceResolution(origin: TraceOrigin(label: "Cart", symbol: symbol), files: [])
    }

    func testAnUndeclaredBypassGates() {
        let outcome = AuditReport(unresolved: [], findings: [finding("Combine")])
            .outcome(accepting: [])

        XCTAssertEqual(outcome.bypassed, ["Combine"])
        XCTAssertTrue(outcome.gates)
        XCTAssertEqual(outcome.entries, ["Combine"])
    }

    func testADeclaredChannelStopsGatingButStaysNamed() {
        let outcome = AuditReport(unresolved: [], findings: [finding("Combine")])
            .outcome(accepting: ["Combine"])

        XCTAssertEqual(outcome.bypassed, [])
        XCTAssertEqual(outcome.accepted, ["Combine"])
        XCTAssertFalse(outcome.gates)
        XCTAssertEqual(outcome.entries, ["Combine (declared)"])
    }

    func testADeclarationThatMatchesNothingIsReportedRatherThanQuietlyEffective() {
        let outcome = AuditReport(unresolved: [], findings: [])
            .outcome(accepting: ["Timer / RunLoop"])

        XCTAssertEqual(outcome.unmatched, ["Timer / RunLoop"])
        XCTAssertFalse(outcome.gates, "a declaration matching nothing excuses nothing, and breaks nothing")
        XCTAssertEqual(outcome.entries, ["Timer / RunLoop (declared, not found)"])
    }

    func testAnUnreadableDeclarationGatesAndCannotBeDeclaredAway() {
        let outcome = AuditReport(unresolved: [unresolved("CartManager")], findings: [])
            .outcome(accepting: ["CartManager"])

        XCTAssertEqual(outcome.unreadable, ["CartManager"])
        XCTAssertTrue(outcome.gates, "an accepted *channel* is not an accepted unreadable subject")
        XCTAssertEqual(outcome.entries.first, "CartManager (no source found)")
    }

    func testInjectableDefaultsAreNeverGatingFindings() {
        let outcome = AuditReport(
            unresolved: [],
            findings: [finding("NotificationCenter.default", use: .injectableDefault)]
        ).outcome(accepting: [])

        XCTAssertFalse(outcome.gates, "a default at an injection point is a fact about the run, not the source")
        XCTAssertEqual(outcome.entries, [])
    }

    func testOneChannelIsNamedOnceHoweverManyLinesReachIt() {
        let outcome = AuditReport(
            unresolved: [],
            findings: [finding("Combine"), finding("Combine"), finding("KVO")]
        ).outcome(accepting: [])

        XCTAssertEqual(outcome.bypassed, ["Combine", "KVO"])
    }
}
