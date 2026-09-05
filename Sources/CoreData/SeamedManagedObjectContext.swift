import CoreData
import Foundation
import HaruspecSeams
import HaruspecSpec

// Core Data support for persistence-bearing subjects: the store is *internal state*, not an effect
// channel — isolate it as a capture resource (`Spec.provides`), observe it through the subject's own
// read-back surface, and accept the channel by name (`.accepts(uncaptured: "Core Data")`). This
// module packages the resource half of that doctrine so an adopter authors none of it.

/// A managed-object context whose ``save()`` is a seam-controlled failure choke point; real Core
/// Data stays behind every call.
///
/// - Important: The context is *private-queue*: ops drive the subject from harness threads, and a
///   main-queue context touched off main is exactly the Core Data crash. The subject serializes
///   onto the context's own queue, so the queue's identity is the context's business, not the
///   caller's.
///
/// A forwarder over the store, not a double: `super` is Core Data, so the semantics being certified
/// remain Apple's. The harness gains control at the one choke point persistence can fail, through a
/// seam read that records and replays like any other. The call stream is deliberately unrecorded —
/// delete-then-insert vs. update-in-place is implementation, and making the context's conversation
/// compared surface would pin it.
public final class SeamedManagedObjectContext: NSManagedObjectContext, @unchecked Sendable {
    /// The seam ``save()`` reads: `false` passes through to the store; `true` throws.
    ///
    /// Swept over both values by default once a run reaches a save (`sweptSeams`) — how a port
    /// reacts to a failed save is behavioral surface, not luck. A spec pins it to opt out:
    /// `.vary { Seam(SeamedManagedObjectContext.saveFailureSeam, .anyOf([.bool(false)])) }`.
    public static let saveFailureSeam = "ManagedObjectContext.save.fails"

    private let seams: SeamContext

    public init(seams: SeamContext) {
        self.seams = seams
        super.init(concurrencyType: .privateQueueConcurrencyType)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("a capture resource is never decoded")
    }

    /// Saves through to the store, unless the ``saveFailureSeam`` reading says to fail first.
    ///
    /// - Throws: `NSPersistentStoreSaveError` when the seam reads `true` — before the store is
    ///   touched, so a failed save leaves the context's pending changes exactly as Core Data would.
    ///   Otherwise whatever the store's own save throws.
    override public func save() throws {
        if seams.bool(Self.saveFailureSeam, default: false) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSPersistentStoreSaveError,
                userInfo: [NSLocalizedDescriptionKey: "injected persistence failure"]
            )
        }
        try super.save()
    }

    /// Returns a fresh in-memory stack behind a seamed context — the `Spec.provides` resource for a
    /// persistence-bearing subject, so probes are isolated and nothing durable leaks between runs.
    ///
    /// - Parameters:
    ///   - model: The subject's own managed-object model. Load it once and reuse it across
    ///     captures — models are process-wide, and re-merging per capture is waste.
    ///   - seams: The capture's context, handed through by the `provides` maker.
    /// - Precondition: The in-memory store must load; a model that cannot back a store is a broken
    ///   fixture, not a verdict.
    public static func inMemory(model: NSManagedObjectModel, seams: SeamContext) -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "Haruspec", managedObjectModel: model)
        let store = NSPersistentStoreDescription()
        store.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [store]
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        precondition(failure == nil, "in-memory store failed to load: \(String(describing: failure))")
        let context = SeamedManagedObjectContext(seams: seams)
        context.persistentStoreCoordinator = container.persistentStoreCoordinator
        return context
    }

    /// The process's merged model, loaded once — models are process-wide, and re-merging per
    /// capture is waste.
    ///
    /// - Precondition: The process's bundles must yield a model with entities; a subject whose
    ///   model lives elsewhere declares it: `.provides(NSManagedObjectContext.self) { … }`.
    private nonisolated(unsafe) static let mergedModel: NSManagedObjectModel = { // immutable once merged
        guard let model = NSManagedObjectModel.mergedModel(from: nil), !model.entities.isEmpty else {
            preconditionFailure(
                "no managed-object model found in the process's bundles — provide one: "
                    + ".provides(NSManagedObjectContext.self) { "
                    + "SeamedManagedObjectContext.inMemory(model: …, seams: $0) }"
            )
        }
        return model
    }()
}

/// Linking this module is the declaration: a derived system whose init takes an
/// `NSManagedObjectContext` resolves a fresh seamed in-memory stack per capture, nothing authored.
///
/// A subject that does not accept its context by initializer has no route here — injection is the
/// contract, so the port-ready fix is to thread the context through the subject's init.
extension SeamedManagedObjectContext: SeamResource {
    public static var providedResources: [Any.Type] {
        [NSManagedObjectContext.self]
    }

    public static func makeResource(_: Any.Type, _ seams: SeamContext) -> Any {
        inMemory(model: mergedModel, seams: seams)
    }

    public static var sweptSeams: [(seam: String, domain: SeamDomain)] {
        [(saveFailureSeam, .anyOf([.bool(false), .bool(true)]))]
    }
}
