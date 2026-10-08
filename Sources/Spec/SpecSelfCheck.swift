import Foundation
import HaruspecCore
import HaruspecSeams

extension Spec {
    /// Returns the live differential's stability: the baseline compared against itself over one
    /// input. A baseline that cannot reproduce itself makes any red against it noise.
    ///
    /// - Parameters:
    ///   - baseline: Builds a fresh baseline per capture.
    ///   - order: The call sequence the input drives.
    ///   - cassette: The seam readings both captures replay.
    /// - Returns: A single-run stability carrying the self-check, unstable when the two captures
    ///   diverged, with the varying payload fields named as uncontrolled seams.
    func selfCheck(
        baseline: @escaping (SeamContext) -> S,
        order: [Op<S>],
        cassette: CassetteData
    ) async -> Stability {
        let diff = await compare(
            make: baseline,
            candidate: baseline,
            order: order,
            cassette: cassette,
            declaring: .none
        ).diff
        let seams = UncontrolledSeam.found(in: diff.divergences)
        return Stability(
            replays: 1,
            outcomes: [],
            baselineSelfCheck: diff.divergences.map(\.stabilityFingerprint),
            uncontrolledSeams: seams.isEmpty ? nil : seams
        )
    }
}
