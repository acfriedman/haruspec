import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Traced<Protocol> (the forwarder)

/// Emits the forwarder: a peer `final class` that wraps *any* conformer — `any Proto` — and
/// forwards every requirement 1:1, instrumented with the `call`/`ret` events of `tracedBody`. The
/// Obj-C baseline and a Swift port are wrapped by the same class, so both traces are
/// protocol-shaped by construction: a port's private helpers never appear, and product code carries
/// no Haruspec attribute.
///
/// Because the protocol keeps the imported IUOs verbatim (`checkout() -> Receipt!`), each forward is a
/// bare `__wrapped.checkout()` — no hand-written shim, no force-unwrap. Method requirements are traced;
/// a read-only `var x: T { get }` forwards as a plain computed property (reads are not effects), and a
/// `{ get set }` requirement's setter records the write as a `stateChange` before forwarding — a write
/// across the boundary is an interaction, compared like a call.
/// `static`/`class` requirements are skipped — no instance `self`.
///
/// A pasted `init` requirement is the construction contract every conformer carries, and what lets
/// the forwarder construct one from its metatype alone: `init(resolving:_:)` resolves each parameter
/// (the capture's center for a `NotificationCenter`, the conformance-matched double otherwise) and
/// wraps the result. The forwarder's own witness of that requirement traps — a forwarder wraps, it
/// never stands in for a conformer.
enum ForwarderEmitter {
    /// The generated `Traced<Protocol>` forwarder.
    ///
    /// - Parameters:
    ///   - proto: The pasted protocol the forwarder conforms to and wraps.
    ///   - label: The stable trace label, the root of every event the forwarder records.
    ///   - timed: Whether each forwarded method also records its duration as a signpost interval.
    /// - Returns: The forwarder's class declaration.
    static func forwarder(for proto: ProtocolDeclSyntax, label: String, timed: Bool) -> DeclSyntax {
        let protoName = proto.name.text
        let generatedName = "Traced\(protoName)"
        let wrapped = "any \(protoName)"

        var members: [String] = []
        var pastedInits: [InitializerDeclSyntax] = []
        for member in proto.memberBlock.members {
            let decl = member.decl
            if let function = decl.as(FunctionDeclSyntax.self), function.body == nil {
                if isStaticOrClass(function.modifiers) {
                    continue
                }
                members.append(forwardingMethod(function, label: label, timed: timed))
            } else if let variable = decl.as(VariableDeclSyntax.self) {
                if isStaticOrClass(variable.modifiers) {
                    continue
                }
                if let property = forwardingProperty(variable, label: label) {
                    members.append(property)
                }
            } else if let initializer = decl.as(InitializerDeclSyntax.self) {
                pastedInits.append(initializer)
                members.append(refusingInit(initializer, generatedName: generatedName))
            }
        }
        // The first pasted init is the designated one: derive the wiring a spec would otherwise
        // author — collaborators resolved to their synthesized doubles, the notification center to
        // the capture's isolated one. `resolve` traps informatively when a parameter has no double.
        if let designated = pastedInits.first {
            members.append(resolvingInit(designated, wrapped: wrapped))
        }

        // Rooted in NSObject so the forwarder can back an Obj-C `id<Protocol>` injection point when the
        // protocol refines an Obj-C (`@objc`) seam — harmless for a Swift-only forwarder, required for an
        // Obj-C-injected one. `super.init()` runs after the stored wrapper is set (Swift two-phase init).
        // `TraceLabeled`: the instance can state its label to an injection point.
        // `@unchecked Sendable`: an immutable single-reference wrapper that forwards into the
        // wrapped conformer's isolation — the conformer's own thread-safety is the conformer's, as it
        // always was, and the compiler would otherwise refuse to carry `self` across that hop.
        // `StampedForwarder`: the class-list census that finds a boundary's forwarder, so every spec
        // over `any <Protocol>` is wrapped by it without naming it. `wrap` is idempotent — a
        // conformer the derived construction already wrapped is handed back as is.
        let conformances = "NSObject, \(protoName), TraceLabeled, StampedForwarder, @unchecked Sendable"
        let source = """
        final class \(generatedName): \(conformances) {
            private let __wrapped: \(wrapped)
            init(_ wrapped: \(wrapped)) { __wrapped = wrapped; super.init() }
            nonisolated var traceLabel: String { \(quotedLiteral(label)) }
            static var forwardedBoundary: Any.Type { (\(wrapped)).self }
            static func wrap(_ conformer: Any) -> Any? {
                if let forwarder = conformer as? \(generatedName) { return forwarder }
                return (conformer as? \(wrapped)).map { \(generatedName)($0) }
            }

        \(members.joined(separator: "\n\n"))
        }
        """
        return DeclSyntax("\(raw: source)")
    }

