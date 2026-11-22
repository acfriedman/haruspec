import CoreData
import HaruspecCore
import HaruspecCoreData
import HaruspecSeams
import HaruspecSpec
import XCTest

// The packaged persistence resource, proven through the public Spec surface: an in-memory stack per
// capture, and the save choke point as swept seam surface. The model is built in code — the module
// serves any subject's model, so the fixture should not need a bundle.

/// One entity, one attribute — enough model to back a store.
private nonisolated(unsafe) let model: NSManagedObjectModel = { // immutable once built; shared read-only
    let text = NSAttributeDescription()
    text.name = "text"
    text.attributeType = .stringAttributeType
    let note = NSEntityDescription()
    note.name = "Note"
    note.properties = [text]
    let model = NSManagedObjectModel()
    model.entities = [note]
    return model
}()

/// A minimal persistence-bearing subject: inserts a row, saves, reports what a fetch sees.
private final class NoteStore {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Returns whether the save reached the store.
    @discardableResult
    func cache(_ text: String) -> Bool {
        let context = context
        return context.performAndWait {
            let row = NSEntityDescription.insertNewObject(forEntityName: "Note", into: context)
            row.setValue(text, forKey: "text")
            do {
                try context.save()
                return true
            } catch {
                return false
            }
        }
    }

    /// Returns the number of saved rows a fetch sees.
    func count() -> Int {
        let context = context
        return context.performAndWait {
            (try? context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Note"))) ?? -1
        }
    }
}

final class SeamedManagedObjectContextTests: XCTestCase {
    func testTheFailureSweepIsOnByDefault() async {
        var outcomes: Set<Bool> = []
        _ = await spec(recording: { outcomes.insert($0) }).baselined(on: store).record()

        XCTAssertEqual(
            outcomes,
            [true, false],
            "nothing declared, and the save both succeeds and fails across the schedule"
        )
    }

    func testAPinnedSeamOptsOutOfTheSweep() async {
        var outcomes: Set<Bool> = []
        _ = await spec(recording: { outcomes.insert($0) })
            .vary { Seam(SeamedManagedObjectContext.saveFailureSeam, .anyOf([.bool(false)])) }
            .baselined(on: store)
            .record()

        XCTAssertEqual(outcomes, [true], "an authored Seam pins the reading, so saves never fail")
    }

    private func spec(recording: @escaping (Bool) -> Void) -> Spec<NoteStore> {
        Spec<NoteStore>("notestore.coredata")
            .operations {
                Op("cache") { sut in recording(sut.cache("hello")) }
            }
    }

    private func store(_ seams: SeamContext) -> NoteStore {
        NoteStore(context: SeamedManagedObjectContext.inMemory(model: model, seams: seams))
    }

    func testEachCaptureGetsItsOwnStore() async {
        // A saved row must be visible to the subject's own fetch, and only within its capture:
        // `Ordering(repeating: 1)` pins one cache per probe (and the pinned seam keeps every save
        // real), so any count above 1 is a leak between the record's many probes.
        var counts: Set<Int> = []
        let spec = Spec<NoteStore>("notestore.isolated")
            .operations {
                Op("cache") { sut in
                    sut.cache("hello")
                    counts.insert(sut.count())
                }
            }
            .vary {
                Ordering(repeating: 1)
                Seam(SeamedManagedObjectContext.saveFailureSeam, .anyOf([.bool(false)]))
            }
            .baselined { seams in
                NoteStore(context: SeamedManagedObjectContext.inMemory(model: model, seams: seams))
            }
        _ = await spec.record()

        XCTAssertEqual(counts, [1], "every probe sees exactly its own saved row")
    }
}
