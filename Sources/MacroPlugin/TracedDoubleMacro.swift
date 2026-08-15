import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - @TracedDouble (peer)

/// Generate a recording test double from a pasted protocol — the collaborator counterpart of
/// `@TracedForwarder`, with **nothing behind the boundary**.
///
/// A hand-written double is a second implementation of the collaborator, and a second implementation
/// can drift. The honest double records the call and does nothing: the interaction at the boundary is
/// the behavior a differential checks, and everything past it is fixture. Where the subject *reads* a
/// return, the value is not emulated state but **generated input** — synthesized as a seam read keyed
/// `"<label>.<method>"`, so it defaults to the type's zero, is recorded into the plan, sweeps when a
/// spec declares a domain for that key in `.vary`, and replays identically.
///
/// Collections return their genuine empty, an optional custom type returns `nil`, and a required
/// custom type — which has no universal zero — resolves the factory the spec declared with
/// `.generates(_:_:)`, trapping fail-fast at the first call when none was.
public struct TracedDoubleMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
            throw MacroError("@TracedDouble can only be attached to a protocol")
        }
        guard let label = stringArgument(of: node, name: "label") else {
            throw MacroError("@TracedDouble requires a 'label:' string naming the collaborator boundary")
        }
        let protoName = proto.name.text
        let generatedName = stringArgument(of: node, name: "as") ?? "Traced\(protoName)"

        // The generated code is the double's whole behavior, so — unlike a forwarder, whose behavior
        // lives in the wrapped Obj-C class — its origin points at the protocol's own file.
        let file = context.location(of: declaration, at: .afterLeadingTrivia, filePathMode: .fileID)?
            .file.trimmedDescription

        var members: [String] = []
        for member in proto.memberBlock.members {
            let decl = member.decl
            if let function = decl.as(FunctionDeclSyntax.self), function.body == nil {
                if isStaticOrClass(function.modifiers) {
                    continue
                }
                members.append(doubleMethod(function, label: label, symbol: generatedName, file: file))
            } else if let variable = decl.as(VariableDeclSyntax.self), !isStaticOrClass(variable.modifiers) {
                throw MacroError(
                    "@TracedDouble cannot synthesize the property requirement "
                        + "'\(variable.trimmedDescription)' — hand-write this double"
                )
            }
        }

        // NSObject-rooted for the same reason the forwarder is: the double usually backs an Obj-C
        // `id<Protocol>` injection point. `SeamDouble` is what lets `context.double(_:)` construct and
        // register it in one move.
        let source = """
        final class \(generatedName): NSObject, \(protoName), SeamDouble {
            private let __seams: SeamContext
            init(_ seams: SeamContext) { __seams = seams; super.init() }

            nonisolated var traceLabel: String { \(quotedLiteral(label)) }

        \(members.joined(separator: "\n\n"))
        }
        """
        return [DeclSyntax("\(raw: source)")]
    }

    /// One synthesized method: records `call`/`ret` exactly as a forwarder would, around a body that
    /// is a no-op — or, for a value-returning requirement, a generated seam read.
    private static func doubleMethod(
        _ function: FunctionDeclSyntax,
        label: String,
        symbol: String,
        file: String?
    ) -> String {
        let key = "\(label).\(function.name.text)"
        let body = tracedBody(
            function: function,
            label: key,
            innerBody: defaultedReturn(of: function, key: key),
            timed: false,
            origin: originArguments(label: label, symbol: symbol, sourceExpression: file)
        )
        let generics = function.genericParameterClause?.trimmedDescription ?? ""
        let whereClause = function.genericWhereClause.map { " \($0.trimmedDescription)" } ?? ""
        return "    func \(function.name.text)\(generics)\(function.signature.trimmedDescription)"
            + "\(whereClause) {\n\(indent(body))\n    }"
    }

    /// The synthesized body: nothing for `Void`, a seam read with the type's zero as its default for
    /// scalar returns, the type's empty for collections, `nil` for optionals, and — for a custom type,
    /// which has no universal zero — the factory the spec declared with `.generates(_:_:)`, resolved
    /// fail-fast at the first call. Every seam key doubles as the `.vary` override point —
    /// `Seam("Inventory.stock", .int(0 ... 5))` turns a zero into swept surface with no change to the
    /// double, and a factory's field keys (`"<key>.<field>"`) sweep the same way.
    private static func defaultedReturn(of function: FunctionDeclSyntax, key: String) -> String {
        guard let returnType = function.signature.returnClause?.type.trimmedDescription else { return "" }
        // `Int!` accepts a bare `Int`, so a defaulted read satisfies it. A `?` is remembered: `nil` is
        // the one genuine zero an *optional* custom type has. An IUO custom type is treated as
        // required — `!` is legacy spelling for "callers assume non-nil", and a silent nil default
        // would move the failure into the subject's force-unwrap.
        let isOptional = returnType.hasSuffix("?")
        let bare = isOptional || returnType.hasSuffix("!")
            ? String(returnType.dropLast())
            : returnType
        let read = quotedLiteral(key)
        switch bare {
        case "Void", "()":
            return ""
        case "Int", "NSInteger":
            return "return Int(__seams.int(\(read), default: 0))"
        case "Int64":
            return "return __seams.int(\(read), default: 0)"
        case "Int32":
            return "return Int32(__seams.int(\(read), default: 0))"
        case "UInt":
            return "return UInt(__seams.int(\(read), default: 0))"
        case "Double":
            return "return __seams.double(\(read), default: 0)"
        case "Float":
            return "return Float(__seams.double(\(read), default: 0))"
        case "CGFloat":
            return "return CGFloat(__seams.double(\(read), default: 0))"
        case "Bool":
            return "return __seams.bool(\(read), default: false)"
        case "String":
            return "return __seams.string(\(read), default: \"\")"
        default:
            if let empty = emptyLiteral(for: bare) {
                return "return \(empty)"
            }
            // A custom type: the spec's declared factory, or nil where the signature allows it.
            return isOptional
                ? "return __seams.valueIfDeclared(\(bare).self, key: \(read))"
                : "return __seams.value(\(bare).self, key: \(read))"
        }
    }

    /// The genuine empty for a collection-shaped return, or `nil` when the type isn't one. Sugar and
    /// generic spellings alike, so a pasted Obj-C interface's `[String: Any]` and a Swift protocol's
    /// `Dictionary<String, Any>` land on the same zero.
    private static func emptyLiteral(for type: String) -> String? {
        if type.hasPrefix("[") {
            return topLevelColon(in: type) ? "[:]" : "[]"
        }
        if type.hasPrefix("Array<") || type.hasPrefix("Set<") {
            return "[]"
        }
        if type.hasPrefix("Dictionary<") {
            return "[:]"
        }
        return nil
    }

    /// Whether a `[...]` spelling is a dictionary — a `:` at bracket depth 1 (`[String: Int]`), not
    /// one nested inside an element type (`[[String: Int]]` is an *array* of dictionaries).
    private static func topLevelColon(in type: String) -> Bool {
        var depth = 0
        for character in type {
            switch character {
            case "[", "<", "(": depth += 1
            case "]", ">", ")": depth -= 1
            case ":" where depth == 1: return true
            default: break
            }
        }
        return false
    }
}
