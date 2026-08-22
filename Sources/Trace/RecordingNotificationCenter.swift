import Foundation
import HaruspecCore

/// A `NotificationCenter` that records what is posted through it — the notification boundary observed
/// by **injection**, the same way a collaborator is observed through a `@TracedForwarder` decorator.
///
/// Not an observer registered from the outside: that shape makes notifications a *second capture
/// path* with different rules from every other kind of event — it holds the recorder directly instead
/// of looking it up, and it sees no call site, so it has nothing to resolve a domain from. That
/// asymmetry breeds exactly the concurrency bugs that cost the most to find — a notification landing
/// while a traced call from the same block vanishes, one actor method reporting two domains. One
/// capture path cannot produce either.
///
/// Injection is the right shape *here* specifically, and the distinction is worth keeping: a
/// notification center is a collaborator, and handing one in is ordinary practice. A dispatch queue
/// or a `Task` is a language mechanism nobody injects, which is why those are reached by a seam.
///
/// Substitutable wherever a `NotificationCenter` is expected, so legacy Objective-C that posts through
/// an injected center needs no change — the posting call is the app's own, unmodified.
///
/// Records **everything** posted through it, deliberately: a filter here would be an allowlist, whose
/// only power is hiding a channel the subject starts posting. The noise knob is the spec's
/// `.ignore(notifications:)` — subtractive, applied at diff time, raw trace complete.
public final class RecordingNotificationCenter: NotificationCenter, @unchecked Sendable {
    /// Every posting spelling funnels here — `postNotificationName:object:userInfo:` and its shorter
    /// forms all end at `post(_:)` in Foundation, and overriding the funnel rather than each spelling
    /// is what keeps a post from being recorded twice or missed.
    override public func post(_ notification: Notification) {
        record(notification)
        super.post(notification)
    }

    override public func post(name: NSNotification.Name, object: Any?, userInfo: [AnyHashable: Any]? = nil) {
        // Routed explicitly rather than trusting the superclass to funnel: `post(name:object:userInfo:)`
        // is a distinct Objective-C selector, and legacy code reaches it directly.
        post(Notification(name: name, object: object, userInfo: userInfo))
    }

    override public func post(name aName: NSNotification.Name, object anObject: Any?) {
        post(Notification(name: aName, object: anObject, userInfo: nil))
    }

    private func record(_ notification: Notification) {
        guard let recorder = TraceContext.active else { return }
        recorder.notification(
            notification.name.rawValue,
            subject: notification.object.map { $0 as AnyObject },
            payload: notification.userInfo.map { RuntimeValue.canonical($0) }
        )
    }
}