    /// The origin an instrumented forward registers: the *wrapped* type, read at runtime, and no
    /// source. The generated forwarder lives in the protocol's file, but the behavior lives in
    /// whatever it wraps — an Obj-C class the audit finds by `@implementation`, a Swift port it finds
    /// by declaration — and naming the pasted-interface file would let an audit read a file with
    /// nothing in it and call the label covered.
    private static func wrappedOrigin(label: String) -> String {
        originArguments(
            label: label,
            symbolExpression: "String(describing: type(of: __wrapped))",
            sourceExpression: nil
        )
    }

    /// One traced forwarding method: same signature and attributes as the requirement, body forwards
    /// to `__wrapped`.
    ///
    /// An `async` requirement is recorded *as the isolation it forwards into*: the body runs in a
    /// nested function whose `isolated` parameter is the wrapped actor when there is one, else the
    /// method's own isolation (`#isolation` — `MainActor` when the requirement declares it, `nil`
    /// otherwise). Recording there, rather than at the caller's frame, is what keeps an actor
    /// port's calls attributed to the actor and lets the effects it emits inherit that domain, with
    /// nothing inside the actor. A sync requirement has no hop to make: an actor can only witness it `nonisolated`.
    private static func forwardingMethod(_ function: FunctionDeclSyntax, label: String, timed: Bool) -> String {
        // Forward each parameter under its external argument label (dropping `_`), passing the value
        // by internal name — reproducing the imported call, IUOs and all, with no unwrap.
        let forwarded = function.signature.parameterClause.parameters.map { param -> String in
            let external = param.firstName.text
            let internalName = (param.secondName ?? param.firstName).text
            return external == "_" ? internalName : "\(external): \(internalName)"
        }.joined(separator: ", ")

        let effects = function.signature.effectSpecifiers
        let isAsync = effects?.asyncSpecifier != nil
        let isThrows = effects?.throwsClause != nil
        let prefix = "\(isThrows ? "try " : "")\(isAsync ? "await " : "")"
        let call = "\(prefix)__wrapped.\(function.name.text)(\(forwarded))"

        let returnType = function.signature.returnClause?.type.trimmedDescription
        let isVoid = returnType == nil || returnType == "Void" || returnType == "()"
        let innerBody = isVoid ? call : "return \(call)"

        var body = tracedBody(
            function: function,
            label: "\(label).\(function.name.text)",
            innerBody: innerBody,
            timed: timed,
            origin: wrappedOrigin(label: label),
            isolationExpression: isAsync ? "__oracleIsolation" : nil
        )
        if isAsync {
            // Arguments cross into the wrapped isolation by capture. They are the caller's values,
            // handed to the conformer exactly as an un-forwarded call would hand them, so the
            // compiler's sending check is answered here rather than pushed onto every conformer.
            let names = function.signature.parameterClause.parameters.map { ($0.secondName ?? $0.firstName).text }
            let launder = names.map { "nonisolated(unsafe) let __oracleArg_\($0) = \($0)\n" }.joined()
            let rebind = names.map { "let \($0) = __oracleArg_\($0)\n" }.joined()
            let signature = "func __oracleForward(__oracleIsolation: isolated (any Actor)?) async "
                + "\(isThrows ? "throws " : "")-> \(returnType ?? "Void")"
            let hop = "\(prefix)__oracleForward(__oracleIsolation: (__wrapped as? any Actor) ?? #isolation)"
            body = "\(launder)\(signature) {\n\(indent(rebind + body))\n}\n\(isVoid ? hop : "return \(hop)")"
        }
        let attributes = function.attributes.isEmpty ? "" : "\(function.attributes.trimmedDescription) "
        let generics = function.genericParameterClause?.trimmedDescription ?? ""
        let whereClause = function.genericWhereClause.map { " \($0.trimmedDescription)" } ?? ""
        return "    \(attributes)func \(function.name.text)\(generics)\(function.signature.trimmedDescription)"
            + "\(whereClause) {\n\(indent(body))\n    }"
    }

