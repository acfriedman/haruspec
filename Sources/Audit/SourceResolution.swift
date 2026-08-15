import Foundation
import HaruspecTrace

/// The files an audit must read to judge one traced declaration — or the fact that there are none.
///
/// The second half is the point. A resolution that found nothing is not "nothing to check": a binary
/// framework with no source, a class that moved, and a typo all look identical from here, and all
/// three have to land on the side that keeps a verdict from going green. So `files` being empty is
/// never silently equivalent to a clean read — callers gate on `isResolved`.
public struct SourceResolution: Sendable, Equatable {
    /// The declaration this resolves, as the instrumentation registered it (see `TraceOrigin`).
    public let origin: TraceOrigin
    /// Every file declaring it, relative to the resolver's root, sorted. More than one is normal and
    /// wanted: an Obj-C class plus its categories, which is exactly where a bypassed channel hides.
    public let files: [String]

    public init(origin: TraceOrigin, files: [String]) {
        self.origin = origin
        self.files = files
    }

    /// Whether an audit can say anything about this declaration at all.
    public var isResolved: Bool {
        !files.isEmpty
    }

    /// How the qualification block names an unresolved declaration — a blind spot with a reason, so a
    /// clean lint over everything else can never read as clean over the whole subject.
    public var unresolvedDescription: String? {
        isResolved ? nil : "\(origin.symbol ?? origin.label) (no source found)"
    }
}
