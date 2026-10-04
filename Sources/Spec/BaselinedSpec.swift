import Foundation
import HaruspecCore
import HaruspecSeams

// A spec declares how a boundary is interrogated and names no implementation. Which implementation is
// trusted is a fact about the test — a migration's legacy type, or the shipping build a PR replays
// against — so the test binds it with `.baselined(on:)`, and only the bound spec runs.

/// A spec bound to the baseline every comparison is measured against. Every run lives here, because
/// each needs the implementation whose behavior is the oracle.
///
///     struct CartMigrationTests {
///         let subject = CartSpec().baselined(on: CartManager.self)
///
///         @Test func swiftPort() async throws {
///             try await subject.check(SwiftCart.self)
///         }
///     }
public struct BaselinedSpec<S> {
    /// The interrogation the baseline and every candidate are driven through.
    public let spec: Spec<S>
    /// Builds a fresh baseline per capture.
    let baseline: (SeamContext) -> S
    /// The builds a catalog can enumerate, declared via ``candidates(_:)``. Empty for a suite that
    /// checks each build inline, which is the ordinary case.
    var candidates: [Candidate<S>] = []

    /// The spec's name, which titles reports, plans, and catalog entries.
    public var name: String {
        spec.name
    }
}

public extension Spec {
    /// Returns this spec bound to the baseline `make` builds. Seams are injected here, so a boundary
    /// the baseline reaches without an injected seam is unobserved.
    ///
    /// - Parameter make: Builds a fresh baseline per capture from the capture's context, which
    ///   carries the center and recording doubles to inject.
    /// - Returns: The bound spec.
    func baselined(on make: @escaping (SeamContext) -> S) -> BaselinedSpec<S> {
        BaselinedSpec(spec: settled(), baseline: make)
    }

    /// Returns this spec bound to the baseline `initializer` builds, every parameter resolved per
    /// capture.
    ///
    /// - Parameter initializer: The baseline's initializer, as in `.baselined(on: CartManager.init)`,
    ///   spelled with its labels when overloaded.
    /// - Returns: The bound spec.
    /// - Precondition: The built type conforms to the boundary; the trap names the extension to write.
    func baselined<each Parameter>(
        on initializer: @escaping (repeat each Parameter) -> some Any
    ) -> BaselinedSpec<S> {
        baselined { context in Self.conforming(context.build(initializer)) }
    }

    /// Returns this spec bound to `conformer`, built through the boundary's pasted `init` and wrapped
    /// in its forwarder. A port checked by type takes the same path, so the sides differ only in type.
    ///
    /// - Parameter conformer: The baseline's type; it must conform to the boundary protocol.
    /// - Returns: The bound spec.
    /// - Precondition: The spec derives construction (its stamped protocol pastes its `init`);
    ///   otherwise the trap says to bind a closure instead. A non-conformer traps at the
    ///   first capture, naming the extension to write.
    func baselined(on conformer: Any.Type) -> BaselinedSpec<S> {
        let spec = settled()
        return spec.baselined(on: spec.constructing(conformer))
    }

    /// Returns the derived construction of `conformer`.
    ///
    /// - Parameter conformer: The type to build through the boundary's pasted `init`.
    /// - Returns: A per-capture build of `conformer`.
    /// - Precondition: The spec derives construction; the trap names both ways to supply it.
    internal func constructing(_ conformer: Any.Type) -> (SeamContext) -> S {
        guard let construct = makeConformer else {
            preconditionFailure(
                "spec '\(name)' derives no construction, so it cannot build \(conformer) — paste the "
                    + "init into the @Haruspec protocol, or build it by closure: "
                    + "{ context in … }"
            )
        }
        return { construct($0, conformer) }
    }
}

public extension SpecProviding {
    /// Returns the declared spec bound to the baseline `make` builds — see ``Spec/baselined(on:)``.
    ///
    /// - Parameter make: Builds a fresh baseline per capture from the capture's context.
    /// - Returns: The bound spec.
    func baselined(on make: @escaping (SeamContext) -> System) -> BaselinedSpec<System> {
        spec.baselined(on: make)
    }

    /// Returns the declared spec bound to the baseline `initializer` builds.
    ///
    /// - Parameter initializer: The baseline's initializer, as in `.baselined(on: CartManager.init)`.
    /// - Returns: The bound spec.
    func baselined<each Parameter>(
        on initializer: @escaping (repeat each Parameter) -> some Any
    ) -> BaselinedSpec<System> {
        spec.baselined(on: initializer)
    }

    /// Returns the declared spec bound to `conformer`, built through the boundary's pasted `init`.
    ///
    /// - Parameter conformer: The baseline's type; it must conform to the boundary protocol.
    /// - Returns: The bound spec.
    func baselined(on conformer: Any.Type) -> BaselinedSpec<System> {
        spec.baselined(on: conformer)
    }
}
