import Foundation
@testable import HaruspecCore
import XCTest

// `canonicalString` is what every report prints a value as, and what dedup compares values by. A
// string in it is a JSON string literal: anything that would break a report line, or would not show
// as itself, is escaped — so a rendering is one line, and two different values never render alike.

final class CanonicalStringEscapingTests: XCTestCase {
    func testAStringEscapesWhatWouldBreakALine() {
        XCTAssertEqual(CanonicalValue.string("alpha\nbravo").canonicalString, #""alpha\nbravo""#)
        XCTAssertEqual(CanonicalValue.string("\r\n").canonicalString, #""\r\n""#)
        XCTAssertEqual(CanonicalValue.string("a\tb").canonicalString, #""a\tb""#)
    }

    func testQuotesAndBackslashesAreEscaped() {
        XCTAssertEqual(CanonicalValue.string(#"say "hi" \ bye"#).canonicalString, #""say \"hi\" \\ bye""#)
    }

    /// A character that renders as nothing, as a plain space, or as a line break would make two
    /// different values read alike, so it is written as its code point.
    func testACharacterThatDoesNotShowAsItselfIsEscaped() {
        let escapes: [(String, String)] = [
            ("\u{0}", #"\u0000"#),
            ("\u{1B}[31m", #"\u001B[31m"#),
            ("\u{7F}", #"\u007F"#),
            ("\u{85}", #"\u0085"#),
            ("a\u{200B}b", #"a\u200Bb"#),
            ("\u{202E}abc", #"\u202Eabc"#),
            ("a\u{2028}b", #"a\u2028b"#),
            ("a\u{2029}b", #"a\u2029b"#),
            ("no\u{A0}break", #"no\u00A0break"#),
            ("\u{3000}", #"\u3000"#),
            ("\u{FEFF}", #"\uFEFF"#),
            ("\u{378}", #"\u0378"#),
            ("\u{E0001}", #"\uDB40\uDC01"#)
        ]

        for (text, escaped) in escapes {
            XCTAssertEqual(CanonicalValue.string(text).canonicalString, "\"\(escaped)\"", text.debugDescription)
        }
    }

    /// Visible text reads as itself: accents, scripts, emoji, and the joiners and tags inside an
    /// emoji, which belong to it.
    func testVisibleTextIsLeftAlone() {
        let visible = [
            "COFFEE",
            "it's",
            "a b",
            "é",
            "e\u{301}",
            "日本語",
            "Ωμέγα",
            "😀",
            "👍🏽",
            "👨\u{200D}👩\u{200D}👧",
            "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
            "1\u{FE0F}\u{20E3}"
        ]

        for text in visible {
            XCTAssertEqual(CanonicalValue.string(text).canonicalString, "\"\(text)\"", text.debugDescription)
        }
    }

    func testAJoinerOutsideAnEmojiIsEscaped() {
        XCTAssertEqual(CanonicalValue.string("a\u{200D}b").canonicalString, #""a\u200Db""#)
        XCTAssertEqual(CanonicalValue.string("😀\u{200C}").canonicalString, #""😀\u200C""#, "a non-joiner joins no emoji")
    }

    /// A combining mark draws onto the character before it, so one with no base in the string
    /// would draw onto the opening quote, or onto an escape.
    func testAMarkWithNoBaseIsEscaped() {
        XCTAssertEqual(CanonicalValue.string("\u{301}a").canonicalString, #""\u0301a""#)
        XCTAssertEqual(CanonicalValue.string("\n\u{301}").canonicalString, #""\n\u0301""#)
        XCTAssertEqual(CanonicalValue.string("\u{20E3}").canonicalString, #""\u20E3""#)
    }

    func testAnObjectKeyIsEscapedLikeAString() {
        XCTAssertEqual(CanonicalValue.object(["a\nb": 1, "\"": 2]).canonicalString, #"{"\"":2,"a\nb":1}"#)
    }

    /// Unescaped, a quote and a comma inside one string rendered exactly like two strings.
    func testDistinctValuesNeverRenderAlike() {
        let two: CanonicalValue = ["a", "b"]
        let one: CanonicalValue = [#"a","b"#]

        XCTAssertNotEqual(two.canonicalString, one.canonicalString)
        XCTAssertNotEqual(
            CanonicalValue.object(["k": "v"]).canonicalString,
            CanonicalValue.object([#"k":"v"#: .null]).canonicalString
        )
    }

    /// Every rendering is JSON that decodes back to the value it came from, so no two values share a
    /// rendering, over values seeded with the characters most likely to collide or break a line.
    ///
    /// - Throws: The decoding error for a rendering that is not JSON.
    func testEveryRenderingDecodesBackToItsValue() throws {
        var generator = SplitMix64(seed: 0x16)
        for _ in 0 ..< 3000 {
            let value = CanonicalValue.random(depth: 0, using: &generator)
            let rendered = value.canonicalString

            let decoded = try JSONDecoder().decode(CanonicalValue.self, from: Data(rendered.utf8))

            XCTAssertEqual(decoded, value, rendered)
        }
    }

    /// No string renders over more than one line, or with a character hidden in it.
    func testEveryStringRendersOnOneLineWithNothingHidden() {
        var generator = SplitMix64(seed: 0x1616)
        for _ in 0 ..< 3000 {
            let rendered = CanonicalValue.string(.random(using: &generator)).canonicalString

            for character in rendered {
                let isEmoji = character.unicodeScalars.contains(where: \.properties.isEmojiPresentation)
                for scalar in character.unicodeScalars {
                    switch scalar.properties.generalCategory {
                    case .control, .lineSeparator, .paragraphSeparator, .unassigned:
                        XCTFail("\(rendered.debugDescription) shows U+\(String(scalar.value, radix: 16)) raw")
                    case .format where !isEmoji, .spaceSeparator where scalar != " ":
                        XCTFail("\(rendered.debugDescription) hides U+\(String(scalar.value, radix: 16))")
                    default:
                        break
                    }
                }
            }
        }
    }
}

// MARK: - Generation

/// A seeded generator, so a failing value reproduces.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

private extension String {
    /// The characters a rendering is most likely to get wrong: quotes, backslashes, separators,
    /// line breaks, controls, invisible and look-alike spaces, joiners, and emoji.
    static let awkward: [Unicode.Scalar] = [
        "\"",
        "\\",
        ",",
        " ",
        "=",
        ":",
        "{",
        "}",
        "[",
        "]",
        "\n",
        "\r",
        "\t",
        "\u{0}",
        "\u{8}",
        "\u{C}",
        "\u{1B}",
        "\u{7F}",
        "\u{85}",
        "\u{A0}",
        "\u{AD}",
        "\u{200B}",
        "\u{200C}",
        "\u{200D}",
        "\u{2028}",
        "\u{2029}",
        "\u{202E}",
        "\u{2066}",
        "\u{3000}",
        "\u{FE0F}",
        "\u{FEFF}",
        "\u{301}",
        "\u{E0001}",
        "\u{E0067}",
        "\u{378}",
        "é",
        "😀",
        "👨",
        "🏽",
        "日"
    ]

    /// Returns a string of up to eight scalars, half awkward and half anywhere in Unicode.
    ///
    /// - Parameter generator: The source of randomness.
    /// - Returns: A string, possibly empty.
    static func random(using generator: inout some RandomNumberGenerator) -> String {
        var scalars = String.UnicodeScalarView()
        for _ in 0 ..< Int.random(in: 0 ... 8, using: &generator) {
            if Bool.random(using: &generator) {
                scalars.append(awkward.randomElement(using: &generator)!)
            } else if let scalar = Unicode.Scalar(UInt32.random(in: 0 ... 0x10FFFF, using: &generator)) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

private extension CanonicalValue {
    /// Returns a value of any kind, nesting arrays and objects at most three deep.
    ///
    /// - Parameters:
    ///   - depth: How deep the value sits; at three, only scalars are generated.
    ///   - generator: The source of randomness.
    /// - Returns: A value whose doubles are never integral, which JSON would read back as ints.
    static func random(depth: Int, using generator: inout some RandomNumberGenerator) -> CanonicalValue {
        switch Int.random(in: depth < 3 ? 0 ... 6 : 0 ... 4, using: &generator) {
        case 0: .null
        case 1: .bool(.random(using: &generator))
        case 2: .int(.random(in: -1_000_000 ... 1_000_000, using: &generator))
        case 3: .double(Double(Int.random(in: -1000 ... 1000, using: &generator)) + 0.25)
        case 4: .string(.random(using: &generator))
        case 5: .array((0 ..< Int.random(in: 0 ... 3, using: &generator)).map { _ in
                random(depth: depth + 1, using: &generator)
            })
        default: .object(Dictionary(
                (0 ..< Int.random(in: 0 ... 3, using: &generator)).map { _ in
                    (String.random(using: &generator), random(depth: depth + 1, using: &generator))
                },
                uniquingKeysWith: { first, _ in first }
            ))
        }
    }
}
