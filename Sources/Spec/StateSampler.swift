import Foundation
import HaruspecCore
import HaruspecTrace

/// Reads a capture's observed properties at every settled point (after construction, after each op,
/// after each held work item) and records each value that moved since the last reading.
///
/// The end-state snapshot says where the subject finished; these say how it got there. A count that
/// never decrements, or a state that is never entered, can finish where the baseline does, and only
/// the path differs. Writes made within one work item read as one change, because nothing outside
/// the item could see between them.
final class StateSampler<S>: @unchecked Sendable {
    private let system: S
    private let properties: [Observed<S>]
    private let recorder: TraceRecorder
    private var last: [String: CanonicalValue] = [:]

    /// Creates a sampler over one capture.
    ///
    /// - Parameters:
    ///   - system: The build under capture, as the ops drive it.
    ///   - properties: The spec's observed properties.
    ///   - recorder: The capture's recorder.
    init(system: S, properties: [Observed<S>], recorder: TraceRecorder) {
        self.system = system
        self.properties = properties
        self.recorder = recorder
    }

    /// Reads every observed property and records a `.snapshot` for each value that changed.
    func sample() async {
        for property in properties {
            let value = await RuntimeValue.canonical(property.read(system))
            guard last[property.label] != value else { continue }
            last[property.label] = value
            recorder.snapshot(property.label, value: value)
        }
    }
}
