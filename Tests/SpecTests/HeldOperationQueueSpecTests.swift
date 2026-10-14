import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// The uploader from haruspec#21, checked through `context.operationQueue(_:)`: one operation per photo
// on a serial queue, and a notification from each operation's completion block.

// MARK: - Subjects

/// Uploads photos.
@Haruspec
protocol PhotoUploading: AnyObject {
    func upload(_ name: String)
}

/// The issue's uploader: one operation per photo on its queue, a photo in flight while its operation is
/// still queued, and a notification once a photo's completion runs.
final class PhotoUploader: PhotoUploading, @unchecked Sendable {
    private let queue: OperationQueue
    private let center: NotificationCenter

    init(queue: OperationQueue, center: NotificationCenter) {
        self.queue = queue
        self.center = center
    }

    func upload(_ name: String) {
        let operation = UploadOperation(Photo(name: name))
        operation.completionBlock = { [weak self] in self?.finished(name) }
        queue.addOperation(operation)
    }

    func isUploading(_ name: String) -> Bool {
        queue.operations.contains { ($0 as? UploadOperation)?.photo.name == name }
    }

    private func finished(_ name: String) {
        center.post(
            name: .init("PhotoUploaded"),
            object: nil,
            userInfo: ["name": name, "stillUploading": isUploading(name), "queued": queue.operationCount]
        )
    }
}

/// A port that never uploads.
final class SilentPhotoUploader: PhotoUploading {
    func upload(_: String) {}
}

/// A port that drops the queue and reports each upload done on the caller's thread.
final class InlinePhotoUploader: PhotoUploading {
    private let center: NotificationCenter

    init(center: NotificationCenter) {
        self.center = center
    }

    func upload(_ name: String) {
        center.post(
            name: .init("PhotoUploaded"),
            object: nil,
            userInfo: ["name": name, "stillUploading": false, "queued": 0]
        )
    }
}

// MARK: - Tests

final class HeldOperationQueueSpecTests: XCTestCase {
    private var uploading: BaselinedSpec<any PhotoUploading> {
        Spec<any PhotoUploading>("uploading.operation-queue")
            .operations {
                Op("cat") { $0.upload("cat.jpg") }
                Op("dog") { $0.upload("dog.jpg") }
            }
            .vary { Ordering(max: 2) }
            .baselined { context in
                PhotoUploader(queue: context.operationQueue(.serial("uploads")), center: context.notifications)
            }
    }

    func testTheUploaderIsEquivalentToItself() async {
        let verdict = await uploading.verify { context in
            PhotoUploader(queue: context.operationQueue(.serial("uploads")), center: context.notifications)
        }

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
    }

    /// The issue's false green: over a real queue, neither side records a completion, so this port
    /// read EQUIVALENT.
    func testAnUploaderThatNeverUploadsDiverges() async {
        let verdict = await uploading.verify { _ in SilentPhotoUploader() }

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
    }

    func testAnUploaderThatDropsTheQueueDiverges() async {
        let verdict = await uploading.verify { context in InlinePhotoUploader(center: context.notifications) }

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
        XCTAssertTrue(verdict.report().contains("ran on a different domain"), verdict.report())
    }

    func testAnUploaderOnAConcurrentQueueDiverges() async {
        let verdict = await uploading.verify { context in
            PhotoUploader(queue: context.operationQueue(.concurrent("uploads")), center: context.notifications)
        }

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
        XCTAssertTrue(verdict.report().contains("queue(concurrent):uploads"), verdict.report())
    }
}
