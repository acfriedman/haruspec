import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - @Traced (member-attribute)

/// Stamps `@TracedMethod("<typeLabel>", timed: …)` onto every eligible instance method of the
/// attached type, so `@Traced` on a class instruments the whole class with no per-method annotation.
/// Timing is enabled for a method when the type opts in via `timing: true` or the method is `@Timed`.
public struct TracedMacro: MemberAttributeMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        if let variable = member.as(VariableDeclSyntax.self) {
            return propertyAttributes(for: variable, node: node, declaration: declaration)
        }
        guard let function = member.as(FunctionDeclSyntax.self), function.body != nil else { return [] }
        // Skip type methods — there is no instance `self` to attribute the events to.
        if function.modifiers.contains(where: {
            $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
        }) {
            return []
        }
        // Respect an explicit @TracedMethod the author wrote themselves (power-user override).
        if hasAttribute(function, named: "TracedMethod") {
            return []
        }

        let typeLabel = stringArgument(of: node) ?? typeName(of: declaration) ?? "Unknown"
        let timed = (boolArgument(of: node, name: "timing") ?? false) || hasAttribute(function, named: "Timed")
        // `declaredBy` is the *concrete* type, which the label deliberately isn't: `@Traced("Cart")` can
        // sit on `SwiftCartActor`, and two ports can share one label. Only this macro sees both, so it
        // hands the type down to the body macro, which pairs it with the file (see `TraceOrigin`).
        let declaredBy = typeName(of: declaration) ?? typeLabel
        return ["""
        @TracedMethod(\(literal: typeLabel), timed: \(raw: timed ? "true" : "false"), \
        declaredBy: \(literal: declaredBy))
        """]
    }

    /// Stamps `@TracedProperty` onto every **stored instance `var`**, so each committed write records a
    /// `stateChange` — the write timeline that makes the type's conformance to `FullMutationCapture`
    /// true. Skipped, deliberately: `let` (never written), computed/observed properties (an accessor
    /// macro cannot add observers where accessors exist — a computed passthrough is the wrapped
    /// side's write, not this type's), `lazy`/wrapped/attributed and multi-binding declarations (the
    /// accessor grammar forbids them), and `static` (no instance `self`).
    private static func propertyAttributes(
        for variable: VariableDeclSyntax,
        node: AttributeSyntax,
        declaration: some DeclGroupSyntax
    ) -> [AttributeSyntax] {
        guard variable.bindingSpecifier.tokenKind == .keyword(.var),
              !isStaticOrClass(variable.modifiers),
              !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.lazy) }),
              variable.attributes.isEmpty,
              variable.bindings.count == 1,
              let binding = variable.bindings.first,
              binding.accessorBlock == nil,
              binding.pattern.is(IdentifierPatternSyntax.self)
        else { return [] }
        let typeLabel = stringArgument(of: node) ?? typeName(of: declaration) ?? "Unknown"
        let declaredBy = typeName(of: declaration) ?? typeLabel
        return ["@TracedProperty(\(literal: typeLabel), declaredBy: \(literal: declaredBy))"]
    }
}

extension TracedMacro: ExtensionMacro {
    /// The `TraceLabeled` conformance: an instrumented instance can state the label its events carry,
    /// so an injection point registers a collaborator by asking the double rather than being told.
    /// `nonisolated`, because the label is a constant and the conformer may be an actor (or a
    /// global-actor-isolated class), whose isolated members could not satisfy the protocol.
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let typeLabel = stringArgument(of: node) ?? typeName(of: declaration) ?? "Unknown"
        // `FullMutationCapture` rides along: every stored `var` carries `@TracedProperty`, so the
        // write timeline is recorded in full — the fact the mutation-order diff needs both sides to
        // state. A marker protocol with a default, so nothing here names an enum case.
        return try [ExtensionDeclSyntax(
            """
            extension \(type.trimmed): TraceLabeled, FullMutationCapture {
                nonisolated public var traceLabel: String { \(literal: typeLabel) }
            }
            """
        )]
    }
}

// MARK: - @Timed (marker)

