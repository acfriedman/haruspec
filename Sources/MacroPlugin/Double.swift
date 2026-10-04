import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Double<Protocol> (the stand-in)

/// Emits the double: a recording stand-in for a collaborator, with **nothing behind the boundary**.
///
/// A hand-written double is a second implementation of the collaborator, and a second implementation
/// can drift. The honest double records the call and does nothing: the interaction at the boundary is
/// the behavior a differential checks, and everything past it is fixture. Where the subject *reads* a
/// return or a property, the value is not emulated state but **generated input** — synthesized as a
/// seam read keyed `"<label>.<member>"`, so it defaults to the type's zero, is recorded into the plan,
/// sweeps when a spec declares a domain for that key in `.vary`, and replays identically.
///
/// Collections return their genuine empty, an optional custom type returns `nil`, and a required
/// custom type — which has no universal zero — resolves the factory the spec declared with
/// `.generates(_:_:)`, trapping fail-fast at the first call when none was.
enum DoubleEmitter {
    /// The generated `Double<Protocol>` stand-in.
    ///
    /// - Parameters:
    ///   - proto: The pasted protocol the double conforms to.
    ///   - label: The collaborator's stable trace label, the root of every event and seam key.
    ///   - context: The expansion context, which locates the protocol's own file for the origin.
    /// - Returns: The double's class declaration.
    static func double(
        for proto: ProtocolDeclSyntax,
        label: String,
        context: some MacroExpansionContext
    ) -> DeclSyntax {
        let generatedName = "Double\(proto.name.text)"
        let protoName = proto.name.text

        // The generated code is the double's whole behavior, so — unlike a forwarder, whose behavior
        // lives in the wrapped Obj-C class — its origin points at the protocol's own file.
        let file = context.location(of: proto, at: .afterLeadingTrivia, filePathMode: .fileID)?
            .file.trimmedDescription

        var members: [String] = []
        for member in proto.memberBlock.members {
            let decl = member.decl
            if let function = decl.as(FunctionDeclSyntax.self), function.body == nil {
                if isStaticOrClass(function.modifiers) {
                    continue
                }
                members.append(doubleMethod(function, label: label, symbol: generatedName, file: file))
            } else if let variable = decl.as(VariableDeclSyntax.self), !isStaticOrClass(variable.modifiers),
                      let property = doubleProperty(variable, label: label, symbol: generatedName, file: file) {
                members.append(property)
            } else if let initializer = decl.as(InitializerDeclSyntax.self) {
                members.append(refusingInit(initializer, generatedName: generatedName))
            }
        }

        // The boundaries this double serves, read off the pasted protocol's inheritance clause — the
        // refinement is the registry entry `SeamContext.resolve(_:)` matches by type identity. The
        // protocol serves itself too: a Swift boundary the adopter owns is stamped directly, with no
        // refining paste in between.
        let refined = (proto.inheritanceClause?.inheritedTypes ?? [])
            .map(\.type.trimmedDescription)
            .filter { $0 != "AnyObject" && $0 != "NSObjectProtocol" && $0 != "Sendable" }
        let boundaries = [protoName] + refined
        let served = "\n    static var servedBoundaries: [Any.Type] { "
            + "[\(boundaries.map { "\($0).self" }.joined(separator: ", "))] }\n"

        // NSObject-rooted for the same reason the forwarder is: the double usually backs an Obj-C
        // `id<Protocol>` injection point. `SeamDouble` is what lets `context.double(_:)` construct and
        // register it in one move.
        let source = """
        final class \(generatedName): NSObject, \(protoName), SeamDouble {
            private let __seams: SeamContext
            init(_ seams: SeamContext) { __seams = seams; super.init() }

            nonisolated var traceLabel: String { \(quotedLiteral(label)) }
        \(served)
        \(members.joined(separator: "\n\n"))
        }
        """
        return DeclSyntax("\(raw: source)")
    }

    /// The double's witness of a pasted `init` requirement, which traps naming the route that builds a
    /// double. Conformance demands a witness, but a double is built by the capture, never by the
    /// subject's construction contract.
    ///
    /// - Parameters:
    ///   - initializer: The pasted `init` requirement to witness.
    ///   - generatedName: The double's class name, which the trap message names.
    /// - Returns: The witness's source.
    private static func refusingInit(_ initializer: InitializerDeclSyntax, generatedName: String) -> String {
        let message = "\(generatedName) is a stand-in, built by the capture: context.double(\(generatedName).self)"
        return "    convenience init\(initializer.signature.parameterClause.trimmedDescription) {\n"
            + "        preconditionFailure(\(quotedLiteral(message)))\n"
            + "    }"
    }

