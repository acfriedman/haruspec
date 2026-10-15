import Combine
import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace

// The audited subject for HeldStandInAuditTests, alone in its file: the audit reads this file, so it
// holds the subject's reaches and nothing else.

@Haruspec
protocol Courier: AnyObject {
    func ship(_ parcel: String)
}

/// Announces through a Combine pipeline on its scheduler, and ships on its operation queue.
final class HeldCourier<S: Scheduler>: Courier, @unchecked Sendable {
    private let parcels = PassthroughSubject<String, Never>()
    private var subscription: AnyCancellable?
    private let queue: OperationQueue
    private let center: NotificationCenter

    init(scheduler: S, queue: OperationQueue, center: NotificationCenter) {
        self.queue = queue
        self.center = center
        subscription = parcels
            .receive(on: scheduler)
            .sink { center.post(name: .init("ParcelAnnounced"), object: nil, userInfo: ["parcel": $0]) }
    }

    func ship(_ parcel: String) {
        queue.addOperation { [center] in
            center.post(name: .init("ParcelShipped"), object: nil, userInfo: ["parcel": parcel])
        }
        parcels.send(parcel)
    }
}