/// A no-op peer macro. Its only job is to be a legal attribute that `@Traced` can detect on a method
/// to enable that method's timing.
public struct TimedMarkerMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf _: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

// MARK: - @TracedMethod (body)

/// Wraps a method body so it records `call` (with arguments) on entry and `ret` (with the return
/// value) on exit, to the ambient `TraceContext.current`. When `timed`, it also records the method's
/// duration as a signpost interval. The original statements run inside a nested function so `return`,
/// `guard … else { return }`, `throws` and `async` all keep their meaning.
public struct TracedMethodMacro: BodyMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else { return [] }

        let typeLabel = stringArgument(of: node) ?? "Unknown"
        let timed = boolArgument(of: node, name: "timed") ?? false
        // The instrumented work is the method's own statements, run inside the `__oracleBody` shim.
        let original = function.body?.statements.description ?? ""

        // The *method's* location, not the type's: a type split across extensions registers each file
        // it actually declares behavior in, which is precisely what an audit has to read.
        let file = context.location(of: declaration, at: .afterLeadingTrivia, filePathMode: .fileID)?
            .file.trimmedDescription

        let body = tracedBody(
            function: function,
            label: "\(typeLabel).\(function.name.text)",
            innerBody: original,
            timed: timed,
            origin: originArguments(
                label: typeLabel,
                symbol: stringArgument(of: node, name: "declaredBy"),
                sourceExpression: file
            )
        )

        // Instrument only under #if DEBUG, so `@Traced` can sit on a type that ships. Release keeps
        // the method's own statements verbatim — no shim, no recorder lookup, nothing to strip.
        let guarded = "#if DEBUG\n\(body)\n#else\n\(original)\n#endif"
        return Array(CodeBlockItemListSyntax("\(raw: guarded)"))
    }
}

// MARK: - @TracedProperty (accessor: record committed writes)

/// Adds a `didSet` observer to a **stored** property so every committed write records a `stateChange`
/// — the property-write half of `@Traced`'s instrumentation, which stamps this automatically. The
/// observer runs after the write, so the recorded value is the one an observer of the property would
/// read at that moment; assignments during `init` never fire an observer, so construction stays
/// untraced (matching methods). Instrumentation is inside `#if DEBUG`, like `@TracedMethod`.
public struct TracedPropertyMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let variable = declaration.as(VariableDeclSyntax.self),
              let binding = variable.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
        else {
            throw MacroError("@TracedProperty can only be attached to a stored `var` with a simple name")
        }
        let typeLabel = stringArgument(of: node) ?? "Unknown"
        let file = context.location(of: declaration, at: .afterLeadingTrivia, filePathMode: .fileID)?
            .file.trimmedDescription
        let origin = originArguments(
            label: typeLabel,
            symbol: stringArgument(of: node, name: "declaredBy"),
            sourceExpression: file
        )
        return ["""
        didSet {
            #if DEBUG
            let __oracle = TraceContext.active
            __oracle?.noteOrigin(\(raw: origin))
            __oracle?.stateChange(\(literal: "\(typeLabel).\(name)"), subject: self, \
        value: RuntimeValue.canonical(\(raw: name) as Any))
            #endif
        }
        """]
    }
}

// MARK: - Shared instrumentation emitter

/// Builds the `call`/`ret` instrumented body shared by `@TracedMethod` and `@TracedForwarder`.
///
/// The result records `call` (with arguments keyed by internal parameter name) on entry, runs
/// `innerBody` inside a nested `__oracleBody()` shim that mirrors the signature's effect specifiers
/// and return type — so `return`, `guard … else { return }`, `throws` and `async` keep their meaning
/// — then records `ret` (with the canonicalized return value, or a `__threw` marker) on exit. When
/// `timed`, it also records the method's duration as a signpost interval.
///
/// Both the baseline (`@Traced`, `innerBody` = the method's own statements) and the port
/// (`@TracedForwarder`, `innerBody` = a `__wrapped.<method>(…)` forwarding call) run this one emitter,
/// so their instrumentation stays byte-for-byte aligned and their traces diff cleanly.
/// The `noteOrigin` argument list an instrumented body registers itself with. `sourceExpression` is
/// already a Swift expression — a `#fileID` string literal from the expansion context, or nil where the
/// behavior has no Swift source to point at.
func originArguments(label: String, symbol: String?, sourceExpression: String?) -> String {
    "\(literalString(label)), symbol: \(symbol.map(literalString) ?? "nil"), source: \(sourceExpression ?? "nil")"
}

