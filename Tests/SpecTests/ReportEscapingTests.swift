import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// A string value in a report reads as itself on one line: a varied separator or a returned value
// with a line break in it is printed escaped, so it cannot fold the report or read as empty.

// MARK: - The boundary

/// Joins two items with a separator the caller sets.
@Haruspec
protocol Joining: AnyObject {
    func setSeparator(_ separator: String)
    func joined() -> String
}

/// The baseline: joins with whatever separator it was given.
final class Joiner: Joining {
    private var separator = ","

    func setSeparator(_ separator: String) {
        self.separator = separator
    }

    func joined() -> String {
        ["alpha", "bravo"].joined(separator: separator)
    }
}

/// A port that normalizes a CRLF separator to LF, so only that separator tells the two apart.
final class LineFeedJoiner: Joining {
    private var separator = ","

    func setSeparator(_ separator: String) {
        self.separator = separator == "\r\n" ? "\n" : separator
    }

    func joined() -> String {
        ["alpha", "bravo"].joined(separator: separator)
    }
}

// MARK: - Tests

final class ReportEscapingTests: XCTestCase {
    func testADivergingStringReturnAndItsCounterexampleReadOnOneLineEach() async {
        let verdict = await Spec<any Joining>("joining.separator") {
            Amend("setSeparator").varying("separator", over: .oneOf("\n", "\r\n", ","))
        }
        .baselined { _ in Joiner() }
        .verify { _ in LineFeedJoiner() }
        let report = verdict.report()

        XCTAssertEqual(verdict.verdict, .diverged, report)
        XCTAssertTrue(
            report.contains(#"≠ Joining.joined: value: baseline="alpha\r\nbravo" candidate="alpha\nbravo""#),
            report
        )
        // `\.isNewline` and not `"\n"`: a CRLF is one `Character`, which a split on LF would miss.
        let lines = report.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let counterexample = lines.first { $0.contains("↳ counterexample:") }
        XCTAssertTrue(counterexample?.contains(#"setSeparator.separator="\r\n""#) == true, report)
        XCTAssertEqual(lines.dropFirst().filter { !$0.hasPrefix("  ") }, [], "a value folded the report:\n\(report)")
        let html = verdict.htmlReport()
        XCTAssertTrue(html.contains(#"<span class="val">&quot;\r\n&quot;"#), "the HTML counterexample chip")
        XCTAssertTrue(html.contains(#"&quot;alpha\r\nbravo&quot;"#), "the HTML value diff")
        XCTAssertFalse(html.unicodeScalars.contains("\r"), "no raw carriage return anywhere in the HTML")
    }

    func testTheIssuesSeparatorsReadAsThemselves() {
        let pairs = verdict(counterexample: [
            "setSeparator.separator": [.string("\n"), .string("\r\n"), .string(",")]
        ]).counterexampleSeamPairs

        XCTAssertEqual(pairs.first?.value, #""\n","\r\n",",""#)
    }

    func testAPlainStringStaysBare() {
        let pairs = verdict(counterexample: [
            "add.sku": [.string("COFFEE"), .string("MUG-12"), .string("café")],
            "add.quantity": [.int(1), .int(20)]
        ]).counterexampleSeamPairs

        XCTAssertEqual(pairs.map(\.value), ["1,20", "COFFEE,MUG-12,café"])
    }

    /// A string that is empty, holds a separator, or would read as another kind of value is quoted.
    func testAStringThatWouldReadAsSomethingElseIsQuoted() {
        let quoted = [
            "",
            "a b",
            "a,b",
            "a \u{301}b",
            ",\u{301}",
            #"say "hi""#,
            #"C:\path"#,
            "42",
            "-1.5",
            "true",
            "null",
            "tab\there"
        ]

        for text in quoted {
            let value = verdict(counterexample: ["k": [.string(text)]]).counterexampleSeamPairs.first?.value
            XCTAssertEqual(value, CanonicalValue.string(text).canonicalString, text.debugDescription)
        }
    }

    /// Returns a verdict whose counterexample is `tracks`, and nothing else of note.
    ///
    /// - Parameter tracks: The counterexample's seam values, per seam.
    /// - Returns: A verdict carrying `tracks` as its counterexample.
    private func verdict(counterexample tracks: [String: [CanonicalValue]]) -> SpecVerdict {
        let diff = BehavioralDiff.compare(
            baseline: Trace(name: "base", events: []),
            candidate: Trace(name: "candidate", events: []),
            comparison: .strict
        )
        return SpecVerdict(
            result: VerificationResult(
                diff: diff,
                coverage: Coverage(declared: [], exercised: [], gaps: [], domainExercised: [])
            ),
            orderingsExplored: 1,
            failingOrder: nil,
            counterexample: CassetteData(tracks: tracks),
            exploration: Exploration(
                orderingsExplored: 1,
                orderingsAvailable: 1,
                orderingsAreExact: true,
                variantsPerOrdering: 1,
                outOfOrderExplored: 0,
                boundaryEdgesScheduled: 0,
                boundaryEdgesCovered: 0,
                combinedVariantsCovered: 0
            ),
            qualification: Qualification(
                coveredClasses: [],
                operations: 1,
                probes: 1,
                seamPositions: [:],
                blindSpots: nil
            ),
            violatedPreconditions: nil
        )
    }
}
