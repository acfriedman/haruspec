import Foundation
import HaruspecCore

// A build named by its initializer: `check(SwiftCart.init)`. Every parameter resolves the way a
// derived system's do (a declared resource, the one double serving the boundary, the capture's
// center), so a port whose dependencies differ from the baseline's is still one line, with no
// closure restating the wiring and no name string restating the type.

public extension SeamContext {
    /// Returns what `initializer` builds with every parameter resolved for this capture.
    ///
    /// - Parameter initializer: The build's initializer, as in `build(SwiftCart.init)`, spelled with
    ///   its labels when overloaded. Each parameter type must be resolvable.
    /// - Returns: A fresh build; each call resolves fresh collaborators.
    /// - Precondition: Every parameter type resolves through ``resolve(_:)``; the trap names the
    ///   declaration that would serve the one that does not.
    func build<each Parameter, Built>(_ initializer: (repeat each Parameter) -> Built) -> Built {
        initializer(repeat resolve((each Parameter).self))
    }
}

public extension Spec {
    /// Declares the baseline by its initializer, every parameter resolved per capture.
    ///
    /// - Parameter initializer: The baseline's initializer, as in `.system(CartManager.init)`.
    /// - Returns: The spec with its system declared.
    func system<each Parameter>(_ initializer: @escaping (repeat each Parameter) -> some Any) -> Spec<S> {
        system { context in Self.conforming(context.build(initializer)) }
    }

    /// Provides a capture resource by its initializer, every parameter resolved per capture.
    ///
    /// - Parameter initializer: The resource's initializer, as in `.provides(ImageLoader.init)`.
    /// - Returns: The spec, serving the initializer's result type wherever a build asks for it.
    func provides<each Parameter, Built>(_ initializer: @escaping (repeat each Parameter) -> Built) -> Spec<S> {
        provides(Built.self) { context in context.build(initializer) }
    }

    /// Verifies the build `initializer` makes, titled by its type unless `named` says otherwise.
    ///
    /// - Parameters:
    ///   - initializer: The port's initializer, as in `check(SwiftCart.init)`; its parameters may
    ///     differ from the baseline's.
    ///   - name: The report's title; the built type's name when `nil`.
    ///   - expected: The verdict the build must earn.
    ///   - intent: The deltas this port is meant to produce.
    ///   - directory: Where the HTML report goes; Haruspec's temp folder when `nil`.
    /// - Returns: The verdict.
    /// - Throws: `SpecCatalog.CheckFailure` unless the build earned `expected`.
    @discardableResult
    func check<each Parameter, Built>(
        _ initializer: @escaping (repeat each Parameter) -> Built,
        named name: String? = nil,
        expecting expected: TraceDiff.Verdict = .equivalent,
        declaring intent: Intent = .none,
        reportsIn directory: URL? = nil
    ) async throws -> SpecVerdict {
        try await check(
            name ?? String(describing: Built.self),
            expecting: expected,
            declaring: intent,
            reportsIn: directory
        ) { context in Self.conforming(context.build(initializer)) }
    }

    /// Returns `build` as the spec's system.
    ///
    /// - Parameter build: A freshly built conformer.
    /// - Returns: `build`, typed as the boundary.
    /// - Precondition: `build` conforms to the boundary; a spec over `any Proto` cannot demand it
    ///   statically, so the trap names the extension to write.
    private static func conforming(_ build: Any) -> S {
        guard let system = build as? S else {
            preconditionFailure(
                "\(type(of: build)) does not conform to \(S.self) — add `extension \(type(of: build)): <boundary> {}`"
            )
        }
        return system
    }
}

public extension SpecProviding {
    /// Verifies the build `initializer` makes — see ``Spec/check(_:named:expecting:declaring:reportsIn:)``.
    ///
    /// - Parameters:
    ///   - initializer: The port's initializer, as in `check(SwiftCart.init)`.
    ///   - name: The report's title; the built type's name when `nil`.
    ///   - expected: The verdict the build must earn.
    ///   - intent: The deltas this port is meant to produce.
    ///   - directory: Where the HTML report goes; Haruspec's temp folder when `nil`.
    /// - Returns: The verdict.
    /// - Throws: `SpecCatalog.CheckFailure` unless the build earned `expected`.
    @discardableResult
    func check<each Parameter>(
        _ initializer: @escaping (repeat each Parameter) -> some Any,
        named name: String? = nil,
        expecting expected: TraceDiff.Verdict = .equivalent,
        declaring intent: Intent = .none,
        reportsIn directory: URL? = nil
    ) async throws -> SpecVerdict {
        try await spec.check(initializer, named: name, expecting: expected, declaring: intent, reportsIn: directory)
    }
}