func tracedBody(
    function: FunctionDeclSyntax,
    label rawLabel: String,
    innerBody: String,
    timed: Bool,
    origin: String
) -> String {
    let label = literalString(rawLabel)

    let effects = function.signature.effectSpecifiers
    let isAsync = effects?.asyncSpecifier != nil
    let isThrows = effects?.throwsClause != nil
    let invoke = "\(isThrows ? "try " : "")\(isAsync ? "await " : "")__oracleBody()"

    let returnType = function.signature.returnClause?.type.trimmedDescription
    let isVoid = returnType == nil || returnType == "Void" || returnType == "()"
    let nestedSignature =
        "func __oracleBody() \(isAsync ? "async " : "")\(isThrows ? "throws " : "")-> \(returnType ?? "Void")"

    // Argument capture: key each argument by its internal parameter name, encoded at runtime. The
    // `as Any` keeps imported IUO parameters (`Foo!`) from tripping an optional-coercion warning.
    let innerNames = function.signature.parameterClause.parameters.map { param in
        (param.secondName ?? param.firstName).text
    }
    let callArgs = innerNames.isEmpty ? "" :
        ", args: [" + innerNames.map { "\"\($0)\": RuntimeValue.canonical(\($0) as Any)" }.joined(separator: ", ") + "]"

    let retVoid = "__oracle?.ret(\(label), subject: self)"
    let retValue = "__oracle?.ret(\(label), subject: self, value: RuntimeValue.canonical(__oracleResult as Any))"
    let retThrew = "__oracle?.ret(\(label), subject: self, "
        + "value: [\"__threw\": RuntimeValue.canonical(String(describing: error))])"
    let timedStop = "if let __oracle, let __oracleStart "
        + "{ __oracle.signpost(\(label), subject: self, durationTicks: __oracle.now() - __oracleStart) }"

    var lines: [String] = [
        "let __oracle = TraceContext.active",
        "__oracle?.noteOrigin(\(origin))",
        "__oracle?.call(\(label), subject: self\(callArgs))",
        "\(nestedSignature) { \(innerBody)",
        "}"
    ]
    if timed {
        lines.append("let __oracleStart = __oracle?.now()")
    }

    switch (isThrows, isVoid) {
    case (false, true):
        lines.append(invoke)
        if timed {
            lines.append(timedStop)
        }
        lines.append(retVoid)
    case (false, false):
        lines.append("let __oracleResult = \(invoke)")
        if timed {
            lines.append(timedStop)
        }
        lines.append(retValue)
        lines.append("return __oracleResult")
    case (true, true):
        lines.append("do {")
        lines.append("    \(invoke)")
        if timed {
            lines.append("    \(timedStop)")
        }
        lines.append("    \(retVoid)")
        lines.append("} catch {")
        lines.append("    \(retThrew)")
        lines.append("    throw error")
        lines.append("}")
    case (true, false):
        lines.append("do {")
        lines.append("    let __oracleResult = \(invoke)")
        if timed {
            lines.append("    \(timedStop)")
        }
        lines.append("    \(retValue)")
        lines.append("    return __oracleResult")
        lines.append("} catch {")
        lines.append("    \(retThrew)")
        lines.append("    throw error")
        lines.append("}")
    }

    return lines.joined(separator: "\n")
}

// MARK: - @TracedForwarder (peer: generate a traced 1:1 forwarding shim)

