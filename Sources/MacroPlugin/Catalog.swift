import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Derived<Protocol> (the op catalog)

/// Emits a spec's op catalog from the boundary protocol: one `DerivedOp` per method requirement,
/// with the binding written mechanically and each parameter mapped by type heuristic — integers and
/// floats to engine-default domains, `Bool` to both values, a custom type to its `SeamGenerated`
/// factory, and `String` (or anything unmappable) left *pending*, to trap when a spec is bound, with
/// the declaration to write. A spec over the protocol adopts it by default, through the forwarder's
/// `derivedCatalog`; the authored residue arrives as `Amend(...)` amendments in the spec's init block.
///
/// Property requirements derive as **observed properties** (`DerivedProperty`) rather than ops:
/// state is snapshot at the capture boundary, not driven as calls.
/// Skipped, deliberately: `static`/`class` members (no instance) and generic requirements (no single
/// binding to write). A skipped requirement that matters becomes an authored `Op` in a plain
/// `.operations` block. An empty catalog is legitimate: the stamp does not know whether a spec will
/// ever drive this protocol, and a catalog no spec adopts costs nothing.
enum CatalogEmitter {
    /// The generated `Derived<Protocol>` catalog.
    ///
    /// - Parameters:
    ///   - proto: The pasted protocol the catalog drives.
    ///   - label: The trace label property entries carry, matching what the forwarder records.
    /// - Returns: The catalog's enum declaration.
    static func catalog(for proto: ProtocolDeclSyntax, label: String) -> DeclSyntax {
        let protoName = proto.name.text
        let system = "any \(protoName)"
        let (entries, properties) = derivedEntries(of: proto, labelRoot: label)

        // With a pasted init requirement, construction derives: the forwarder's `init(resolving:_:)`
        // builds any conformer from its metatype, so the baseline's and the candidate's construction
        // closures both collapse into the catalog.
        let forwarder = "Traced\(protoName)"
        var systemEntry = ""
        let hasPastedInit = proto.memberBlock.members.contains { $0.decl.is(InitializerDeclSyntax.self) }
        // The conformer arrives as a bare `Any.Type`: a spec generic over `any Proto` cannot spell
        // `any Proto.Type`, so conformance is checked here, naming the line to write.
        if hasPastedInit {
            let refusal = "\\(type) does not conform to \(protoName) — declare it: "
                + "extension \\(type): \(protoName) {}"
            systemEntry = """


                nonisolated static var derivedSystem: ((SeamContext, Any.Type) -> \(system))? {
                    { context, type in
                        guard let conformer = type as? any \(protoName).Type else {
                            preconditionFailure("\(refusal)")
                        }
                        return \(forwarder)(resolving: context, conformer)
                    }
                }
            """
        }

        // `var` requirements derive as observed properties: the spec snapshots each at the capture
        // boundary and scopes the write-timeline diff to exactly these labels.
        var propertiesEntry = ""
        if !properties.isEmpty {
            propertiesEntry = """


                nonisolated static var derivedProperties: [DerivedProperty<\(system)>] {
                    [
            \(properties.joined(separator: ",\n"))
                    ]
                }
            """
        }

        // `nonisolated` keeps each closure nonisolated under a module's default `MainActor` isolation,
        // where a capture refuses an op that runs on an actor.
        let source = """
        enum Derived\(protoName): DerivedOperations {
            typealias System = \(system)
            nonisolated static var derivedOps: [DerivedOp<\(system)>] {
                [
        \(entries.joined(separator: ",\n"))
                ]
            }
        \(systemEntry)\(propertiesEntry)
        }
        """
        return DeclSyntax("\(raw: source)")
    }

