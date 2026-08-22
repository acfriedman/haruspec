import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - @DerivedOps (peer)

/// Derives a spec's op catalog from the boundary protocol: one `DerivedOp` per method requirement,
/// with the binding written mechanically and each parameter mapped by type heuristic — integers and
/// floats to engine-default domains, `Bool` to both values, a custom type to its `SeamGenerated`
/// factory, and `String` (or anything unmappable) left *pending*, to trap at spec construction with
/// the declaration to write. The authored residue arrives later, as `Amend(...)` amendments in
/// `.operations(derivedFrom:)`.
///
/// Property requirements derive as **observed properties** (`DerivedProperty`) rather than ops:
/// state is snapshot at the capture boundary and its writes join the diff, not driven as calls.
/// Skipped, deliberately: `static`/`class` members (no instance) and generic requirements (no single
/// binding to write). A skipped requirement that matters becomes an authored `Op` in a plain
/// `.operations` block.
public struct DerivedOpsMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
            throw MacroError("@DerivedOps can only be attached to a protocol")
        }
        let protoName = proto.name.text
        let system = "any \(protoName)"

        let (entries, properties) = derivedEntries(of: proto)
        guard !entries.isEmpty else {
            throw MacroError(
                "@DerivedOps found no derivable requirement on '\(protoName)' — "
                    + "it derives instance methods only"
            )
        }

        // With a @TracedForwarder sibling and a pasted init requirement, the system factory derives
        // too: the forwarder's generated `init(resolving:)` carries the wiring, so the whole
        // `.system { }` closure collapses into the catalog.
        var systemEntry = ""
        let hasPastedInit = proto.memberBlock.members.contains { $0.decl.is(InitializerDeclSyntax.self) }
        if hasPastedInit, let forwarder = forwarderName(of: proto) {
            systemEntry = """

                static var derivedSystem: ((SeamContext) -> \(system))? {
                    { \(forwarder)(resolving: $0) }
                }
            """
        }

        // `var` requirements derive as observed properties: the spec snapshots each at the capture
        // boundary and scopes the write-timeline diff to exactly these labels.
        var propertiesEntry = ""
        if !properties.isEmpty {
            propertiesEntry = """


                static var derivedProperties: [DerivedProperty<\(system)>] {
                    [
            \(properties.joined(separator: ",\n"))
                    ]
                }
            """
        }

        let source = """
        enum Derived\(protoName): DerivedOperations {
            typealias System = \(system)
            static var derivedOps: [DerivedOp<\(system)>] {
                [
        \(entries.joined(separator: ",\n"))
                ]
            }
        \(systemEntry)\(propertiesEntry)
        }
        """
        return [DeclSyntax("\(raw: source)")]
    }

    /// Walks the requirements once: methods become op entries, `var`s become observed properties.
    private static func derivedEntries(of proto: ProtocolDeclSyntax) -> (ops: [String], properties: [String]) {
        var entries: [String] = []
        var properties: [String] = []
        let labelRoot = forwarderLabel(of: proto) ?? proto.name.text
        for member in proto.memberBlock.members {
            if let variable = member.decl.as(VariableDeclSyntax.self), !isStaticOrClass(variable.modifiers),
               let binding = variable.bindings.first,
               let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                properties.append(derivedProperty(name, labelRoot: labelRoot, isAsync: hasAsyncGetter(binding)))
                continue
            }
            guard let function = member.decl.as(FunctionDeclSyntax.self), function.body == nil,
                  !isStaticOrClass(function.modifiers), function.genericParameterClause == nil
            else { continue }
            entries.append(derivedOp(function))
        }
        return (entries, properties)
    }

    /// One `DerivedProperty(...)` entry for a `var` requirement. A `{ get async }` requirement —
    /// how an actor port witnesses a property — reads back with `await`.
    private static func derivedProperty(_ name: String, labelRoot: String, isAsync: Bool) -> String {
        "            DerivedProperty(\(quotedLiteral(name)), "
            + "label: \(quotedLiteral("\(labelRoot).\(name)"))) { __sut in \(isAsync ? "await " : "")__sut.\(name) }"
    }

    /// Whether a var requirement's accessor block declares `get async`.
    private static func hasAsyncGetter(_ binding: PatternBindingSyntax) -> Bool {
        guard case let .accessors(accessors) = binding.accessorBlock?.accessors else { return false }
        return accessors.contains { $0.effectSpecifiers?.asyncSpecifier != nil }
    }

    /// The sibling `@TracedForwarder`'s trace label, when the protocol carries one — property labels
    /// must match what the instrumentation records, and the forwarder's label is that root.
    private static func forwarderLabel(of proto: ProtocolDeclSyntax) -> String? {
        for element in proto.attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "TracedForwarder"
            else { continue }
            return stringArgument(of: attribute, name: "label")
        }
        return nil
    }

    /// The sibling `@TracedForwarder`'s generated type name, when the protocol carries one — the two
    /// macros never talk, but both see the same attribute list.
    private static func forwarderName(of proto: ProtocolDeclSyntax) -> String? {
        for element in proto.attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "TracedForwarder"
            else { continue }
            return stringArgument(of: attribute, name: "as") ?? "Traced\(proto.name.text)"
        }
        return nil
    }

    /// One `DerivedOp(...)` entry: the argument list and the forwarding call, both written from the
    /// signature alone.
    private static func derivedOp(_ function: FunctionDeclSyntax) -> String {
        let label = function.name.text
        let parameters = function.signature.parameterClause.parameters
        let mapped = parameters.enumerated().map { position, parameter in
            map(parameter, at: position)
        }

        let call = mapped.enumerated().map { position, argument -> String in
            let external = parameters[parameters.index(parameters.startIndex, offsetBy: position)].firstName.text
            return external == "_" ? argument.value : "\(external): \(argument.value)"
        }.joined(separator: ", ")

        let effects = function.signature.effectSpecifiers
        let prefix = "\(effects?.throwsClause != nil ? "try? " : "")\(effects?.asyncSpecifier != nil ? "await " : "")"
        let returnType = function.signature.returnClause?.type.trimmedDescription
        let returnsValue = returnType != nil && returnType != "Void" && returnType != "()"
        // `try?` yields an optional even for Void, so a throwing call is always discarded explicitly.
        let discard = returnsValue || effects?.throwsClause != nil ? "_ = " : ""
        let invocation = "\(discard)\(prefix)__sut.\(label)(\(call))"

        let arguments = mapped.isEmpty
            ? ""
            : ", arguments: [\(mapped.map(\.derived).joined(separator: ", "))]"
        let valuesName = mapped.isEmpty ? "_" : "__values"
        return """
                    DerivedOp(\(quotedLiteral(label))\(arguments)) { __sut, \(valuesName) in
                        \(invocation)
                    }
        """
    }

    /// The type heuristic for one parameter: which `DerivedArgument` it declares, and the expression
    /// that reads its generated value back at the call. Imported IUO/optional sugar is stripped —
    /// a generated value is always concrete, and a `T` satisfies a `T!`/`T?` parameter.
    private static func map(
        _ parameter: FunctionParameterSyntax,
        at position: Int
    ) -> (derived: String, value: String) {
        var name = (parameter.secondName ?? parameter.firstName).text
        if name == "_" {
            name = String(position)
        }
        let quoted = quotedLiteral(name)
        let spelled = parameter.type.trimmedDescription
        let bare = spelled.hasSuffix("!") || spelled.hasSuffix("?") ? String(spelled.dropLast()) : spelled

        switch bare {
        case "Int", "NSInteger":
            return (".int(\(quoted))", "__values[\(position)] as! Int")
        case "Int64", "Int32", "Int16":
            return (".int(\(quoted))", "\(bare)(__values[\(position)] as! Int)")
        // Width-fitted spans: the conversions trap on overflow, so each family gets the ladder its
        // type can represent.
        case "Int8":
            return (".int8(\(quoted))", "Int8(__values[\(position)] as! Int)")
        case "UInt", "UInt64", "UInt32", "UInt16":
            return (".uint(\(quoted))", "\(bare)(__values[\(position)] as! Int)")
        case "UInt8":
            return (".uint8(\(quoted))", "UInt8(__values[\(position)] as! Int)")
        case "Double":
            return (".double(\(quoted))", "__values[\(position)] as! Double")
        case "Float", "CGFloat":
            return (".double(\(quoted))", "\(bare)(__values[\(position)] as! Double)")
        case "Bool":
            return (".bool(\(quoted))", "__values[\(position)] as! Bool")
        case "String":
            return (".string(\(quoted))", "__values[\(position)] as! String")
        case "NSString":
            return (".string(\(quoted))", "(__values[\(position)] as! String) as NSString")
        default:
            // A plain type name is a model — `.generated` requires its `SeamGenerated` conformance,
            // and the compile error on a type without one is the prompt to write it. Anything else
            // (a collection, a closure) has no heuristic: pending, resolvable only by op override.
            if bare.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                return (
                    ".generated(\(quoted), \(bare).self)",
                    "__values[\(position)] as! \(bare)"
                )
            }
            return (
                ".pending(\(quoted), type: \(quotedLiteral(bare)))",
                "__values[\(position)] as! \(bare)"
            )
        }
    }
}