/// Attached to a `protocol` of pasted Clang-imported signatures, generate a peer `final class` that
/// wraps an Obj-C object and forwards every requirement 1:1 — instrumented with the *same* `call`/`ret`
/// events `@Traced` emits (see `tracedBody`), so the forwarder's trace aligns with a `@Traced` port.
///
/// Because the protocol keeps the imported IUOs verbatim (`checkout() -> Receipt!`), each forward is a
/// bare `__wrapped.checkout()` — no hand-written shim, no force-unwrap. Method requirements are traced;
/// a read-only `var x: T { get }` forwards as a plain computed property (reads are not effects), and a
/// `{ get set }` requirement's setter records the write as a `stateChange` before forwarding — the
/// boundary half of property capture, hence `BoundaryMutationCapture` on the generated class.
/// `static`/`class` requirements are skipped — no instance `self`.
public struct TracedForwarderMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let proto = declaration.as(ProtocolDeclSyntax.self) else {
            throw MacroError("@TracedForwarder can only be attached to a protocol")
        }
        guard let wrapping = typeArgument(of: node, name: "wrapping") else {
            throw MacroError("@TracedForwarder requires a 'wrapping:' class to forward to")
        }
        guard let label = stringArgument(of: node, name: "label") else {
            throw MacroError("@TracedForwarder requires a 'label:' string matching the port's @Traced label")
        }
        let protoName = proto.name.text
        let generatedName = stringArgument(of: node, name: "as") ?? "Traced\(protoName)"

        // A singleton wrapped type can declare its accessor (`shared: "shared()"`) so the forwarder
        // self-wires to the real instance; absent it, the init defaults to a fresh `wrapping()`.
        let sharedAccessor = stringArgument(of: node, name: "shared")

        var members: [String] = []
        var pastedInits: [InitializerDeclSyntax] = []
        for member in proto.memberBlock.members {
            let decl = member.decl
            if let function = decl.as(FunctionDeclSyntax.self), function.body == nil {
                if isStaticOrClass(function.modifiers) {
                    continue
                }
                members.append(forwardingMethod(function, label: label, wrapping: wrapping))
            } else if let variable = decl.as(VariableDeclSyntax.self) {
                if isStaticOrClass(variable.modifiers) {
                    continue
                }
                if let property = forwardingProperty(variable, label: label, wrapping: wrapping) {
                    members.append(property)
                }
            } else if let initializer = decl.as(InitializerDeclSyntax.self) {
                pastedInits.append(initializer)
                members.append(mirrorInit(initializer, wrapping: wrapping))
            }
        }
        // The first pasted init is the designated one: derive the wiring a spec would otherwise
        // author — collaborators resolved to their synthesized doubles, the notification center to
        // the capture's isolated one. `resolve` traps informatively when a parameter has no double.
        if let designated = pastedInits.first {
            members.append(resolvingInit(designated))
        }

        // With a pasted init, construction is the protocol's business and the bare `W()` default
        // disappears — it assumed an NSObject-style `-init`, which a Swift baseline may not have,
        // and a compiled default argument fails even for callers who never use it. Without one, the
        // historical default stands (`shared:` accessor, or the wrapped type's own `init()`).
        let wrappedDefault = pastedInits.isEmpty
            ? " = \(sharedAccessor.map { "\(wrapping).\($0)" } ?? "\(wrapping)()")"
            : ""

        // Rooted in NSObject so the forwarder can back an Obj-C `id<Protocol>` injection point when the
        // protocol refines an Obj-C (`@objc`) seam — harmless for a Swift-only forwarder, required for an
        // Obj-C-injected one. `super.init()` runs after the stored wrapper is set (Swift two-phase init).
        // `TraceLabeled` for the same reason `@Traced` emits it: the instance can state its label to an
        // injection point.
        // `BoundaryMutationCapture`: the generated setter records writes that cross this wrapper, and
        // nothing records the wrapped object's internal writes — so the trace says "boundary", and
        // the mutation-order diff knows not to read the wrapped side's silence as behavior.
        let source = """
        final class \(generatedName): NSObject, \(protoName), TraceLabeled, BoundaryMutationCapture {
            private let __wrapped: \(wrapping)
            init(_ wrapped: \(wrapping)\(wrappedDefault)) { __wrapped = wrapped; super.init() }

            nonisolated var traceLabel: String { \(quotedLiteral(label)) }

        \(members.joined(separator: "\n\n"))
        }
        """
        return [DeclSyntax("\(raw: source)")]
    }

    /// One traced forwarding method: same signature as the requirement, body forwards to `__wrapped`.
    private static func forwardingMethod(
        _ function: FunctionDeclSyntax,
        label: String,
        wrapping: String
    ) -> String {
        // Forward each parameter under its external argument label (dropping `_`), passing the value
        // by internal name — reproducing the imported call, IUOs and all, with no unwrap.
        let forwarded = function.signature.parameterClause.parameters.map { param -> String in
            let external = param.firstName.text
            let internalName = (param.secondName ?? param.firstName).text
            return external == "_" ? internalName : "\(external): \(internalName)"
        }.joined(separator: ", ")

        let effects = function.signature.effectSpecifiers
        let prefix = "\(effects?.throwsClause != nil ? "try " : "")\(effects?.asyncSpecifier != nil ? "await " : "")"
        let call = "\(prefix)__wrapped.\(function.name.text)(\(forwarded))"

        let returnType = function.signature.returnClause?.type.trimmedDescription
        let isVoid = returnType == nil || returnType == "Void" || returnType == "()"
        let innerBody = isVoid ? call : "return \(call)"

        // No `source:`. The generated forwarder does live in the protocol's file, but the *behavior*
        // lives in the Obj-C class it wraps — pointing an audit at the pasted-interface file would
        // read as "audited" while the code that can bypass a channel was never opened. The wrapped
        // type name is what a reader (or a later Obj-C path) has to go on.
        let body = tracedBody(
            function: function,
            label: "\(label).\(function.name.text)",
            innerBody: innerBody,
            timed: false,
            origin: originArguments(label: label, symbol: wrapping, sourceExpression: nil)
        )
        let generics = function.genericParameterClause?.trimmedDescription ?? ""
        let whereClause = function.genericWhereClause.map { " \($0.trimmedDescription)" } ?? ""
        return "    func \(function.name.text)\(generics)\(function.signature.trimmedDescription)"
            + "\(whereClause) {\n\(indent(body))\n    }"
    }

    /// A pasted `init` requirement mirrors 1:1 onto the wrapped class — which is also what satisfies
    /// the requirement on the generated conformer, so the protocol can carry the construction
    /// contract without burdening it.
    private static func mirrorInit(_ initializer: InitializerDeclSyntax, wrapping: String) -> String {
        let parameters = initializer.signature.parameterClause.parameters
        let forwarded = parameters.map { param -> String in
            let external = param.firstName.text
            let internalName = (param.secondName ?? param.firstName).text
            return external == "_" ? internalName : "\(external): \(internalName)"
        }.joined(separator: ", ")
        return "    convenience init\(initializer.signature.parameterClause.trimmedDescription) {\n"
            + "        self.init(\(wrapping)(\(forwarded)))\n"
            + "    }"
    }

    /// The derived system wiring: each parameter of the designated pasted init resolves by type —
    /// the capture's notification center for a `NotificationCenter`, the conformance-matched
    /// synthesized double for a collaborator boundary. What this cannot resolve, `resolve` reports
    /// at spec construction with the authored `.system { }` spelled out.
    private static func resolvingInit(_ initializer: InitializerDeclSyntax) -> String {
        let arguments = initializer.signature.parameterClause.parameters.map { param -> String in
            let external = param.firstName.text
            let internalName = (param.secondName ?? param.firstName).text
            let spelled = param.type.trimmedDescription
            let bare = spelled.hasSuffix("!") || spelled.hasSuffix("?") ? String(spelled.dropLast()) : spelled
            let value = bare == "NotificationCenter" || bare == "NSNotificationCenter"
                ? "__context.notifications"
                : "__context.resolve(\(bare).self)"
            return external == "_" ? value : "\(external == "_" ? internalName : external): \(value)"
        }.joined(separator: ", ")
        return "    convenience init(resolving __context: SeamContext) {\n"
            + "        self.init(\(arguments))\n"
            + "    }"
    }

    /// One forwarding property. A read-only `var x: T { get }` forwards as a plain computed property
    /// — reads are not effects, so nothing records. A `{ get set }` requirement forwards both
    /// accessors, and the setter records the write as a `stateChange` before it forwards — the
    /// boundary half of property capture (the wrapped object's *internal* writes never cross this
    /// wrapper, which is why the generated class declares `BoundaryMutationCapture`).
    private static func forwardingProperty(
        _ variable: VariableDeclSyntax,
        label: String,
        wrapping: String
    ) -> String? {
        guard variable.bindingSpecifier.tokenKind == .keyword(.var),
              let binding = variable.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let type = binding.typeAnnotation?.type.trimmedDescription
        else { return nil }
        guard hasSetterRequirement(binding) else {
            return "    var \(name): \(type) { __wrapped.\(name) }"
        }
        let origin = originArguments(label: label, symbol: wrapping, sourceExpression: nil)
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

// MARK: - @Seamed (un-injected reach)

/// One rewrite to apply: replace the trimmed source range `[start, end)` with `text`.
private typealias SeamEdit = (start: Int, end: Int, text: String)

/// The bare nondeterminism calls `@Seamed` rewrites, and what they become.
private enum SeamRewrite {
    /// A no-arg `Foo()` call routed to `Seam.<replacement>`.
    static let calls: [String: String] = ["Date": "Seam.now()", "UUID": "Seam.uuid()"]
    /// A `Type.member` access routed to a replacement (e.g. `Date.now`).
    static let members: [(type: String, member: String, replacement: String)] = [
        ("Date", "now", "Seam.now()")
    ]

    static func replacement(forCall node: FunctionCallExprSyntax) -> String? {
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
              node.arguments.isEmpty, node.trailingClosure == nil, node.additionalTrailingClosures.isEmpty
        else { return nil }
        return calls[callee.baseName.text]
    }

    static func replacement(forMember node: MemberAccessExprSyntax) -> String? {
        guard let base = node.base?.as(DeclReferenceExprSyntax.self) else { return nil }
        return members.first { $0.type == base.baseName.text && $0.member == node.declName.baseName.text }?.replacement
    }
}

/// Collects the trimmed source ranges of rewritable seam calls under `node`, with their replacements.
/// A manual recursive walk over value-level syntax — deliberately *not* a `SyntaxRewriter` /
/// `SyntaxVisitor` subclass, whose visitation symbols the prebuilt SwiftSyntax binary doesn't export.
private func collectSeamEdits(_ node: Syntax, into edits: inout [SeamEdit]) {
    if let call = node.as(FunctionCallExprSyntax.self), let repl = SeamRewrite.replacement(forCall: call) {
        edits.append((
            call.positionAfterSkippingLeadingTrivia.utf8Offset,
            call.endPositionBeforeTrailingTrivia.utf8Offset,
            repl
        ))
        return
    }
    if let member = node.as(MemberAccessExprSyntax.self), let repl = SeamRewrite.replacement(forMember: member) {
        edits.append((
            member.positionAfterSkippingLeadingTrivia.utf8Offset,
            member.endPositionBeforeTrailingTrivia.utf8Offset,
            repl
        ))
        return
    }
    for child in node.children(viewMode: .sourceAccurate) {
        collectSeamEdits(child, into: &edits)
    }
}

/// Stamps `@SeamedMethod` onto each method of the attached type whose body reads an un-injected seam.
public struct SeamedMacro: MemberAttributeMacro {
    public static func expansion(
        of _: AttributeSyntax,
        attachedTo _: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        guard let function = member.as(FunctionDeclSyntax.self), let body = function.body else { return [] }
        if hasAttribute(function, named: "SeamedMethod") {
            return []
        }
        var edits: [SeamEdit] = []
        collectSeamEdits(Syntax(body), into: &edits)
        return edits.isEmpty ? [] : ["@SeamedMethod"]
    }
}

/// Rewrites a method body's bare seam calls to the ambient `Seam`, guarded so *only* DEBUG builds
/// carry the rewrite — release keeps the original bare calls, so production is byte-for-byte untouched.
public struct SeamedMethodMacro: BodyMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in _: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self), let body = function.body else { return [] }
        let statements = body.statements

        var edits: [SeamEdit] = []
        collectSeamEdits(Syntax(statements), into: &edits)
        if edits.isEmpty {
            return Array(statements)
        }

        // Apply edits to the statements' own source text by descending offset (so earlier edits don't
        // shift later ones). `.description` starts at `statements.position`, so subtract that base.
        let base = statements.position.utf8Offset
        var utf8 = Array(statements.description.utf8)
        for edit in edits.sorted(by: { $0.start > $1.start }) {
            let start = edit.start - base, end = edit.end - base
            guard start >= 0, end <= utf8.count, start <= end else { continue }
            utf8.replaceSubrange(start ..< end, with: Array(edit.text.utf8))
        }
        let rewritten = String(decoding: utf8, as: UTF8.self)

        // Emit the rewrite only under #if DEBUG; release builds keep the original bare calls untouched.
        let guarded = "#if DEBUG\n\(rewritten)\n#else\n\(statements.description)\n#endif"
        return Array(CodeBlockItemListSyntax("\(raw: guarded)"))
    }
}

