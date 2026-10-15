import Foundation

/// A stand-in the capture hands a subject in place of a real scheduler or queue, which holds the work
/// the subject gives it. A reach through one is captured, so the audit reports it without gating.
///
/// The audit reads source text, so it can't see which value a line calls. It reads which stand-ins the
/// capture actually held work through instead: a `queue.addOperation {` in a subject that was handed
/// `context.operationQueue` and ran work through it is that queue. What still gates is a way to get a
/// second, real one: `OperationQueue()` or `OperationQueue.main` in the subject's own code.
public enum HeldStandIn: String, Sendable, CaseIterable {
    /// `context.scheduler(_:)`: Combine's scheduled work, held on virtual time.
    case scheduler
    /// `context.operationQueue(_:)`: an operation queue's operations and completion blocks, held.
    case operationQueue

    /// The channel and spellings a reach through this stand-in matches.
    var covers: (channel: String, spellings: [String]) {
        switch self {
        case .scheduler:
            // Combine escapes the capture only through a scheduler; a direct `DispatchQueue.main` or
            // `RunLoop.main` in a pipeline is its own finding under `dispatch` or `Timer / RunLoop`.
            ("Combine", ["import Combine", "PassthroughSubject", "CurrentValueSubject", ".sink("])
        case .operationQueue:
            ("dispatch", ["addOperationWithBlock", "addOperation {", "addOperation(", "addOperation:"])
        }
    }

    /// Whether a reach on `channel`, spelled `spelling`, goes through one of `standIns`.
    ///
    /// - Parameters:
    ///   - channel: The finding's channel.
    ///   - spelling: The spelling that matched.
    ///   - standIns: The stand-ins the capture held work through.
    /// - Returns: `true` when one of `standIns` covers that channel and spelling.
    static func covers(_ channel: String, _ spelling: String, through standIns: Set<HeldStandIn>) -> Bool {
        standIns.contains { $0.covers.channel == channel && $0.covers.spellings.contains(spelling) }
    }
}