    /// Returns the catalog's entries for the protocol's requirements: methods become op entries, `var`s
    /// become observed properties.
    ///
    /// - Parameters:
    ///   - proto: The pasted protocol whose requirements the catalog covers.
    ///   - labelRoot: The trace label of the stamped protocol, which property labels extend.
    /// - Returns: The `DerivedOp(...)` entries and the `DerivedProperty(...)` entries, each as Swift source;
    ///   either list is empty when the protocol has no requirement of that kind that derives.
    private static func derivedEntries(
        of proto: ProtocolDeclSyntax,
        labelRoot: String
    ) -> (ops: [String], properties: [String]) {
        var entries: [String] = []
        var properties: [String] = []
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

    /// Returns one `DerivedProperty(...)` entry for a `var` requirement. A `{ get async }` requirement —
    /// how an actor port witnesses a property — reads back with `await`.
    ///
    /// - Parameters:
    ///   - name: The property requirement's name.
    ///   - labelRoot: The trace label of the stamped protocol; the entry's label is this root, a dot,
    ///     and `name`.
    ///   - isAsync: Whether the requirement's getter is `async`.
    /// - Returns: The entry as Swift source.
    private static func derivedProperty(_ name: String, labelRoot: String, isAsync: Bool) -> String {
        "            DerivedProperty(\(quotedLiteral(name)), "
            + "label: \(quotedLiteral("\(labelRoot).\(name)"))) { __sut in \(isAsync ? "await " : "")__sut.\(name) }"
    }

    /// Returns one `DerivedOp(...)` entry: the argument list and the forwarding call, both written from
    /// the signature alone.
    ///
    /// - Parameter function: A non-static, non-generic method requirement of the pasted protocol.
    /// - Returns: The entry as Swift source.
    private static func derivedOp(_ function: FunctionDeclSyntax) -> String {
        let label = function.name.text
        // A completion block is not generated input: the op hands in a block that signals, and
        // waits for it. Not across a global-actor hop, which a synchronous start cannot make — such
        // a requirement keeps the general rule, a pending argument.
        let completion = function.attributes.isEmpty ? CompletionBlock.of(function) : nil
        let parameters = Array(function.signature.parameterClause.parameters)
        let generated = completion == nil ? parameters : parameters.dropLast()
        let mapped = generated.enumerated().map { position, parameter in
            map(parameter, at: position)
        }

        // Parenthesized so a forced cast passed to an IUO parameter (`Product!`) reads as a value,
        // not as a cast the compiler warns will be treated as optional.
        var passed = zip(generated, mapped).map { parameter, argument -> String in
            let external = parameter.firstName.text
            return external == "_" ? "(\(argument.value))" : "\(external): (\(argument.value))"
        }
        if let completion, let last = parameters.last {
            let ignored = completion.arguments.isEmpty
                ? ""
                : " \(completion.arguments.map { _ in "_" }.joined(separator: ", ")) in"
            let signal = "{\(ignored) __delivered() }"
            passed.append(last.firstName.text == "_" ? signal : "\(last.firstName.text): \(signal)")
        }
        let call = passed.joined(separator: ", ")

        let effects = function.signature.effectSpecifiers
        let prefix = "\(effects?.throwsClause != nil ? "try? " : "")\(effects?.asyncSpecifier != nil ? "await " : "")"
        let returnType = function.signature.returnClause?.type.trimmedDescription
        let returnsValue = returnType != nil && returnType != "Void" && returnType != "()"
        // `try?` yields an optional even for Void, so a throwing call is always discarded explicitly.
        let discard = returnsValue || effects?.throwsClause != nil ? "_ = " : ""
        // A requirement pinned to a global actor (`@MainActor func display`) is a hop from the op's
        // own isolation, and Swift 6 refuses to send a non-`Sendable` system across it. The system
        // is the conformer the spec built for this capture and nothing else holds it, so it is
        // handed over through an unchecked holder — the same answer the forwarder gives by reading
        // the conformer off its own `@unchecked Sendable` self.
        let hops = !function.attributes.isEmpty
        let receiver = hops ? "__sent.value" : "__sut"
        let handOver = hops ? "let __sent = UncheckedHandOver(__sut)\n                " : ""
        var invocation = "\(handOver)\(discard)\(prefix)\(receiver).\(label)(\(call))"
        if completion != nil {
            // The start runs inside the wait, so a throw reaches it rather than `try?`: a refusal
            // ends the wait, because the block will never run.
            let isThrows = effects?.throwsClause != nil
            let start = "\(returnsValue ? "_ = " : "")\(isThrows ? "try " : "")\(receiver).\(label)(\(call))"
            invocation = "await CompletionDelivery.awaited { __delivered in \(start) }"
        }

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

    /// Returns the type heuristic for one parameter: which `DerivedArgument` it declares, and the
    /// expression that reads its generated value back at the call.
    ///
    /// - Parameters:
    ///   - parameter: A parameter of the method requirement.
    ///   - position: The parameter's zero-based index among the method's generated arguments.
    /// - Returns: The `DerivedArgument` as a Swift expression (`.pending` when no heuristic fits), and a
    ///   Swift expression reading the generated value out of `__values` as the parameter's type.
    ///
    /// Imported IUO/optional sugar is stripped — a generated value is always concrete, and a `T`
    /// satisfies a `T!`/`T?` parameter.
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
