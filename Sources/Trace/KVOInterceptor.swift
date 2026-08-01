import Foundation
import HaruspecCore

/// Captures Key-Value-Observing changes as `stateChange` events — a scaffold for the runtime capture
/// of observable property mutations, complementing notification capture.
///
/// Works on any `NSObject` with `@objc dynamic` properties; each observed change is recorded with the
/// key path as the label and the new value canonicalized. Not yet wired into the (struct-based) demo
/// model — it proves the mechanism for ObjC/KVO-heavy legacy code.
public final class KVOInterceptor: NSObject, @unchecked Sendable {
    private let recorder: TraceRecorder
    private let lock = NSLock()
    private var observed: [(object: NSObject, keyPath: String)] = []

    public init(recorder: TraceRecorder) {
        self.recorder = recorder
        super.init()
    }

    /// Begin observing the given key paths (e.g. `["count"]`) on an object.
    public func observe(_ object: NSObject, keyPaths: [String]) {
        lock.lock(); defer { lock.unlock() }
        for keyPath in keyPaths {
            object.addObserver(self, forKeyPath: keyPath, options: [.new], context: nil)
            observed.append((object, keyPath))
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        for (object, keyPath) in observed {
            object.removeObserver(self, forKeyPath: keyPath)
        }
        observed.removeAll()
    }

    override public func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                      change: [NSKeyValueChangeKey: Any]?,
                                      context _: UnsafeMutableRawPointer?) {
        guard let keyPath, let newValue = change?[.newKey] else { return }
        recorder.stateChange(keyPath, subject: object as AnyObject?, value: RuntimeValue.canonical(newValue))
    }
}
