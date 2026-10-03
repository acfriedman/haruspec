import SwiftSyntax
import SwiftSyntaxMacros

// MARK: - Scheduling protocols (the project's thread seams)

/// One requirement of a scheduling protocol, classified by its shape. The shape is the whole
/// contract: whether the work escapes says whether it is held or run inline, an `async` body says it
/// is a task, and a second parameter says what releases it.
private enum SchedulingShape {
    /// `func async(_ work: @escaping () -> Void)`: held, run in enqueue order.
    case enqueue(work: String)
    /// `func spawn(_ operation: @escaping () async -> Void)`: an unstructured task, held.
    case spawn(operation: String)
    /// `func after(_ delay: TimeInterval, _ work: @escaping () -> Void)`: held on virtual time.
    case delayed(work: String, delay: String)
    /// `func notify(_ group: DispatchGroup, _ work: @escaping () -> Void)`: held until the group empties.
    case notify(work: String, group: String)
    /// `func sync(_ work: () -> Void)`: run inline, after the queue's held work.
    case sync(work: String)
}

/// The shapes a scheduling protocol's requirements may take, named in every rejection.
private let acceptedShapes = """
a scheduling protocol's requirements take one of these shapes: \
`(_ work: @escaping () -> Void)` (enqueue), \
`(_ work: @escaping () async -> Void)` (spawn a task), \
`(_ delay: TimeInterval, _ work: @escaping () -> Void)` (enqueue after a delay), \
`(_ group: DispatchGroup, _ work: @escaping () -> Void)` (notify when the group empties), \
`(_ work: () -> Void)` (sync), each returning Void
"""

/// Emits the double for a stamped scheduling protocol (`@Haruspec(schedules: .serial)`): the stand-in
/// that holds the work it is handed in the capture's backlog instead of running it on a thread.
///
/// A scheduling protocol is the project's own seam over GCD, `Task`, or a Combine scheduler.
/// Production conforms a real queue to it; under test its double hands every enqueue to the capture's
/// `WorkBacklog`, which the engine drains one item at a time, so the subject's handed-off work is
/// reached, counted, and run in one deterministic order.
///
/// The double records no events of its own. What a scheduler contributes to a trace is *where* the
/// work ran (its domain) and *what caused it* (the spawn edge on its first event), both of which the
/// backlog stamps on the work's own events.
///
/// It is the only role a scheduling protocol plays: a scheduler is never a subject, so no forwarder
/// or op catalog is emitted.
enum SchedulerEmitter {
    /// The generated `Double<Protocol>` for a scheduling protocol.
    ///
    /// - Parameters:
    ///   - proto: The stamped protocol.
    ///   - label: Its trace label, which names its domain.
    ///   - discipline: The stamp's `schedules:` case: `serial`, `concurrent`, or `main`.
    /// - Returns: The double's class declaration.
    /// - Throws: A `MacroError` naming the requirement whose shape a scheduler cannot hold.
    static func double(for proto: ProtocolDeclSyntax, label: String, discipline: String) throws -> DeclSyntax {
        let protoName = proto.name.text
        let generatedName = "Double\(protoName)"
        var methods: [String] = []
        var hasSync = false
        var hasSpawn = false
        for member in proto.memberBlock.members {
            let decl = member.decl
            guard let function = decl.as(FunctionDeclSyntax.self), !isStaticOrClass(function.modifiers) else {
                throw MacroError("\(protoName): a scheduling protocol declares only methods; \(acceptedShapes)")
            }
            let shape = try classify(function, in: protoName)
            switch shape {
            case .sync:
                hasSync = true
            case .spawn:
                hasSpawn = true
            default:
                break
            }
            methods.append(method(function, shape: shape, label: label, discipline: discipline))
        }
        if hasSync, discipline == "main" {
            throw MacroError(
                "\(protoName): a main-queue protocol cannot declare a sync: main.sync from the main thread deadlocks"
            )
        }
        if hasSync, hasSpawn {
            throw MacroError(
                "\(protoName): a protocol that spawns async work cannot also declare a sync, "
                    + "which would have to wait for a task synchronously"
            )
        }
        if methods.isEmpty {
            throw MacroError("\(protoName): a scheduling protocol needs at least one requirement; \(acceptedShapes)")
        }

        let refined = (proto.inheritanceClause?.inheritedTypes ?? [])
            .map(\.type.trimmedDescription)
            .filter { $0 != "AnyObject" && $0 != "NSObjectProtocol" && $0 != "Sendable" }
        let boundaries = ([protoName] + refined).map { "\($0).self" }.joined(separator: ", ")

        let source = """
        final class \(generatedName): NSObject, \(protoName), SeamDouble, @unchecked Sendable {
            private let __seams: SeamContext
            init(_ seams: SeamContext) { __seams = seams; super.init() }

            nonisolated var traceLabel: String { \(quotedLiteral(label)) }

            static var servedBoundaries: [Any.Type] { [\(boundaries)] }

        \(methods.joined(separator: "\n\n"))
        }
        """
        return DeclSyntax("\(raw: source)")
    }

