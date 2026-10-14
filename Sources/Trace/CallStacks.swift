import Foundation
import HaruspecCore

/// Each thread's traced calls still in progress, and which of them encloses an event recorded now.
///
/// An effect emitted inside a call belongs to the domain of the work that caused it, even when the
/// machinery that carried it (Foundation's notification dispatch, a collaborator decorator) sits one
/// frame away and is isolated to nothing itself; and work handed off inside a call names that call as
/// its cause. A forwarder binds its call for its task as well (``TraceContext/withOpenCall(_:_:)``),
/// since an `await` can resume its body on another thread; these stacks hold calls recorded straight
/// on the recorder, and are mutated only under the recorder's lock.
struct CallStacks {
    private var byThread: [ObjectIdentifier: [TraceContext.OpenCall]] = [:]

    /// Pushes `call` on the current thread's stack.
    ///
    /// - Parameter call: The call just recorded.
    mutating func push(_ call: TraceContext.OpenCall) {
        byThread[ObjectIdentifier(Thread.current), default: []].append(call)
    }

    /// Pops the current thread's latest call, if it has one.
    ///
    /// Defensive rather than symmetric: an async traced call may resume on another thread, leaving
    /// this one's stack short, and popping what is not there would end a caller still running.
    mutating func pop() {
        let thread = ObjectIdentifier(Thread.current)
        if byThread[thread]?.isEmpty == false {
            byThread[thread]?.removeLast()
        }
    }

    /// Returns the traced call enclosing an event recorded now.
    ///
    /// - Returns: The later of the task's bound call and this thread's latest call at or above the
    ///   task's floor; with no task scope, this thread's latest call; `nil` when no call encloses.
    func enclosing() -> TraceContext.OpenCall? {
        let onThread = byThread[ObjectIdentifier(Thread.current)]?.last
        guard let scope = TraceContext.callScope else {
            return onThread
        }
        let candidates = [scope.call, onThread.flatMap { $0.seq >= scope.floor ? $0 : nil }].compactMap(\.self)
        return candidates.max { $0.seq < $1.seq }
    }
}
