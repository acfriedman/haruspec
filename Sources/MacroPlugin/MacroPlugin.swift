import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Shared instrumentation emitter

/// Returns the `noteOrigin` argument list for a symbol known at expansion time.
///
/// - Parameters:
///   - label: The traced label as plain text, unquoted.
///   - symbol: The symbol's name as plain text, unquoted; `nil` where there is nothing to point at.
///   - sourceExpression: A Swift expression naming the source, such as a `#fileID` literal from the
///     expansion context; `nil` where there is nothing to point at.
/// - Returns: The arguments as Swift source, the quoted label first, with `nil` written out for a
///   missing symbol or source.
func originArguments(label: String, symbol: String?, sourceExpression: String?) -> String {
    originArguments(label: label, symbolExpression: symbol.map(literalString), sourceExpression: sourceExpression)
}

/// Returns the `noteOrigin` argument list an instrumented body registers itself with.
///
/// - Parameters:
///   - label: The traced label as plain text, unquoted.
///   - symbolExpression: A Swift expression naming the symbol, such as a string literal or a runtime
///     ``Swift/type(of:)`` read; `nil` where there is nothing to point at.
///   - sourceExpression: A Swift expression naming the source, such as a `#fileID` literal from the
///     expansion context; `nil` where there is nothing to point at.
/// - Returns: The arguments as Swift source, the quoted label first, with `nil` written out for a
///   missing expression.
func originArguments(label: String, symbolExpression: String?, sourceExpression: String?) -> String {
    "\(literalString(label)), symbol: \(symbolExpression ?? "nil"), source: \(sourceExpression ?? "nil")"
}

/// Builds the `call`/`ret` instrumented body shared by the forwarder and the double.
///
/// - Parameters:
///   - function: The method declaration being instrumented.
///   - rawLabel: The traced label as plain text, unquoted.
///   - innerBody: Swift statements for the method's own work: a forwarding call for a forwarder, a
///     no-op or a generated read for a double.
///   - timed: Whether the method's duration is recorded as a signpost interval.
///   - origin: The `noteOrigin` argument list, as
///     ``originArguments(label:symbolExpression:sourceExpression:)`` returns it.
///   - isolationExpression: A Swift expression for the isolation every record names, such as the
///     isolation a forwarder forwards into; `nil` names the call site's own `#isolation`.
/// - Returns: The instrumented body as Swift source, one statement per line, without its braces.
///
/// The result records `call` (with arguments keyed by internal parameter name) on entry, runs
/// `innerBody` inside a nested `__oracleBody` shim that mirrors the signature's effect specifiers
/// and return type — so `return`, `guard … else { return }`, `throws` and `async` keep their meaning
/// — then records `ret` (with the canonicalized return value, or a `__threw` marker) on exit. When
/// `timed`, it also records the method's duration as a signpost interval.
///
/// The forwarder (`innerBody` = a `__wrapped.<method>(…)` forwarding call) and the double
/// (`innerBody` = a no-op or a generated read) run this one emitter, so a boundary records the same
/// events whichever role it plays.
func tracedBody(
    function: FunctionDeclSyntax,
    label rawLabel: String,
    innerBody: String,
    timed: Bool,
    origin: String,
    isolationExpression: String? = nil
) -> String {
    let label = literalString(rawLabel)

    let specifiers = function.signature.effectSpecifiers
    let isAsync = specifiers?.asyncSpecifier != nil
    let isThrows = specifiers?.throwsClause != nil
    let effects = "\(isThrows ? "try " : "")\(isAsync ? "await " : "")"
    // The open call is bound for the task, so it still encloses the body after an await moves it.
    let invoke = "\(effects)TraceContext.withOpenCall(__oracleCall) { \(effects)__oracleBody() }"

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
        + "value: [\"__threw\": RuntimeValue.thrown(error)]\(isolation))"
    let timedStop = "if let __oracle, let __oracleStart "
        + "{ __oracle.signpost(\(label), subject: self, durationTicks: __oracle.now() - __oracleStart) }"

    var lines: [String] = [
        "let __oracle = TraceContext.active",
        "__oracle?.noteOrigin(\(origin))",
        "let __oracleCall = __oracle?.call(\(label), subject: self\(callArgs)\(isolation))",
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

/// Returns `value` as Swift source for a string literal, escaped so a pathological label cannot break
/// out of the generated expression.
///
/// - Parameter value: The literal's content as plain text, unquoted and unescaped.
/// - Returns: A Swift string-literal expression whose value is `value`.
func quotedLiteral(_ value: String) -> String {
    StringLiteralExprSyntax(content: value).description
}

/// Returns the first positional string-literal argument of a macro attribute.
///
/// - Parameter node: The macro attribute as written at the use site.
/// - Returns: The literal's text, or `nil` when the first argument is labeled, not a string literal, or
///   absent.
func stringArgument(of node: AttributeSyntax) -> String? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
          let first = arguments.first, first.label == nil,
          let literal = first.expression.as(StringLiteralExprSyntax.self) else { return nil }
    return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
}

/// Returns a labeled string-literal argument of a macro attribute.
///
/// - Parameters:
///   - node: The macro attribute as written at the use site.
///   - name: The argument label, without its colon.
/// - Returns: The literal's text, or `nil` when no argument with that label is a string literal.
func stringArgument(of node: AttributeSyntax, name: String) -> String? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for argument in arguments where argument.label?.text == name {
        if let literal = argument.expression.as(StringLiteralExprSyntax.self) {
            return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
        }
    }
    return nil
}

/// Returns whether a modifier list marks the declaration `static` or `class` (a type member, no
/// instance `self`).
///
/// - Parameter modifiers: The declaration's modifier list.
/// - Returns: Whether the list contains `static` or `class`.
func isStaticOrClass(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
}

/// Returns a generated body with each line indented two levels (eight spaces), for readability of the
/// expansion.
///
/// - Parameter body: Swift source, its lines separated by `\n`.
/// - Returns: The same source with eight spaces before every line, empty lines included.
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

/// Returns a labeled boolean-literal argument of a macro attribute.
///
/// - Parameters:
///   - node: The macro attribute as written at the use site.
///   - name: The argument label, without its colon.
/// - Returns: The literal's value, or `nil` when no argument with that label is a boolean literal.
func boolArgument(of node: AttributeSyntax, name: String) -> Bool? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    for argument in arguments where argument.label?.text == name {
        if let literal = argument.expression.as(BooleanLiteralExprSyntax.self) {
            return literal.literal.tokenKind == .keyword(.true)
        }
    }
    return nil
}

/// Returns a Swift double-quoted string literal for a known-safe label.
///
/// - Parameter value: The label as plain text; must contain no `"`, `\`, or newline, since nothing is
///   escaped.
/// - Returns: `value` wrapped in double quotes, as a Swift expression.
func literalString(_ value: String) -> String {
    "\"\(value)\""
}

// MARK: - Plugin

@main
struct Plugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [HaruspecMacro.self, ContinuousMacro.self]
}
