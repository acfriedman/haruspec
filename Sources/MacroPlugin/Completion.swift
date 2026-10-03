import SwiftSyntax

// MARK: - Completion blocks (the legacy async shape)

/// A requirement's completion block: a synchronous method's trailing parameter, typed as a function
/// returning `Void`. It is the shape every pre-`async` Obj-C API answers through.
///
/// The answer is a block invocation, not a return, so each role records it as one: the block's
/// delivery is a `call`/`ret` pair labeled `"<label>.<method>.<block>"`, with the block's arguments
/// as the call's payload. The forwarder records it by handing the conformer a recording block; the
/// double records it as it delivers generated arguments; the derived op awaits it. Every role records
/// the same events, so a collaborator stood in for today can be migrated as a subject tomorrow.
///
/// Anything else function-typed — a block that is not last, one that returns a value, a block on an
/// `async` method — is not a completion and keeps the general rules: a derived argument with no
/// heuristic (pending), a double that never calls it.
struct CompletionBlock {
    /// The parameter's internal name, which the method body refers to.
    let name: String
    /// The delivery's label suffix: the external argument label, or the internal name under `_`.
    let label: String
    /// Whether the parameter is an optional block, which a caller may pass as `nil`.
    let isOptional: Bool
    /// The parameter's type as a local declaration may spell it: `@escaping` describes a parameter,
    /// not a type, so it is dropped.
    let localType: String
    /// The block's own parameters, in order.
    let arguments: [Argument]

    /// One parameter of the block.
    struct Argument {
        /// The payload and seam-key name: the spelled name, or the position when the type is bare
        /// (an imported block's `(Int, (any Error)?) -> Void` names nothing).
        let key: String
        /// The source-spelled type.
        let type: String
    }

    /// Returns the completion block of `function`, or `nil` when it takes none.
    ///
    /// - Parameter function: A protocol method requirement.
    /// - Returns: The trailing block parameter, when the method is synchronous and the block returns
    ///   `Void`.
    static func of(_ function: FunctionDeclSyntax) -> CompletionBlock? {
        guard function.signature.effectSpecifiers?.asyncSpecifier == nil,
              let last = function.signature.parameterClause.parameters.last
        else { return nil }
        var isOptional = false
        guard let block = functionType(last.type, isOptional: &isOptional),
              isVoid(block.returnClause.type)
        else { return nil }
        let arguments = block.parameters.enumerated().map { position, element in
            let spelled = (element.secondName ?? element.firstName)?.text
            let key = spelled.flatMap { $0 == "_" ? nil : $0 } ?? String(position)
            return Argument(key: key, type: element.type.trimmedDescription)
        }
        let internalName = (last.secondName ?? last.firstName).text
        let external = last.firstName.text
        return CompletionBlock(
            name: internalName,
            label: external == "_" ? internalName : external,
            isOptional: isOptional,
            localType: spelledWithoutEscaping(last.type),
            arguments: arguments
        )
    }

    /// Returns the internal names of `function`'s parameters whose values a `call` records. A
    /// completion block is not an argument value: its delivery is recorded as its own event.
    ///
    /// - Parameter function: A protocol method requirement.
    /// - Returns: Every parameter's internal name, in order, except the completion block's.
    static func recordedArgumentNames(of function: FunctionDeclSyntax) -> [String] {
        let completion = of(function)?.name
        return function.signature.parameterClause.parameters
            .map { ($0.secondName ?? $0.firstName).text }
            .filter { $0 != completion }
    }

    /// The block's bound argument names inside a recording closure: `__b0, __b1, …`.
    var boundNames: [String] {
        arguments.indices.map { "__b\($0)" }
    }

    /// Returns the statements that record one delivery and run `deliver` between its two events.
    ///
    /// - Parameters:
    ///   - eventLabel: The delivery's label, `"<label>.<method>.<block>"`.
    ///   - deliver: The statement that runs the block, with the arguments bound as ``boundNames``.
    /// - Returns: The statements, newline-separated; they read `__oracle` and `self` from the
    ///   enclosing method.
    func recordedDelivery(eventLabel: String, deliver: String) -> String {
        let label = quotedLiteral(eventLabel)
        let payload = arguments.isEmpty ? "" : ", args: ["
            + zip(arguments, boundNames)
            .map { "\(quotedLiteral($0.key)): RuntimeValue.canonical(\($1) as Any)" }
            .joined(separator: ", ")
            + "]"
        return [
            "__oracle?.call(\(label), subject: self\(payload))",
            deliver,
            "__oracle?.ret(\(label), subject: self)"
        ].joined(separator: "\n")
    }

    /// Strips attributes (`@escaping`, `@Sendable`), optionality, and wrapping parentheses down to a
    /// function type.
    ///
    /// - Parameters:
    ///   - type: A parameter's spelled type.
    ///   - isOptional: Set when an optional or implicitly unwrapped layer was stripped.
    /// - Returns: The function type, or `nil` when `type` is not one.
    private static func functionType(_ type: TypeSyntax, isOptional: inout Bool) -> FunctionTypeSyntax? {
        if let function = type.as(FunctionTypeSyntax.self) {
            return function
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return functionType(attributed.baseType, isOptional: &isOptional)
        }
        if let optional = type.as(OptionalTypeSyntax.self) {
            isOptional = true
            return functionType(optional.wrappedType, isOptional: &isOptional)
        }
        if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            isOptional = true
            return functionType(unwrapped.wrappedType, isOptional: &isOptional)
        }
        if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first,
           only.firstName == nil {
            return functionType(only.type, isOptional: &isOptional)
        }
        return nil
    }

    private static func isVoid(_ type: TypeSyntax) -> Bool {
        let spelled = type.trimmedDescription
        return spelled == "Void" || spelled == "()"
    }
}

/// Whether a block argument's type is the Cocoa error slot: an optional `Error` or `NSError`.
///
/// - Parameter type: The block argument's spelled type.
/// - Returns: `true` for `(any Error)?`, `Error?`, `NSError?`, and their implicitly unwrapped forms.
func isErrorSlot(_ type: String) -> Bool {
    guard type.hasSuffix("?") || type.hasSuffix("!") else { return false }
    var bare = String(type.dropLast())
    if bare.hasPrefix("("), bare.hasSuffix(")") {
        bare = String(bare.dropFirst().dropLast())
    }
    return ["any Error", "Error", "NSError"].contains(bare)
}

/// Returns `type` spelled without its `@escaping` attribute, which describes a parameter rather than
/// a type — so the spelling is one a local declaration or a metatype expression accepts.
///
/// - Parameter type: A parameter's spelled type.
/// - Returns: The spelling, every other attribute kept.
func spelledWithoutEscaping(_ type: TypeSyntax) -> String {
    guard let attributed = type.as(AttributedTypeSyntax.self) else {
        return type.trimmedDescription
    }
    let kept = attributed.attributes.filter { element in
        element.as(AttributeSyntax.self)?.attributeName.trimmedDescription != "escaping"
    }
    let specifiers = attributed.specifiers.map(\.trimmedDescription)
    return (specifiers + kept.map(\.trimmedDescription) + [attributed.baseType.trimmedDescription])
        .joined(separator: " ")
}
