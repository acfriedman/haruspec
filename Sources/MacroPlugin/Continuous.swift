import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - @Continuous (peer: a spec's continuous suite)

/// Emits the test suite that runs a spec's continuous side, so a spec opts into CI by its attribute
/// rather than by a hand-copied suite.
///
/// The suite is its own type because census and record runs select it by name while campaign suites
/// stand down, and its one test is parameterized by the modes the environment selects, empty in an
/// ordinary run. It names itself, so the census records which suite to run locally.
public struct ContinuousMacro: PeerMacro {
    public static func expansion(
        of attribute: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let spec = declaration.as(StructDeclSyntax.self) else {
            throw MacroError("@Continuous can only be attached to a struct conforming to SpecProviding")
        }
        guard case let .argumentList(arguments) = attribute.arguments,
              let baseline = arguments.first(where: { $0.label?.text == "baseline" })?.expression else {
            throw MacroError("@Continuous needs the baseline CI watches: @Continuous(baseline: LegacyType.self)")
        }
        let name = spec.name.text
        let subject = "\(name)().baselined(on: \(baseline.trimmedDescription))"
        return [
            """
            struct \(raw: name)Continuous {
                @Testing.Test(arguments: \(raw: subject).continuousModes())
                func continuousRunHolds(_ mode: ContinuousMode) async throws {
                    try await \(raw: subject).checkContinuous(mode, in: Self.self)
                }
            }
            """
        ]
    }
}
