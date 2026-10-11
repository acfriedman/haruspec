import Foundation
import HaruspecSeams
import HaruspecTrace

// Settle points: where a capture lets held work land between operations.
//
// A capture used to run every operation first and drain the backlog once, after the last one. That
// is one legal schedule, and the most impatient user there is: a second refresh never meets a first
// one that finished, and a debounce never sees a user pause between letters. Draining after every
// operation instead only flips the blind spot. A port that answers from a cache the main queue fills
// later reads equivalent the moment every gap is settled, though today's schedule catches it.
//
// So each gap between two operations gets a setting: held (nothing runs, the old schedule), ready
// (`Settle.ready`) or elapsed (`Settle.elapsed`). A settle schedule is one setting per gap, and it is
// carried *inside* the ordering as engine-owned settle steps (`refresh → settle:elapsed → refresh`).
// That keeps it keyed by operation position rather than by held work, which a port rarely holds the
// same of, so the baseline and the candidate always run the same schedule and every run is still a
// pair. It also means the recorded plan, the failing order and the shrink carry the schedule with no
// second channel: removing a settle step turns its gap back to held.

extension Settle {
    /// The label a settle step carries in an ordering, `settle:elapsed`: the replay contract a plan
    /// records, so it is reserved and no declared op may take it.
    var stepLabel: String {
        "settle:\(rawValue)"
    }

    /// The setting a settle step's label names, or `nil` for any other label.
    ///
    /// - Parameter stepLabel: A label from an ordering.
    init?(stepLabel: String) {
        guard stepLabel.hasPrefix("settle:") else {
            return nil
        }
        self.init(rawValue: String(stepLabel.dropFirst("settle:".count)))
    }
}

extension Op {
    /// The engine's settle step for `settle`, which a capture runs by letting held work land instead
    /// of calling the subject.
    ///
    /// - Parameter settle: How far the held work may run.
    /// - Returns: A step labelled ``Settle/stepLabel``.
    static func settling(_ settle: Settle) -> Op<S> {
        var step = Op(settle.stepLabel) { (_: S) in }
        step.settle = settle
        return step
    }
}

/// One setting per gap between consecutive operations; `nil` is held.
typealias SettleSchedule = [Settle?]

/// Chooses which settle schedules an ordering runs under, from the many its gaps admit.
///
/// With three settings a gap, the space triples with every operation, so the budget buys a few,
/// and the order they are bought in decides which bugs a small budget still reaches.
enum SettleSchedules {
    /// Up to `max` distinct settle schedules over `gaps` gaps, edges before middles.
    ///
    /// - Parameters:
    ///   - gaps: How many gaps the ordering has: one fewer than its operations.
    ///   - max: How many schedules the budget buys this ordering.
    ///   - seed: Seeds the sample of the middle.
    /// - Returns: The all-held corner first (the capture as it ran before settle points, so a red it
    ///   found stays red), then the all-elapsed corner, then single flips off each corner, then a
    ///   sample of the rest. An ordering with no gaps has one schedule, the empty one.
    ///
    /// The corners are the impatient user and the patient one. A single flip is the user who waited
    /// once, or hurried once, which is where a bug that needs one earlier operation to have landed
    /// shows up first.
    static func sample(gaps: Int, max: Int, seed: UInt64) -> [SettleSchedule] {
        let held = SettleSchedule(repeating: nil, count: gaps)
        guard gaps > 0, max > 1 else {
            return [held]
        }
        let limit = Swift.min(max, spaceSize(gaps: gaps))
        var result: [SettleSchedule] = []
        var seen = Set<SettleSchedule>()
        func add(_ schedule: SettleSchedule) {
            if result.count < limit, seen.insert(schedule).inserted {
                result.append(schedule)
            }
        }
        let elapsed = SettleSchedule(repeating: .elapsed, count: gaps)
        add(held)
        add(elapsed)
        for (corner, flip) in [(held, Settle.elapsed), (elapsed, nil), (held, .ready), (
            elapsed,
            .ready
        )] as [(SettleSchedule, Settle?)] {
            for gap in 0 ..< gaps {
                var schedule = corner
                schedule[gap] = flip
                add(schedule)
            }
        }
        let settings: [Settle?] = [nil, .ready, .elapsed]
        var rng = SplitMix64(seed: seed)
        var attempts = 0
        while result.count < limit, attempts < limit * 20 {
            attempts += 1
            add((0 ..< gaps).map { _ in settings[Int(rng.next() % 3)] })
        }
        return result
    }

    /// How many settle schedules `gaps` gaps admit, three settings each, saturating rather than
    /// overflowing: past `Int.max` the budget is the binding limit anyway.
    ///
    /// - Parameter gaps: How many gaps the ordering has.
    /// - Returns: `3^gaps`, or `Int.max`.
    static func spaceSize(gaps: Int) -> Int {
        var size = 1
        for _ in 0 ..< gaps {
            let (next, overflow) = size.multipliedReportingOverflow(by: 3)
            guard !overflow else {
                return .max
            }
            size = next
        }
        return size
    }
}

/// `schedule`'s settle steps interleaved into `order`: each gap's setting between the two operations
/// around it, and nothing for a held gap.
///
/// - Parameters:
///   - schedule: One setting per gap of `order`.
///   - order: The declared operations, in the order they run.
/// - Returns: The ordering a capture drives.
func interleaving<S>(_ schedule: SettleSchedule, into order: [Op<S>]) -> [Op<S>] {
    precondition(
        schedule.count == Swift.max(0, order.count - 1),
        "a settle schedule has one setting per gap: \(order.count) operations, \(schedule.count) settings"
    )
    var result: [Op<S>] = []
    for (index, operation) in order.enumerated() {
        if index > 0, let settle = schedule[index - 1] {
            result.append(.settling(settle))
        }
        result.append(operation)
    }
    return result
}

/// Puts a shrink trial's ordering back into settle-schedule shape: at most one step per gap.
///
/// - Parameter order: An ordering with settle steps anywhere.
/// - Returns: The ordering with no settle step before the first operation or after the last, and
///   one at most between each two operations.
///
/// Where removing an operation left two steps side by side, the one that runs more (elapsed over
/// ready) stays, since the gap they now share saw both.
func normalizedSettles<S>(_ order: [Op<S>]) -> [Op<S>] {
    var result: [Op<S>] = []
    var pending: Settle?
    for operation in order {
        if let settle = operation.settle {
            pending = pending == .elapsed ? .elapsed : settle
            continue
        }
        if !result.isEmpty, let settle = pending {
            result.append(.settling(settle))
        }
        pending = nil
        result.append(operation)
    }
    return result
}

/// An ordering's labels without its settle steps: the declared operations it ran, which is what the
/// ordering axis counts and what a precondition reads.
///
/// - Parameter labels: An ordering's labels, settle steps included.
/// - Returns: The labels of the declared operations alone.
func operationLabels(_ labels: [String]) -> [String] {
    labels.filter { Settle(stepLabel: $0) == nil }
}