    /// One synthesized property, whose read is a generated value and whose write is recorded and kept
    /// nowhere. It is the property form of a method's seam read and a `Void` method's no-op.
    ///
    /// - Parameters:
    ///   - variable: The protocol's `var` requirement.
    ///   - label: The boundary's trace label; the seam key and the write's event are
    ///     `"<label>.<name>"`.
    ///   - symbol: The double's class name, recorded as the write's origin.
    ///   - file: The stamped protocol's `#fileID`, recorded as the write's origin; `nil` when the
    ///     expansion context cannot locate it.
    /// - Returns: The property's source, or `nil` when the requirement is not a simple typed `var`.
    ///
    /// A read is not recorded, as a forwarder's read is not; it returns the seam `"<label>.<name>"`,
    /// defaulted to the type's zero. A `{ get set }` requirement's setter records the write as a
    /// `stateChange`.
    private static func doubleProperty(
        _ variable: VariableDeclSyntax,
        label: String,
        symbol: String,
        file: String?
    ) -> String? {
        guard variable.bindingSpecifier.tokenKind == .keyword(.var),
              let binding = variable.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let type = binding.typeAnnotation?.type.trimmedDescription
        else { return nil }
        let key = "\(label).\(name)"
        let read = defaultedReturn(type: type, key: key)
        guard case let .accessors(accessors) = binding.accessorBlock?.accessors,
              accessors.contains(where: { $0.accessorSpecifier.tokenKind == .keyword(.set) })
        else {
            return hasAsyncGetter(binding)
                ? "    var \(name): \(type) { get async { \(read) } }"
                : "    var \(name): \(type) { \(read) }"
        }
        let origin = originArguments(label: label, symbol: symbol, sourceExpression: file)
        return """
            var \(name): \(type) {
                get { \(read) }
                set {
                    let __oracle = TraceContext.active
                    __oracle?.noteOrigin(\(origin))
                    __oracle?.stateChange(\(quotedLiteral(key)), subject: self, \
        value: RuntimeValue.canonical(newValue as Any))
                }
            }
        """
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
        var innerBody = defaultedReturn(type: function.signature.returnClause?.type.trimmedDescription, key: key)
        if let completion = CompletionBlock.of(function) {
            innerBody = delivery(completion, key: key) + (innerBody.isEmpty ? "" : "\n\(innerBody)")
        }
        // Answers are per argument tuple, so a subject asking in another order gets the same ones.
        let arguments = CompletionBlock.recordedArgumentNames(of: function)
        if !innerBody.isEmpty, !arguments.isEmpty {
            let pairs = arguments.map { "\"\($0)\": RuntimeValue.canonical(\($0) as Any)" }.joined(separator: ", ")
            innerBody = "let __seams = self.__seams.arguments([\(pairs)])\n" + innerBody
        }
        let body = tracedBody(
            function: function,
            label: key,
            innerBody: innerBody,
            timed: false,
            origin: originArguments(label: label, symbol: symbol, sourceExpression: file)
        )
        let generics = function.genericParameterClause?.trimmedDescription ?? ""
        let whereClause = function.genericWhereClause.map { " \($0.trimmedDescription)" } ?? ""
        return "    func \(function.name.text)\(generics)\(function.signature.trimmedDescription)"
            + "\(whereClause) {\n\(indent(body))\n    }"
    }

    /// The double's answer through a completion block, delivered at once, inside the call. Each
    /// block argument is generated input, exactly as a return of its type would be.
    ///
    /// - Parameters:
    ///   - completion: The method's completion block.
    ///   - key: The method's seam key and event label, `"<label>.<method>"`.
    /// - Returns: The statements that generate the arguments and deliver them.
    ///
    /// Each argument is a seam read keyed `"<label>.<method>.<block>.<argument>"`, defaulted to the
    /// type's zero and swept when a spec declares a domain for the key. The delivery is recorded as
    /// a forwarder records it.
    ///
    /// The Cocoa error slot (`(any Error)?`) is the failure branch, which a nil default alone would
    /// never reach. Its key reads as a `Bool` — whether this delivery fails — and a failing delivery
    /// builds its error through the factory the spec declared for `any Error`.
    private static func delivery(_ completion: CompletionBlock, key: String) -> String {
        let blockKey = "\(key).\(completion.label)"
        let generated = zip(completion.arguments, completion.boundNames).map { argument, name in
            let argumentKey = "\(blockKey).\(argument.key)"
            // An imported `NSError *` slot spells the class; the factory builds any `Error`.
            let bridged = argument.type.contains("NSError") ? ".map { $0 as NSError }" : ""
            let value = isErrorSlot(argument.type)
                ? "__seams.failure(\(quotedLiteral(argumentKey)))\(bridged)"
                : generatedValue(type: argument.type, key: argumentKey)
            return "let \(name): \(argument.type) = \(value)"
        }
        let bound = completion.boundNames.joined(separator: ", ")
        let call = "\(completion.name)\(completion.isOptional ? "?" : "")(\(bound))"
        return (generated + [completion.recordedDelivery(eventLabel: blockKey, deliver: call)]).joined(separator: "\n")
    }

    /// Returns the generated value a return of `type` would produce, as an expression.
    ///
    /// - Parameters:
    ///   - type: The value's spelled type.
    ///   - key: The seam key the value reads.
    /// - Returns: The expression `defaultedReturn` would return.
    private static func generatedValue(type: String, key: String) -> String {
        String(defaultedReturn(type: type, key: key).dropFirst("return ".count))
    }

    /// The synthesized body: nothing for `Void`, a seam read with the type's zero as its default for
    /// scalar returns, the type's empty for collections, `nil` for optionals, and — for a custom type,
    /// which has no universal zero — the factory the spec declared with `.generates(_:_:)`, resolved
    /// fail-fast at the first call. Every seam key doubles as the `.vary` override point —
    /// `Seam("Inventory.stock", .int(0 ... 5))` turns a zero into swept surface with no change to the
    /// double, and a factory's field keys (`"<key>.<field>"`) sweep the same way.
    private static func defaultedReturn(type returnType: String?, key: String) -> String {
        guard let returnType else { return "" }
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
