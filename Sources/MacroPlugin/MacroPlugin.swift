import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Shared instrumentation emitter

/// The `noteOrigin` argument list an instrumented body registers itself with. `symbolExpression` and
/// `sourceExpression` are already Swift expressions — a string literal, a `#fileID` literal from the
/// expansion context, a runtime `type(of:)` read — or nil where there is nothing to point at.
func originArguments(label: String, symbolExpression: String?, sourceExpression: String?) -> String {
    "\(literalString(label)), symbol: \(symbolExpression ?? "nil"), source: \(sourceExpression ?? "nil")"
}

/// `originArguments` for a symbol known at expansion time.
func originArguments(label: String, symbol: String?, sourceExpression: String?) -> String {
    originArguments(label: label, symbolExpression: symbol.map(literalString), sourceExpression: sourceExpression)
}

/// Builds the `call`/`ret` instrumented body shared by the forwarder and the double.
///
/// The result records `call` (with arguments keyed by internal parameter name) on entry, runs
/// `innerBody` inside a nested `__oracleBody()` shim that mirrors the signature's effect specifiers
/// and return type — so `return`, `guard … else { return }`, `throws` and `async` keep their meaning
/// — then records `ret` (with the canonicalized return value, or a `__threw` marker) on exit. When
/// `timed`, it also records the method's duration as a signpost interval.
///
/// The forwarder (`innerBody` = a `__wrapped.<method>(…)` forwarding call) and the double
/// (`innerBody` = a no-op or a generated read) run this one emitter, so a boundary records the same
/// events whichever role it plays.
///
/// `isolationExpression`, when given, is passed as each record's `isolation:` in place of the
/// call site's own `#isolation` — how a forwarder records as the isolation it forwards into.
func tracedBody(
    function: FunctionDeclSyntax,
    label rawLabel: String,
    innerBody: String,
    timed: Bool,
    origin: String,
    isolationExpression: String? = nil
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
    let innerNames = CompletionBlock.recordedArgumentNames(of: function)
    let callArgs = innerNames.isEmpty ? "" :
        ", args: [" + innerNames.map { "\"\($0)\": RuntimeValue.canonical(\($0) as Any)" }.joined(separator: ", ") + "]"
    let isolation = isolationExpression.map { ", isolation: \($0)" } ?? ""

    let retVoid = "__oracle?.ret(\(label), subject: self\(isolation))"
    let retValue = "__oracle?.ret(\(label), subject: self, "
        + "value: RuntimeValue.canonical(__oracleResult as Any)\(isolation))"
    let retThrew = "__oracle?.ret(\(label), subject: self, "
        + "value: [\"__threw\": RuntimeValue.canonical(String(describing: error))]\(isolation))"
    let timedStop = "if let __oracle, let __oracleStart "
        + "{ __oracle.signpost(\(label), subject: self, durationTicks: __oracle.now() - __oracleStart) }"

    var lines: [String] = [
        "let __oracle = TraceContext.active",
        "__oracle?.noteOrigin(\(origin))",
        "__oracle?.call(\(label), subject: self\(callArgs)\(isolation))",
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

// MARK: - Shared helpers

/// Renders `value` as Swift source for a string literal — labels are plain identifiers, but escape
/// anyway so a pathological one cannot break out of the generated expression.
func quotedLiteral(_ value: String) -> String {
    StringLiteralExprSyntax(content: value).description
}

/// Extracts the first positional string-literal argument of a macro attribute, if present.
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
func boolArgument(of node: AttributeSyntax, name: String) -> Bool? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for argument in arguments where argument.label?.text == name {
        if let literal = argument.expression.as(BooleanLiteralExprSyntax.self) {
            return literal.literal.tokenKind == .keyword(.true)
        }
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
    let providingMacros: [Macro.Type] = [HaruspecMacro.self]
}
