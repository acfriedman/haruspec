import Foundation
import HaruspecCore
import HaruspecMacros
import HaruspecSeams
@testable import HaruspecSpec
import HaruspecTrace
import XCTest

// A GCD pantry that looks its stock up on a background queue and announces on main, against a
// `@MainActor` port that spawns the lookup through the project's task seam. The port's `refresh`
// runs on main while the capture recorded its call on its own thread; the spawn still names the call,
// and the announcement, a hop to main later, is still after it.

// MARK: - Seams

@Haruspec(schedules: .concurrent)
protocol PantryLookupQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
}

@Haruspec(schedules: .main)
protocol PantryMainQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
}

@Haruspec(schedules: .concurrent)
protocol PantrySpawner: AnyObject {
    func spawn(_ operation: @escaping @Sendable () async -> Void)
}

// MARK: - Subjects

@Haruspec
protocol Pantry: AnyObject {
    func refresh() async
}

/// Looks up on the background queue, then announces on main.
final class QueuedPantry: Pantry, @unchecked Sendable {
    private let lookups: any PantryLookupQueue
    private let main: any PantryMainQueue
    private let center: NotificationCenter

    init(lookups: any PantryLookupQueue, main: any PantryMainQueue, center: NotificationCenter) {
        self.lookups = lookups
        self.main = main
        self.center = center
    }

    func refresh() async {
        lookups.async { [self] in
            center.post(name: .init("PantryLookedUp"), object: nil)
            main.async { [self] in center.post(name: .init("PantryDidUpdate"), object: nil) }
        }
    }
}

/// The port: main-actor state, the lookup in a spawned task, the announcement back on main.
@MainActor
final class SpawnedPantry: Pantry {
    private nonisolated(unsafe) let spawner: any PantrySpawner
    private nonisolated let center: NotificationCenter

    nonisolated init(spawner: any PantrySpawner, center: NotificationCenter) {
        self.spawner = spawner
        self.center = center
    }

    func refresh() async {
        spawner.spawn { [weak self] in await self?.load() }
    }

    private func load() async {
        await Self.lookUp(center)
        center.post(name: .init("PantryDidUpdate"), object: nil)
    }

    private nonisolated static func lookUp(_ center: NotificationCenter) async {
        center.post(name: .init("PantryLookedUp"), object: nil)
    }
}

// MARK: - Tests

final class MainActorSpawnCauseTests: XCTestCase {
    func testAMainActorPortSpawningThroughTheSeamKeepsItsCauses() async {
        let verdict = await Spec<any Pantry>("pantry.main-actor")
            .operations { Op("refresh") { await $0.refresh() } }
            .baselined { context in
                QueuedPantry(
                    lookups: context.double(DoublePantryLookupQueue.self),
                    main: context.double(DoublePantryMainQueue.self),
                    center: context.notifications
                )
            }
            .verify(
                candidate: { context in
                    SpawnedPantry(spawner: context.double(DoublePantrySpawner.self), center: context.notifications)
                },
                declaring: Intent { Moves(everythingFrom: .queue("PantryLookupQueue"), to: .queue("PantrySpawner")) }
            )

        XCTAssertEqual(verdict.verdict, .equivalent, verdict.report())
        XCTAssertFalse(verdict.report().contains("synchronization"), verdict.report())
    }
}
