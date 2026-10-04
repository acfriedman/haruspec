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
        of _: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let spec = declaration.as(StructDeclSyntax.self) else {
            throw MacroError("@Continuous can only be attached to a struct conforming to SpecProviding")
        }
        let name = spec.name.text
        return [
            """
            struct \(raw: name)Continuous {
                @Testing.Test(arguments: \(raw: name)().continuousModes())
                func continuousRunHolds(_ mode: ContinuousMode) async throws {
                    try await \(raw: name)().checkContinuous(mode, in: Self.self)
                }
            }
            """
        ]
    }
}
