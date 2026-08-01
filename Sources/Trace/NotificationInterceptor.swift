import Foundation
import HaruspecCore

/// Captures `NotificationCenter` posts into a `TraceRecorder` with **no changes to app code**.
///
/// This is the runtime half of the layered capture model: side effects like notifications are
/// emitted as ordinary statements inside method bodies, so instead of hand-recording each one, we
/// observe the center during a capture window and record every matching post. Posts are delivered
/// synchronously on the posting thread, so trace ordering relative to other events is preserved.
///
/// The default (`names == nil`) captures **everything** — a behavioral oracle watches all behavior,
/// so nothing on an un-listed channel becomes a silent blind spot. Pass a non-nil `names` set only to
/// narrow to an explicit allowlist (e.g. when a SUT shares a noisy center). Diff-time channel filtering
/// (`ToleranceSpec.ignoredNotificationNames`) is the preferred way to drop a single noisy channel while
/// keeping the rest, since it leaves the raw trace faithful.
///
/// **Isolation is structural, not filtered.** A capture window observes the `center` it is handed. The
/// scenario runner hands each window a *fresh* `NotificationCenter()` (surfaced to the SUT as
/// `SeamContext.notifications`), so posts from one window never reach another — no shared global to
/// cross-pollinate. If a caller deliberately points a window at a process-wide center (`.observing(on:
/// .default)`), isolation becomes their responsibility (serialize the suite, or don't share the center
/// across parallel windows); there is no runtime thread-scope filter papering that over.
public final class NotificationInterceptor: @unchecked Sendable {
    private let recorder: TraceRecorder
    private let center: NotificationCenter
    private let names: Set<String>?
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    public init(recorder: TraceRecorder, center: NotificationCenter = .default, names: Set<String>? = nil) {
        self.recorder = recorder
        self.center = center
        self.names = names
    }

    /// Begin observing. Safe to call once; call `stop()` to end the capture window.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard tokens.isEmpty else { return }
        if let names {
            for name in names {
                let token = center.addObserver(forName: Notification.Name(name),
                                               object: nil, queue: nil) { [weak self] in
                    self?.record($0)
                }
                tokens.append(token)
            }
        } else {
            tokens.append(center.addObserver(forName: nil, object: nil, queue: nil) { [weak self] in
                self?.record($0)
            })
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
    }

    private func record(_ note: Notification) {
        let payload = note.userInfo.map { RuntimeValue.canonical($0) }
        recorder.notification(note.name.rawValue, subject: note.object.map { $0 as AnyObject }, payload: payload)
    }
}