    /// The forwarder's witness of a pasted `init` requirement. Conformance demands one, but a
    /// forwarder has nothing to construct — so it traps, naming the two routes that do.
    private static func refusingInit(_ initializer: InitializerDeclSyntax, generatedName: String) -> String {
        let message = "\(generatedName) is a forwarder, not a conformer — wrap one: "
            + "\(generatedName)(<conformer>), or construct it from its type: "
            + "\(generatedName)(resolving: context, <Conformer>.self)"
        return "    convenience init\(initializer.signature.parameterClause.trimmedDescription) {\n"
            + "        preconditionFailure(\(quotedLiteral(message)))\n"
            + "    }"
    }

    /// The derived construction: each parameter of the designated pasted init resolves by type —
    /// the capture's notification center for a `NotificationCenter`, the conformance-matched
    /// synthesized double for a collaborator boundary — and the conformer is built through the
    /// requirement itself, then wrapped. What this cannot resolve, `resolve` reports at spec
    /// construction with the authored `.system { }` spelled out.
    private static func resolvingInit(_ initializer: InitializerDeclSyntax, wrapped: String) -> String {
        let arguments = initializer.signature.parameterClause.parameters.map { param -> String in
            let external = param.firstName.text
            let spelled = param.type.trimmedDescription
            let bare = spelled.hasSuffix("!") || spelled.hasSuffix("?") ? String(spelled.dropLast()) : spelled
            let value = bare == "NotificationCenter" || bare == "NSNotificationCenter"
                ? "__context.notifications"
                : "__context.resolve(\(bare).self)"
            return external == "_" ? value : "\(external): \(value)"
        }.joined(separator: ", ")
        return "    convenience init(resolving __context: SeamContext, _ __conformer: \(wrapped).Type) {\n"
            + "        self.init(__conformer.init(\(arguments)))\n"
            + "    }"
    }

    /// One forwarding property. A read-only `var x: T { get }` forwards as a plain computed property
    /// — reads are not effects, so nothing records; a `{ get async }` requirement (how an actor
    /// witnesses state) forwards with `await`. A `{ get set }` requirement forwards both accessors,
    /// and the setter records the write as a `stateChange` before it forwards. The wrapped object's
    /// *internal* writes never cross this wrapper, so only boundary writes are on the trace.
    private static func forwardingProperty(_ variable: VariableDeclSyntax, label: String) -> String? {
        guard variable.bindingSpecifier.tokenKind == .keyword(.var),
              let binding = variable.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let type = binding.typeAnnotation?.type.trimmedDescription
        else { return nil }
        guard hasSetterRequirement(binding) else {
            return hasAsyncGetter(binding)
                ? "    var \(name): \(type) { get async { await __wrapped.\(name) } }"
                : "    var \(name): \(type) { __wrapped.\(name) }"
        }
        let origin = wrappedOrigin(label: label)
        return """
            var \(name): \(type) {
                get { __wrapped.\(name) }
                set {
                    let __oracle = TraceContext.active
                    __oracle?.noteOrigin(\(origin))
                    __oracle?.stateChange(\(quotedLiteral("\(label).\(name)")), subject: self, \
        value: RuntimeValue.canonical(newValue as Any))
                    __wrapped.\(name) = newValue
                }
            }
        """
    }

    /// Whether a protocol var requirement's accessor block declares `set`.
    private static func hasSetterRequirement(_ binding: PatternBindingSyntax) -> Bool {
        guard case let .accessors(accessors) = binding.accessorBlock?.accessors else { return false }
        return accessors.contains { $0.accessorSpecifier.tokenKind == .keyword(.set) }
    }
}

/// Whether a protocol var requirement's accessor block declares `get async`.
func hasAsyncGetter(_ binding: PatternBindingSyntax) -> Bool {
    guard case let .accessors(accessors) = binding.accessorBlock?.accessors else { return false }
    return accessors.contains { $0.effectSpecifiers?.asyncSpecifier != nil }
}
