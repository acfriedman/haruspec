import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// A port off an operation queue onto the project's own stamped serial queue. The baseline's
// notification is posted from a completion block, two held items from the upload that caused it; the
// port posts it from one block. Both name the upload as its cause, so the only difference left is the
// one the port really makes: the state the baseline shows between the operation and its completion.

// MARK: - Subjects

@Haruspec(schedules: .serial)
protocol ConfirmingUploadQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
}

/// Uploads photos, counting the ones sent and the ones confirmed.
@Haruspec
protocol ConfirmingUploading: AnyObject {
    func upload(_ name: String)
    var sent: Int { get }
    var confirmed: Int { get }
}

/// Sends from the operation, confirms and posts from its completion block.
final class QueuedConfirmingUploader: ConfirmingUploading, @unchecked Sendable {
    private let queue: OperationQueue
    private let center: NotificationCenter
    private(set) var sent = 0
    private(set) var confirmed = 0

    init(queue: OperationQueue, center: NotificationCenter) {
        self.queue = queue
        self.center = center
    }

    func upload(_ name: String) {
        let operation = BlockOperation { [self] in sent += 1 }
        operation.completionBlock = { [self] in
            confirmed += 1
            center.post(name: .init("Uploaded"), object: nil, userInfo: ["name": name])
        }
        queue.addOperation(operation)
    }
}

/// The port: sends, confirms and posts in one block on the stamped queue.
final class OneBlockConfirmingUploader: ConfirmingUploading, @unchecked Sendable {
    private let queue: any ConfirmingUploadQueue
    private let center: NotificationCenter
    private(set) var sent = 0
    private(set) var confirmed = 0

    init(queue: any ConfirmingUploadQueue, center: NotificationCenter) {
        self.queue = queue
        self.center = center
    }

    func upload(_ name: String) {
        queue.async { [self] in
            sent += 1
            confirmed += 1
            center.post(name: .init("Uploaded"), object: nil, userInfo: ["name": name])
        }
    }
}

// MARK: - Tests

final class HeldOperationQueuePortTests: XCTestCase {
    func testAOneBlockPortChangesTheOrderOfStateButNotTheCauseOfTheNotification() async {
        let verdict = await Spec<any ConfirmingUploading>("uploading.confirming")
            .operations { Op("cat") { $0.upload("cat") } }
            .baselined { context in
                QueuedConfirmingUploader(
                    queue: context.operationQueue(.serial("ConfirmingUploadQueue")),
                    center: context.notifications
                )
            }
            .verify { context in
                OneBlockConfirmingUploader(
                    queue: context.double(DoubleConfirmingUploadQueue.self),
                    center: context.notifications
                )
            }

        XCTAssertEqual(verdict.verdict, .diverged, verdict.report())
        XCTAssertTrue(verdict.report().contains("ConfirmingUploading.sent: event order changed"), verdict.report())
        XCTAssertFalse(
            verdict.report().contains("synchronization"),
            "the completion names the upload two hops on\n\(verdict.report())"
        )
    }
}