    /// Returns the double's witness for one requirement: a hand-off to the capture's backlog.
    private static func method(
        _ function: FunctionDeclSyntax,
        shape: SchedulingShape,
        label: String,
        discipline: String
    ) -> String {
        let queue = "on: self, label: \(quotedLiteral(label)), discipline: .\(discipline)"
        let body = switch shape {
        case let .enqueue(work):
            "__seams.backlog.enqueue(\(queue), \(work))"
        case let .spawn(operation):
            "__seams.backlog.spawn(\(queue), \(operation))"
        case let .delayed(work, delay):
            "__seams.backlog.enqueue(\(queue), after: TimeInterval(\(delay)), \(work))"
        case let .notify(work, group):
            "__seams.backlog.enqueue(\(queue), notifying: \(group), \(work))"
        case let .sync(work):
            "__seams.backlog.runSync(\(queue), \(work))"
        }
        return "    func \(function.name.text)\(function.signature.trimmedDescription) {\n        \(body)\n    }"
    }

    /// Classifies a requirement by its parameters, or rejects it naming the shapes a scheduler holds.
    private static func classify(_ function: FunctionDeclSyntax, in protoName: String) throws -> SchedulingShape {
        let reject = MacroError("\(protoName).\(function.name.text): \(acceptedShapes)")
        let signature = function.signature
        let returnType = signature.returnClause?.type.trimmedDescription
        guard signature.effectSpecifiers == nil, function.genericParameterClause == nil,
              returnType == nil || returnType == "Void" || returnType == "()"
        else { throw reject }

        let parameters = Array(signature.parameterClause.parameters)
        let blocks = parameters.compactMap { parameter in WorkBlock(parameter).map { (parameter, $0) } }
        guard blocks.count == 1, let (block, work) = blocks.first else { throw reject }
        let workName = internalName(block)

        if parameters.count == 1 {
            if work.isAsync {
                guard work.escapes else { throw reject }
                return .spawn(operation: workName)
            }
            return work.escapes ? .enqueue(work: workName) : .sync(work: workName)
        }
        guard parameters.count == 2, work.escapes, !work.isAsync,
              let other = parameters.first(where: { $0.trimmedDescription != block.trimmedDescription })
        else { throw reject }
        let otherType = other.type.trimmedDescription
        if ["TimeInterval", "Double", "NSTimeInterval"].contains(otherType) {
            return .delayed(work: workName, delay: internalName(other))
        }
        if ["DispatchGroup", "dispatch_group_t"].contains(otherType) {
            return .notify(work: workName, group: internalName(other))
        }
        throw reject
    }

    private static func internalName(_ parameter: FunctionParameterSyntax) -> String {
        (parameter.secondName ?? parameter.firstName).text
    }
}

/// A parameter typed as a block taking nothing and returning `Void`: the work a scheduler is handed.
private struct WorkBlock {
    /// Whether the parameter is `@escaping`: held work, rather than work run before the call returns.
    let escapes: Bool
    /// Whether the block is `async`: a task's body.
    let isAsync: Bool

    init?(_ parameter: FunctionParameterSyntax) {
        var type = parameter.type
        var escapes = false
        while true {
            if let attributed = type.as(AttributedTypeSyntax.self) {
                escapes = escapes || attributed.attributes.contains { element in
                    element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "escaping"
                }
                type = attributed.baseType
            } else if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
                      let only = tuple.elements.first, only.firstName == nil {
                type = only.type
            } else {
                break
            }
        }
        // GCD's own block type, as a pasted Obj-C interface may spell it.
        if type.as(IdentifierTypeSyntax.self)?.name.text == "dispatch_block_t" {
            self.escapes = escapes
            isAsync = false
            return
        }
        guard let function = type.as(FunctionTypeSyntax.self), function.parameters.isEmpty,
              ["Void", "()"].contains(function.returnClause.type.trimmedDescription),
              function.effectSpecifiers?.throwsClause == nil
        else { return nil }
        self.escapes = escapes
        isAsync = function.effectSpecifiers?.asyncSpecifier != nil
    }
}