// MARK: - Shared helpers

/// Extracts the first positional string-literal argument of a macro attribute, if present.
/// `label` as Swift source for a string literal — labels are plain identifiers, but escape anyway so
/// a pathological one cannot break out of the generated expression.
func quotedLiteral(_ value: String) -> String {
    StringLiteralExprSyntax(content: value).description
}

func stringArgument(of node: AttributeSyntax) -> String? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
          let first = arguments.first, first.label == nil,
          let literal = first.expression.as(StringLiteralExprSyntax.self) else { return nil }
    return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
}

/// Extracts a labeled string-literal argument of a macro attribute, if present.
func stringArgument(of node: AttributeSyntax, name: String) -> String? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for argument in arguments where argument.label?.text == name {
        if let literal = argument.expression.as(StringLiteralExprSyntax.self) {
            return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
        }
    }
    return nil
}

/// Extracts a labeled metatype argument (`Foo.self`) as its type name, e.g. `CartManager.self` → "CartManager".
private func typeArgument(of node: AttributeSyntax, name: String) -> String? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for argument in arguments where argument.label?.text == name {
        if let member = argument.expression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "self", let base = member.base {
            return base.trimmedDescription
        }
        return argument.expression.trimmedDescription
    }
    return nil
}

/// Whether a modifier list marks the declaration `static` or `class` (a type member, no instance `self`).
func isStaticOrClass(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
}

