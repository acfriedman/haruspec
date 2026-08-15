import Foundation
import HaruspecCore
import HaruspecTrace

// The audit's denominator, carried onto the verdict: which sources the covered labels were declared
// in. `coveredClasses` names labels, and a label is deliberately not a type name — so nothing in a
// verdict could previously say *what an audit would have to read* to claim the capture saw every
// effect channel. The macro stamps each declaration (see `TraceOrigin`); this is where one
// verification's worth of them is scoped, collected, and stamped onto the verdict it produced.

extension Spec {
    /// Run one verification with an origin collector bound, and carry what it reached onto its verdict.
    ///
    /// Bound around the *whole* verification rather than per capture: the origins of interest span the
    /// baseline and the candidate (a PR audit cares most about the sources the candidate introduced),
    /// and every replay pass of a stability run is the same build. Scoped rather than process-wide, so
    /// specs running in parallel — the default under swift-testing — cannot pool sources into each
    /// other's verdicts.
    func collectingOrigins(
        declaring intent: Intent,
        _ verification: () async -> SpecVerdict
    ) async -> SpecVerdict {
        let origins = OriginCollector()
        let verdict = await TraceOrigins.$collector.withValue(origins) { await verification() }
            .noting(origins: origins.snapshot)
        // The audit rides the same wrapper because it needs exactly what this collected. No configured
        // root means no audit and no claim: `blindSpots` stays nil and every surface says "not audited".
        guard let root = AuditRoot.fromEnvironment() else { return verdict }
        return verdict.audited(against: root, declaring: intent)
    }
}

extension SpecVerdict {
    /// Carry the origins one verification collected onto the verdict it produced. Applied last because
    /// the qualification is resolved off the golden template, before a candidate has run.
    func noting(origins: [TraceOrigin]) -> SpecVerdict {
        SpecVerdict(
            schemaVersion: schemaVersion,
            result: result,
            orderingsExplored: orderingsExplored,
            failingOrder: failingOrder,
            counterexample: counterexample,
            exploration: exploration,
            qualification: qualification.noting(origins: origins),
            violatedPreconditions: violatedPreconditions,
            stability: stability
        )
    }
}

extension TraceOrigin {
    /// One declaration as the qualification block prints it. "no source" is the load-bearing half: it
    /// marks reached behavior an audit structurally cannot read, so a clean lint over everything else
    /// never reads as clean over the whole subject.
    var declarationEntry: String {
        switch (symbol, source) {
        case let (symbol?, source?): "\(symbol) (\(source))"
        case let (symbol?, nil): "\(symbol) (no source)"
        case let (nil, source?): source
        case (nil, nil): "unknown"
        }
    }
}
