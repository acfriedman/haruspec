import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - @Haruspec (peer: everything a boundary protocol yields)

/// The one stamp on a pasted boundary protocol, emitting every role at once under one label. It does
/// not say what the protocol is *for*, because a spec decides that by using it.
///
/// The roles:
///
/// - `Traced<Protocol>`, the forwarder, used when the protocol is a spec's subject;
/// - `Derived<Protocol>`, the op catalog, used when a spec derives its operations from it;
/// - `Double<Protocol>`, the stand-in, used when another subject's `init` takes the protocol (or a
///   protocol it refines) as a collaborator.
///
/// Because the roles share one label, a boundary records the same event names whether it is driven
/// through its forwarder or stood in for by its double — so a collaborator today can be migrated as
/// a subject tomorrow with nothing re-stamped. A collaborator that was never stamped fails loudly at
/// the first capture that needs it, naming the stamp to write.
public struct HaruspecMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
            throw MacroError("@Haruspec can only be attached to a protocol")
        }
        // The label defaults to the protocol's name; a string pins it when the two differ — a
        // rename that must keep matching old recordings, or a name another type already holds.
        let label = stringArgument(of: node) ?? proto.name.text
        let timed = boolArgument(of: node, name: "timed") ?? false
        return [
            ForwarderEmitter.forwarder(for: proto, label: label, timed: timed),
            CatalogEmitter.catalog(for: proto, label: label),
            DoubleEmitter.double(for: proto, label: label, context: context)
        ]
    }
}