/// Indent each line of a generated body by two levels (eight spaces), for readability of the expansion.
func indent(_ body: String) -> String {
    body.split(separator: "\n", omittingEmptySubsequences: false).map { "        \($0)" }.joined(separator: "\n")
}

/// A macro-expansion failure surfaced to the compiler as a diagnostic (never a plugin crash).
struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

/// Extracts a labeled boolean-literal argument of a macro attribute, if present.
private func boolArgument(of node: AttributeSyntax, name: String) -> Bool? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for argument in arguments where argument.label?.text == name {
        if let literal = argument.expression.as(BooleanLiteralExprSyntax.self) {
            return literal.literal.tokenKind == .keyword(.true)
        }
    }
    return nil
}

/// Whether a function carries an attribute with the given (unqualified) name.
private func hasAttribute(_ function: FunctionDeclSyntax, named: String) -> Bool {
    function.attributes.contains { element in
        element.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == named
    }
}

/// The declared name of a class/struct/actor.
private func typeName(of declaration: some DeclGroupSyntax) -> String? {
    if let decl = declaration.as(ClassDeclSyntax.self) {
        return decl.name.text
    }
    if let decl = declaration.as(ActorDeclSyntax.self) {
        return decl.name.text
    }
    if let decl = declaration.as(StructDeclSyntax.self) {
        return decl.name.text
    }
    return nil
}

/// Renders a Swift double-quoted string literal for a known-safe label.
func literalString(_ value: String) -> String {
    "\"\(value)\""
}

// MARK: - Plugin

@main
struct Plugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        TracedMacro.self,
        TracedMethodMacro.self,
        TracedPropertyMacro.self,
        TimedMarkerMacro.self,
        TracedForwarderMacro.self,
        TracedDoubleMacro.self,
        DerivedOpsMacro.self,
        SeamedMacro.self,
        SeamedMethodMacro.self
    ]
}
