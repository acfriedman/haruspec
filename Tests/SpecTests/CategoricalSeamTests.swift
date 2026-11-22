import Foundation
import HaruspecCore
import HaruspecSeams
import HaruspecSpec
import XCTest

// The categorical axis: inputs whose interesting values are named rather than ranged. Without it a
// spec has to smuggle the choice through an int (`seams.int("promoValid") == 1 ? "SAVE10" : "NOPE"`),
// which hides what is being varied from anyone reading the spec.

private final class Greeter {
    private(set) var greetings: [String] = []
    func greet(_ salutation: String) {
        greetings.append(salutation)
    }
}

final class CategoricalSeamTests: XCTestCase {
    func testEveryDeclaredValueIsReachable() async {
        // Recording explores the declared surface, so the generated cassettes should between them
        // cover the whole set rather than pinning one value.
        var seen: Set<String> = []
        _ = await spec(recording: { seen.insert($0) }).record()

        XCTAssertEqual(seen, ["hello", "hola", "bonjour"])
    }

    func testOnlyDeclaredValuesAreEverProduced() async {
        var seen: Set<String> = []
        _ = await spec(recording: { seen.insert($0) }).record()

        XCTAssertTrue(seen.isSubset(of: ["hello", "hola", "bonjour"]))
    }

    func testTheSameSeedReplaysTheSameChoices() async {
        var first: [String] = []
        var second: [String] = []
        _ = await spec(recording: { first.append($0) }).record()
        _ = await spec(recording: { second.append($0) }).record()

        XCTAssertEqual(first, second, "generation is seeded; a categorical draw must be reproducible")
    }

    private func spec(recording: @escaping (String) -> Void) -> BaselinedSpec<Greeter> {
        Spec<Greeter>("greeter.categorical")
            .operations {
                Op("greet") { sut, seams in
                    let salutation = seams.string("salutation", default: "hello")
                    recording(salutation)
                    sut.greet(salutation)
                }
            }
            .vary { Seam("salutation", .oneOf("hello", "hola", "bonjour")) }
            .baselined { _ in Greeter() }
    }

    /// The golden probe reads each declared seam's first interior value — for a named set, its first
    /// name — never the op's fallback `default`: the template must sit inside the declared surface,
    /// and a default outside the set would verify one input nobody declared.
    func testTheGoldenProbeReadsTheDeclaredDomainNotTheOpDefault() async {
        var seen: Set<String> = []
        let pinned = Spec<Greeter>("greeter.pinned")
            .operations {
                Op("greet") { sut, seams in
                    let salutation = seams.string("salutation", default: "undeclared")
                    seen.insert(salutation)
                    sut.greet(salutation)
                }
            }
            .vary { Seam("salutation", .oneOf("only")) }
            .baselined { _ in Greeter() }
        _ = await pinned.record()

        XCTAssertEqual(seen, ["only"])
    }

    func testIntSetsVaryOverExactlyTheDeclaredValues() async {
        var seen: Set<Int64> = []
        let spec = Spec<Greeter>("greeter.ints")
            .operations {
                Op("greet") { sut, seams in
                    let qty = seams.int("qty", default: 0)
                    seen.insert(qty)
                    sut.greet("\(qty)")
                }
            }
            .vary { Seam("qty", .oneOf([0, 7, 999])) }
            .baselined { _ in Greeter() }
        _ = await spec.record()

        XCTAssertEqual(seen, [0, 7, 999], "a categorical int must not fill the gaps between values")
    }
}
